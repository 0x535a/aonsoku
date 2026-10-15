import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

/// Captured by the system artwork handlers. A live asset pins its video file
/// against eviction, including after the player switches to another cover.
final class ArtworkAsset {
  let id: String
  let preview: CGImage
  let motion: Bool
  let backend: String
  let parameters: ArtworkMotionParameters
  var analysisReason: String?
  var retainedStaticAsset: ArtworkAsset?
  let format: ArtworkFormat
  fileprivate var source: CGImage?
  fileprivate var shouldContinue: () -> Bool = { true }
  private let store: ArtworkStore

  fileprivate init(
    id: String, preview: CGImage, source: CGImage?,
    format: ArtworkFormat, motion: Bool, backend: String = "camera",
    store: ArtworkStore, parameters: ArtworkMotionParameters = .init()
  ) {
    self.id = id
    self.preview = preview
    self.source = source
    self.format = format
    self.motion = motion
    self.backend = backend
    self.parameters = parameters
    self.store = store
  }

  func requestVideo(_ completion: @escaping (URL?) -> Void) {
    store.requestVideo(for: self, completion: completion)
  }

  deinit { store.assetReleased() }
}

final class ArtworkStore {
  static let shared = ArtworkStore()
  private let queue = DispatchQueue(label: "com.aonsoku.lock-screen-artwork", qos: .utility)
  private let requests = DispatchQueue(label: "com.aonsoku.artwork-file-requests", qos: .utility)
  private let directory: URL
  private let byteLimit: Int
  private let countLimit: Int
  private struct WeakAsset { weak var value: ArtworkAsset? }
  private var assets: [String: WeakAsset] = [:]
  private var pending: [(asset: ArtworkAsset, callbacks: [(URL?) -> Void])] = []
  private var encodingID: String?
  private var retiredCameraIDs: Set<String> = []
  private var pressureObserver: NSObjectProtocol?
  private var textRegions: [String: [CGRect]] = [:]
  private var analyses: [String: ArtworkMotionAnalysis] = [:]
  private let policy = ArtworkMotionPolicy.shared

  init(directory: URL? = nil, byteLimit: Int = 24 * 1024 * 1024, countLimit: Int = 12) {
    // Application Support rather than temporary storage: URLs must remain
    // valid while MediaPlayer retains the corresponding artwork object.
    self.directory =
      directory
      ?? ArtworkStorage.directory("AonsokuArtwork")
    self.byteLimit = byteLimit
    self.countLimit = countLimit
    queue.async { self.trim() }
    pressureObserver = NotificationCenter.default.addObserver(
      forName: ArtworkMotionPolicy.resourcesChanged, object: nil, queue: nil
    ) { [weak self] _ in
      self?.queue.async { [weak self] in
        self?.analyses.removeAll()
        self?.textRegions.removeAll()
      }
    }
  }

