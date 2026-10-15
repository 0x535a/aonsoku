import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// macOS production host for the isolated macOS renderer/model/cache sources.
/// Control state is isolated from the encoding and Core ML queues.
final class MacDynamicCoverService {
  static var shared: MacDynamicCoverService?
  private let control = DispatchQueue(label: "com.aonsoku.macos-artwork-control", qos: .utility)
  private let registry = DynamicCoverRegistry<ArtworkAsset>()
  private let generation = ArtworkGeneration()
  private var originalURL: URL?
  private var original: Data?
  private var originalTask: URLSessionDownloadTask?
  private var sourceStatus = "no-cover"
  private var observers: [NSObjectProtocol] = []
  private var sourceRevision = 0
  private var preparing = false
  private var retryTimer: DispatchSourceTimer?
  private var fileLeases: [String: (owner: UUID, url: URL)] = [:]
  private var owners: Set<UUID> = []
  private let root: URL
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
  }()

  init(root: URL, license: URL) {
    self.root = root
    ArtworkStorage.root = root
    ArtworkStorage.license = license
    _ = ArtworkMotionPolicy.shared  // AppKit snapshot, main thread
    let center = NotificationCenter.default
    for name in [
      ArtworkSettings.changed, ArtworkModelManager.ready,
      ArtworkMotionPolicy.resourcesChanged,
      ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
          self?.control.async { [weak self] in
            guard let self else { return }
            ArtworkModelManager.shared.resumeDeferred()
            self.prepare(
              force: note.name == ArtworkSettings.changed || note.name == ArtworkModelManager.ready)
          }
        })
    }
    // Retry interrupted/deferred work without encoding in an acquire call.
    let timer = DispatchSource.makeTimerSource(queue: control)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    timer.setEventHandler { [weak self] in self?.prepare() }
    timer.resume()
    retryTimer = timer
  }

  func call(
    _ operation: String, _ input: [String: Any], completion: @escaping ([String: Any]) -> Void
  ) {
    control.async {
      do { try self.handle(operation, input, completion: completion) } catch {
        completion(["error": "\((error as NSError).domain):\((error as NSError).code)"])
      }
    }
  }

  private func handle(
    _ operation: String, _ input: [String: Any], completion: @escaping ([String: Any]) -> Void
  ) throws {
    switch operation {
    case "capabilities":
      completion(["version": 1, "available": true, "formats": ["square", "portrait"]])
    case "state": completion(state())
    case "configure":
      let old = ArtworkSettings.shared.value
      try ArtworkSettings.shared.configure(input)
      let next = ArtworkSettings.shared.value
      if !next.immersiveEnabled || !next.dynamicEnabled {
        ArtworkModelManager.shared.stopAutomaticGeneration()
      }
      if old.wifiOnly != next.wifiOnly { ArtworkModelManager.shared.preferencesChanged() }
      completion(state())
    case "download", "cancel", "remove":
      guard let raw = input["tier"] as? String, let tier = ArtworkTier(rawValue: raw) else {
        throw NSError(domain: "ArtworkTier", code: 1)
      }
      if operation == "download" { ArtworkModelManager.shared.request(tier) }
      if operation == "cancel" { ArtworkModelManager.shared.cancel(tier) }
      if operation == "remove" { ArtworkModelManager.shared.remove(tier) }
      completion([:])
    case "listVideos": ArtworkStore.shared.listVideos { completion(["videos": $0]) }
    case "deleteVideo":
      guard let id = input["id"] as? String else { throw NSError(domain: "ArtworkVideo", code: 1) }
      ArtworkStore.shared.deleteVideo(id: id) { deleted in
        completion(deleted ? [:] : ["error": "Video is in use or could not be deleted"])
      }
    case "clearVideos":
      let kind = input["kind"] as? String ?? "all"
      guard ["all", "static", "dynamic"].contains(kind) else {
        throw NSError(domain: "ArtworkVideo", code: 2)
      }
      ArtworkStore.shared.clearVideos(kind: kind) { deleted, retained in
        completion(["deleted": deleted, "retained": retained])
      }
    case "diagnostics":
      let snapshot = ArtworkDiagnostics.shared.snapshot()
      var info: [String: Any] = [
        "source": sourceStatus, "revision": registry.revision,
        "renderer": ArtworkDiagnostics.shared.rendererState(),
        "variants": snapshot.variants, "phases": snapshot.phases,
        "leases": fileLeases.count, "state": state(),
      ]
      if let depth = ArtworkDiagnostics.shared.depthPreview() {
        let data = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(
          data, UTType.png.identifier as CFString, 1, nil)
        {
          CGImageDestinationAddImage(destination, depth, nil)
          if CGImageDestinationFinalize(destination) {
            info["depthPreview"] = "data:image/png;base64," + (data as Data).base64EncodedString()
          }
        }
      }
      completion(info)
    case "playback":
      updateSource(input["artworkUrl"] as? String)
      completion([:])
    case "acquire": acquire(input, completion: completion)
    case "openSession", "release", "releaseAll", "leaseFile":
      guard let raw = input["owner"] as? String, let owner = UUID(uuidString: raw) else {
        throw NSError(domain: "ArtworkSession", code: 1)
      }
      let id = input["leaseId"] as? String ?? ""
      if operation == "openSession" {
        owners.insert(owner)
      } else if operation == "releaseAll" {
        owners.remove(owner)
        registry.releaseAll(owner: owner)
        fileLeases = fileLeases.filter { $0.value.owner != owner }
      } else if fileLeases[id]?.owner == owner {
        if operation == "leaseFile" {
          completion(["path": fileLeases[id]!.url.path])
          return
        }
        fileLeases.removeValue(forKey: id)
        registry.release(id, owner: owner)
      }
      completion([:])
    default: throw NSError(domain: "ArtworkOperation", code: 1)
    }
  }

  private func state() -> [String: Any] {
    let options = ArtworkSettings.shared.value
    let policy = ArtworkMotionPolicy.shared
    let manager = ArtworkModelManager.shared
    let encoded = try? JSONEncoder().encode(options)
    var reason = policy.generationReason
    if !options.immersiveEnabled || !options.dynamicEnabled {
      reason = "disabled"
    } else if reason == "ready", let tier = policy.effectiveTier,
      manager.availableTier(upTo: tier) == nil
    {
      reason = "waitingForModel"
    }
    return [
      "supported": true,
      "options": encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:],
      "deviceMemoryBytes": ProcessInfo.processInfo.physicalMemory,
      "recommendedTier": ArtworkTier.automatic(memory: ProcessInfo.processInfo.physicalMemory)
        .rawValue,
      "effectiveTier": policy.effectiveTier?.rawValue as Any? ?? NSNull(),
      "generationStatus": reason, "models": manager.snapshot(),
      "modelRevision": ArtworkModelCatalog.revision,
    ]
  }

  private func updateSource(_ raw: String?) {
    // Only native media-session metadata supplies this URL. Original covers
    // are downloaded here; renderer thumbnails/base64 are never AI inputs.
    var components = raw.flatMap { URLComponents(string: $0) }
    let path = components?.url?.lastPathComponent ?? ""
    if !["http", "https"].contains(components?.scheme ?? "")
      || !["getCoverArt", "getCoverArt.view"].contains(path)
    {
      components = nil
    }
    let originalQuery = components?.queryItems?.filter { $0.name != "size" }
    components?.queryItems = originalQuery
    let url = components?.url
    if originalURL == url {
      if original == nil && originalTask == nil { prepare() }
      return
    }
    originalTask?.cancel()
    originalTask = nil
    sourceRevision += 1
    originalURL = url
    original = nil
    sourceStatus = url == nil ? "no-cover" : "waitingForOriginal"
    let cover = components?.queryItems?.first { $0.name == "id" }?.value
    registry.begin(coverArtId: cover)
    generation.update(registry.revision)
    preparing = false
    prepare()
  }

  private func prepare(force: Bool = false) {
    let options = ArtworkSettings.shared.value
    let policy = ArtworkMotionPolicy.shared
    guard originalURL != nil else { return }
    if force {
      registry.begin(coverArtId: registry.coverArtId)
      generation.update(registry.revision)
      preparing = false
    }
    guard options.immersiveEnabled, policy.allowsStaticGeneration else { return }
    guard let original else {
      fetchOriginal()
      return
    }
    guard !preparing else { return }
    // A completed depth clip needs no further work until its source/options change.
    let motion = options.dynamicEnabled && policy.allowsGeneration
    if let cover = registry.coverArtId,
      let asset = registry.current(coverArtId: cover, format: "square", mode: "dynamic"),
      !motion || (asset.motion && asset.backend != "camera")
    {
      return
    }
    preparing = true
    let revision = registry.revision
    let current = { [generation] in generation.contains(revision) }
    let store = ArtworkStore.shared
    let target =
      policy.effectiveTier ?? ArtworkTier.automatic(memory: ProcessInfo.processInfo.physicalMemory)
    let tier = ArtworkModelManager.shared.availableTier(upTo: target) ?? target
    if motion { ArtworkModelManager.shared.request(target, automatic: true) }
    guard let image = ArtworkRenderer.decode(original) else {
      preparing = false
      sourceStatus = "invalid-original"
      return
    }
    func publish(_ asset: ArtworkAsset?) {
      guard let asset else { return }
      self.control.async {
        guard self.registry.revision == revision else { return }
        let rank = asset.motion ? (asset.backend == "camera" ? 1 : 2) : 0
        self.registry.publish(
          asset, format: asset.format == .square ? "square" : "portrait", rank: rank)
        ArtworkDiagnostics.shared.update(
          asset.format.label,
          [
            "publishedBackend": asset.motion ? asset.backend : "static", "asset": asset.id,
            "loopDuration": "\(asset.motion ? asset.parameters.duration : 2) s",
          ])
      }
    }
    let group = DispatchGroup()
    for format in [ArtworkFormat.square, .tall] {
      group.enter()
      store.prepare(data: original, source: image, format: format, shouldContinue: current) {
        staticAsset in
        publish(staticAsset)
        guard motion, current(), policy.allowsGeneration else {
          group.leave()
          return
        }
        let depth = {
          store.prepare(
            data: original, source: image, format: format, motion: true,
            backend: tier.backend, shouldContinue: current
          ) { asset in
            if let asset, asset.motion, asset.backend != "camera" {
              asset.retainedStaticAsset = staticAsset
              publish(asset)
              store.retireCameraVideo(for: asset)
            }
            group.leave()
          }
        }
        if store.hasReadyVideo(data: original, format: format, backend: tier.backend) {
          depth()
          return
        }
        store.prepare(
          data: original, source: image, format: format, motion: true,
          backend: "camera", shouldContinue: current
        ) { asset in
          asset?.retainedStaticAsset = staticAsset
          publish(asset)
          if current() { depth() } else { group.leave() }
        }
      }
    }
    group.notify(queue: control) {
      if self.registry.revision == revision { self.preparing = false }
    }
  }

  private func fetchOriginal() {
    guard originalTask == nil, let url = originalURL else { return }
    let revision = sourceRevision
    let cache = ArtworkStorage.directory("OriginalCovers")
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let file = cache.appendingPathComponent(digest)
    if let data = try? Data(contentsOf: file), ArtworkSourceQuality.dimensions(data) != nil {
      original = data
      sourceStatus = "originalReady (disk)"
      prepare()
      return
    }
    originalTask = session.downloadTask(with: url) { [weak self] temporary, response, error in
      var data: Data?
      if error == nil, let temporary, let response = response as? HTTPURLResponse,
        (200..<300).contains(response.statusCode),
        let bytes = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        bytes > 0, bytes <= 32 * 1024 * 1024,
        let loaded = try? Data(contentsOf: temporary),
        ArtworkSourceQuality.dimensions(loaded) != nil
      {
        data = loaded
      }
      self?.control.async { [weak self, data] in
        guard let self, revision == self.sourceRevision else { return }
        self.originalTask = nil
        guard let data else {
          self.sourceStatus = "original-download-failed"
          return
        }
        self.original = data
        self.sourceStatus = "originalReady"
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        var folder = cache
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let files =
          (try? FileManager.default.contentsOfDirectory(
            at: cache,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let ordered = files.sorted {
          ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast)
            > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey])
              .contentModificationDate) ?? .distantPast)
        }
        var total = 0
        for (index, item) in ordered.enumerated() {
          total += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
          if item != file && (index >= 12 || total > 64 * 1024 * 1024) {
            try? FileManager.default.removeItem(at: item)
          }
        }
        self.prepare()
      }
    }
    originalTask?.resume()
  }

  private func acquire(_ input: [String: Any], completion: @escaping ([String: Any]) -> Void) {
    guard let cover = input["coverArtId"] as? String,
      let format = input["format"] as? String, ["square", "portrait"].contains(format),
      let mode = input["mode"] as? String, ["static", "dynamic"].contains(mode),
      let raw = input["owner"] as? String, let owner = UUID(uuidString: raw)
    else {
      completion(["error": "Invalid cover request"])
      return
    }
    guard ArtworkSettings.shared.value.immersiveEnabled else {
      completion(["status": "disabled"])
      return
    }
    guard owners.contains(owner), registry.coverArtId == cover else {
      completion(["status": "mismatch"])
      return
    }
    let motion =
      ArtworkSettings.shared.value.dynamicEnabled && ArtworkMotionPolicy.shared.allowsPlayback
    guard
      let asset = registry.current(
        coverArtId: cover, format: format, mode: mode == "dynamic" && motion ? "dynamic" : "static")
    else {
      completion(["status": "pending", "reason": sourceStatus])
      return
    }
    let revision = registry.revision
    asset.requestVideo { url in
      self.control.async {
        guard self.owners.contains(owner), revision == self.registry.revision else {
          completion(["status": "mismatch"])
          return
        }
        guard ArtworkSettings.shared.value.immersiveEnabled else {
          completion(["status": "disabled"])
          return
        }
        guard
          !asset.motion
            || (ArtworkSettings.shared.value.dynamicEnabled
              && ArtworkMotionPolicy.shared.allowsPlayback),
          let url
        else {
          completion(["status": "pending"])
          return
        }
        guard let id = self.registry.retain(asset, owner: owner) else {
          completion(["status": "busy"])
          return
        }
        self.fileLeases[id] = (owner, url)
        completion([
          "status": "ready", "leaseId": id, "assetId": asset.id, "coverArtId": cover,
          "format": format,
          "stage": asset.motion ? (asset.backend == "camera" ? "camera" : "depth") : "static",
          "backend": asset.motion ? asset.backend : "static", "width": asset.format.width,
          "height": asset.format.height, "duration": asset.motion ? asset.parameters.duration : 2,
        ])
      }
    }
  }
}