  deinit {
    if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) }
  }

  func prepare(
    data: Data, source: CGImage, format: ArtworkFormat = .tall,
    motion: Bool = false, backend: String = "camera",
    shouldContinue: @escaping () -> Bool = { true },
    completion: @escaping (ArtworkAsset?) -> Void
  ) {
    let parameters =
      backend == "camera"
      ? ArtworkMotionParameters()
      : ArtworkSettings.shared.value.motionParameters
    queue.async {
      autoreleasepool {
        guard shouldContinue() else {
          completion(nil)
          return
        }
        // Content-based identity shares assets across album tracks and
        // invalidates them on cover replacement. No authenticated URL
        // or server/album identifier is stored on disk.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let id =
          motion
          ? Self.motionID(digest: digest, format: format, backend: backend, parameters: parameters)
          : "edge-v1-\(format.width)x\(format.height)-\(digest)"
        ArtworkDiagnostics.shared.update(
          format.label,
          [
            "backend": backend,
            "state": "preparing", "reason": "", "cache": "miss",
            "mode": motion ? "pending" : "static",
          ])
        if let existing = self.assets[id]?.value {
          existing.shouldContinue = shouldContinue
          if motion && existing.source == nil { existing.source = source }
          self.enqueue(existing) { url in
            if motion, url == nil {
              let fallback = self.preparedAsset(existing, video: nil)
              self.enqueue(fallback) { _ in completion(fallback) }
            } else {
              completion(existing)
            }
          }
          return
        }
        let renderMeasurement = ArtworkMeasurement("image-extension")
        guard let preview = ArtworkRenderer.render(source, format: format) else {
          completion(nil)
          return
        }
        let asset = ArtworkAsset(
          id: id, preview: preview, source: motion ? source : nil,
          format: format, motion: motion, backend: backend, store: self, parameters: parameters)
        renderMeasurement.finish("format=\(format.label)")
        asset.shouldContinue = shouldContinue
        self.assets[id] = WeakAsset(value: asset)
        self.trim()
        self.enqueue(asset) { url in
          if motion, url == nil {
            let fallback = self.preparedAsset(asset, video: nil)
            self.enqueue(fallback) { _ in completion(fallback) }
          } else {
            completion(asset)
          }
        }
      }
    }
  }

  private func preparedAsset(_ asset: ArtworkAsset, video: URL?) -> ArtworkAsset {
    guard video == nil else { return asset }
    // A deferred or failed motion export still uses the proven immersive
    // static clip, with no inference/multi-frame work in system requests.
    let digest = asset.id.components(separatedBy: "-").last!
    let id = "edge-v1-\(asset.format.width)x\(asset.format.height)-\(digest)"
    if let existing = assets[id]?.value { return existing }
    let fallback = ArtworkAsset(
      id: id, preview: asset.preview, source: nil,
      format: asset.format, motion: false, store: self)
    fallback.analysisReason = asset.analysisReason ?? "waiting-for-model-or-resources"
    fallback.shouldContinue = asset.shouldContinue
    assets[id] = WeakAsset(value: fallback)
    return fallback
  }

  fileprivate func requestVideo(
    for asset: ArtworkAsset, completion: @escaping (URL?) -> Void
  ) {
    requests.async {
      guard !asset.motion || self.policy.allowsPlayback else {
        completion(nil)
        return
      }
      let url = self.videoURL(for: asset.id)
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
        completion(nil)
        return
      }
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      completion(url)
    }
  }

  private func enqueue(_ asset: ArtworkAsset, completion: @escaping (URL?) -> Void) {
    let url = videoURL(for: asset.id)
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
      ArtworkDiagnostics.shared.update(
        asset.format.label,
        [
          "cache": "hit", "state": "ready",
          "mode": asset.motion ? "cached motion" : "static", "bytes": "\(size)",
        ])
      asset.source = nil
      completion(url)
      return
    }
    try? FileManager.default.removeItem(at: url)
    if let index = pending.firstIndex(where: { $0.asset.id == asset.id }) {
      pending[index].callbacks.append(completion)
    } else {
      // Bound retained source images when songs are changed rapidly.
      if pending.count >= 4 {
        completion(nil)
        return
      }
      pending.append((asset, [completion]))
    }
    encodeNext()
  }

  func hasReadyVideo(data: Data, format: ArtworkFormat, backend: String) -> Bool {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let parameters = ArtworkSettings.shared.value.motionParameters
    let id = Self.motionID(digest: digest, format: format, backend: backend, parameters: parameters)
    return (try? videoURL(for: id).resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 }
      ?? false
  }

  static func motionID(
    digest: String, format: ArtworkFormat, backend: String,
    parameters: ArtworkMotionParameters
  ) -> String {
    let prefix =
      backend == "camera" ? "motion-v5-camera" : "motion-v6-\(backend)-\(parameters.cacheKey)"
    return "\(prefix)-\(format.width)x\(format.height)-\(digest)"
  }

  func retireCameraVideo(for depthAsset: ArtworkAsset) {
    queue.async {
      let digest = depthAsset.id.components(separatedBy: "-").last!
      let id = "motion-v5-camera-\(depthAsset.format.width)x\(depthAsset.format.height)-\(digest)"
      self.retiredCameraIDs.insert(id)
      self.trim()
      self.queue.asyncAfter(deadline: .now() + 5) { self.trim() }
    }
  }

  fileprivate func assetReleased() { queue.async { self.trim() } }

  func listVideos(_ completion: @escaping ([[String: Any]]) -> Void) {
    queue.async {
      let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: self.directory,
          includingPropertiesForKeys: Array(keys))) ?? []
      let items = files.filter {
        $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(".tmp.mp4")
      }
      .compactMap { url -> [String: Any]? in
        let id = url.deletingPathExtension().lastPathComponent
        let values = try? url.resourceValues(forKeys: keys)
        guard let bytes = values?.fileSize, bytes > 0 else { return nil }
        return [
          "id": id, "kind": id.hasPrefix("edge-") ? "static" : "dynamic",
          "format": id.contains("720x960") ? "3:4" : "1:1", "sizeBytes": bytes,
          "cachedAt": Int((values?.creationDate ?? .distantPast).timeIntervalSince1970 * 1000),
          "lastAccessedAt": Int(
            (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000),
          "protected": self.assets[id]?.value != nil,
        ]
      }
      completion(
        items.sorted { ($0["lastAccessedAt"] as? Int ?? 0) > ($1["lastAccessedAt"] as? Int ?? 0) })
    }
  }

  func deleteVideo(id: String, completion: @escaping (Bool) -> Void) {
    queue.async {
      guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
        self.assets[id]?.value == nil
      else {
        completion(false)
        return
      }
      let url = self.videoURL(for: id)
      guard FileManager.default.fileExists(atPath: url.path) else {
        completion(true)
        return
      }
      do {
        try FileManager.default.removeItem(at: url)
        completion(true)
      } catch { completion(false) }
    }
  }

  func clearVideos(kind: String, completion: @escaping (Int, Int) -> Void) {
    queue.async {
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: self.directory,
          includingPropertiesForKeys: nil)) ?? []
      var deleted = 0
      var retained = 0
      for file in files
      where file.pathExtension == "mp4" && !file.lastPathComponent.hasSuffix(".tmp.mp4") {
        let id = file.deletingPathExtension().lastPathComponent
        let category = id.hasPrefix("edge-") ? "static" : "dynamic"
        guard kind == "all" || kind == category else { continue }
        guard self.assets[id]?.value == nil else {
          retained += 1
          continue
        }
        do {
          try FileManager.default.removeItem(at: file)
          deleted += 1
        } catch { retained += 1 }
      }
      completion(deleted, retained)
    }
  }

  private func videoURL(for id: String) -> URL {
    directory.appendingPathComponent(id).appendingPathExtension("mp4")
  }

  private func encodeNext() {
    guard encodingID == nil, let request = pending.first else { return }
    encodingID = request.asset.id
    guard request.asset.shouldContinue(),
      !request.asset.motion || canGenerate(request.asset)
    else {
      request.asset.analysisReason = "generation-deferred: \(policy.generationReason)"
      finishEncoding(nil)
      return
    }
    if request.asset.motion,
      let tier = ArtworkTier.allCases.first(where: { $0.backend == request.asset.backend }),
      ArtworkModelManager.shared.modelURL(tier) == nil
    {
      request.asset.analysisReason = "waiting-for-model"
      ArtworkModelManager.shared.request(tier, automatic: true)
      finishEncoding(nil)
      return
    }
    var depth: CIImage?
    if request.asset.motion, let source = request.asset.source {
      let digest = request.asset.backend + "-" + request.asset.id.components(separatedBy: "-").last!
      let analysis: ArtworkMotionAnalysis = autoreleasepool {
        if let cached = analyses[digest] { return cached }
        let measured = ArtworkMeasurement("analysis backend=\(request.asset.backend)")
        let result: ArtworkMotionAnalysis
        if let tier = ArtworkTier.allCases.first(where: { $0.backend == request.asset.backend }),
          let modelURL = ArtworkModelManager.shared.modelURL(tier)
        {
          let ratio = Double(source.width) / Double(source.height)
          if min(source.width, source.height) < 64 || ratio < 0.4 || ratio > 2.5 {
            result = .init(mask: nil, reason: "unsafe-source-geometry")
          } else {
            let model = ArtworkDepthModel.analyze(
              source,
              candidate: ArtworkDepthModel.candidate(tier), modelURL: modelURL,
              shouldContinue: { self.canContinue(request.asset) })
            let content = request.asset.id.components(separatedBy: "-").last!
            if textRegions[content] == nil && self.policy.allowsGeneration
              && request.asset.shouldContinue()
            {
              if textRegions.count >= 8 { textRegions.removeAll() }
              textRegions[content] = ArtworkMotion.textRegions(source)
            }
            result = .init(
              mask: model.mask, reason: model.reason,
              protectedText: textRegions[content] ?? [])
          }
        } else {
          result = ArtworkMotion.analyze(source)
        }
        measured.finish("mode=\(result.mode) reason=\(result.reason)")
        if analyses.count >= 8 { analyses.removeAll() }
        if result.canCache { analyses[digest] = result }
        return result
      }
      request.asset.analysisReason = analysis.reason
      if request.asset.backend != "camera" {
        ArtworkDiagnostics.shared.setDepth(analysis.mask)
      }
      ArtworkDiagnostics.shared.update(
        request.asset.format.label,
        [
          "mode": analysis.mode, "reason": analysis.reason,
          "textRegions": "\(analysis.protectedText.count)",
        ])
      guard analysis.canCache else {
        finishEncoding(nil)
        return
      }
      // The camera stage already covers procedural motion. A DAV2 namespace
      // is reserved for completed depth, never a geometry/error fallback.
      guard request.asset.backend == "camera" || analysis.mask != nil else {
        finishEncoding(nil)
        return
      }
      guard analysis.mask == nil || ArtworkMotion.parallaxAvailable else {
        request.asset.analysisReason = "metal-kernel-unavailable"
        finishEncoding(nil)
        return
      }
      depth = ArtworkMotion.depthImage(
        analysis, source: source, format: request.asset.format)
    }
    let measured = ArtworkMeasurement(
      "\(request.asset.motion ? "motion-encode" : "static-encode") backend=\(request.asset.backend)"
    )
    let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
      "tmp.mp4")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      var excluded = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try excluded.setResourceValues(values)
      ArtworkVideo.write(
        image: request.asset.preview, to: temporary, queue: queue,
        motion: request.asset.motion, depth: depth, parameters: request.asset.parameters,
        shouldContinue: { self.canContinue(request.asset) }
      ) {
        result in
        self.queue.async {
          let final = self.videoURL(for: request.asset.id)
          var output: URL?
          do {
            _ = try result.get()
            try FileManager.default.moveItem(at: temporary, to: final)
            output = final
          } catch {
            // Leave ordinary static artwork installed on any failure.
            try? FileManager.default.removeItem(at: temporary)
          }
          measured.finish("success=\(output != nil)")
          request.asset.source = nil
          self.finishEncoding(output)
        }
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      finishEncoding(nil)
    }
  }

  private func finishEncoding(_ url: URL?) {
    let request = pending.removeFirst()
    encodingID = nil
    request.asset.source = nil
    ArtworkDiagnostics.shared.update(
      request.asset.format.label,
      [
        "state": url == nil ? "deferred/failed" : "ready",
        "reason": request.asset.analysisReason ?? (url == nil ? "encoding-failed" : "static"),
        "mode": request.asset.motion && url != nil
          ? (request.asset.analysisReason == "camera-fallback-no-depth" ? "camera" : "parallax")
          : "static",
      ])
    for callback in request.callbacks { callback(url) }
    trim()
    encodeNext()
  }

  private func canGenerate(_ asset: ArtworkAsset) -> Bool {
    guard policy.allowsGeneration, asset.shouldContinue() else { return false }
    if let tier = ArtworkTier.allCases.first(where: { $0.backend == asset.backend }) {
      guard let ceiling = policy.effectiveTier else { return false }
      let ranks: [ArtworkTier: Int] = [.p6: 0, .p8: 1, .fp16: 2]
      return ranks[tier]! <= ranks[ceiling]!
    }
    return true
  }

  private func canContinue(_ asset: ArtworkAsset) -> Bool {
    // The loaded model itself consumes headroom. Tier admission happens once,
    // before loading; abort only for actual pause conditions while it is alive.
    let active = asset.shouldContinue()
    let allowed = policy.allowsGeneration
    if !active || !allowed {
      ArtworkDiagnostics.shared.update(
        asset.format.label,
        ["reason": active ? policy.generationReason : "stale-revision"])
    }
    return active && allowed
  }

  private func trim() {
    assets = assets.filter { $0.value.value != nil }
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys)
      )
    else { return }
    for id in Array(retiredCameraIDs) where assets[id]?.value == nil {
      try? FileManager.default.removeItem(at: videoURL(for: id))
      retiredCameraIDs.remove(id)
    }
    var entries = files.filter {
      $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(".tmp.mp4")
    }
    .map { url -> (URL, Int, Date) in
      let values = try? url.resourceValues(forKeys: keys)
      return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
    }.sorted { $0.2 < $1.2 }
    var bytes = entries.reduce(0) { $0 + $1.1 }
    var count = entries.count
    while !entries.isEmpty && (bytes > byteLimit || count > countLimit) {
      let (url, size, _) = entries.removeFirst()
      let id = url.deletingPathExtension().lastPathComponent
      guard assets[id]?.value == nil else { continue }
      if (try? FileManager.default.removeItem(at: url)) != nil {
        bytes -= size
        count -= 1
      }
    }
    // Only this process's active encoder owns a temporary file. Clean up
    // interrupted exports from previous launches, never an active export.
    if encodingID == nil {
      for file in files where file.lastPathComponent.hasSuffix(".tmp.mp4") {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
}