@_cdecl("aonsoku_artwork_initialize")
public func aonsokuArtworkInitialize(_ root: UnsafePointer<CChar>, _ license: UnsafePointer<CChar>)
{
  precondition(Thread.isMainThread)
  if MacDynamicCoverService.shared == nil {
    MacDynamicCoverService.shared = MacDynamicCoverService(
      root: URL(fileURLWithPath: String(cString: root), isDirectory: true),
      license: URL(fileURLWithPath: String(cString: license)))
  }
}

/// Called on a Rust blocking worker, never the AppKit/main or audio command thread.
@_cdecl("aonsoku_artwork_call")
public func aonsokuArtworkCall(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
  guard !Thread.isMainThread, let service = MacDynamicCoverService.shared,
    let data = String(cString: request).data(using: .utf8),
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let operation = json["operation"] as? String
  else { return strdup("{\"error\":\"Artwork service unavailable\"}") }
  let semaphore = DispatchSemaphore(value: 0)
  var result: [String: Any] = [:]
  service.call(operation, json["payload"] as? [String: Any] ?? [:]) { value in
    result = value
    semaphore.signal()
  }
  semaphore.wait()
  let output = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
  return strdup(String(decoding: output, as: UTF8.self))
}

@_cdecl("aonsoku_artwork_free")
public func aonsokuArtworkFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }
