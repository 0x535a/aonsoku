import CoreGraphics
import CoreImage
import CryptoKit
import Foundation

/// Captured by the system artwork handlers. A live asset pins its video file
/// against eviction, including after the player switches to another cover.
final class LockScreenArtworkAsset {
  let id: String
  let preview: CGImage
  let motion: Bool
  let backend: String
  var analysisReason: String?
  let format: LockScreenArtworkFormat
  fileprivate var source: CGImage?
  fileprivate var shouldContinue: () -> Bool = { true }
  private let store: LockScreenArtworkStore

  fileprivate init(
    id: String, preview: CGImage, source: CGImage?,
    format: LockScreenArtworkFormat, motion: Bool, backend: String = "camera",
    store: LockScreenArtworkStore
  ) {
    self.id = id
    self.preview = preview
    self.source = source
    self.format = format
    self.motion = motion
    self.backend = backend
    self.store = store
  }

  func requestVideo(_ completion: @escaping (URL?) -> Void) {
    store.requestVideo(for: self, completion: completion)
  }
}

final class LockScreenArtworkStore {
  static let shared = LockScreenArtworkStore()
  private let queue = DispatchQueue(label: "com.aonsoku.lock-screen-artwork", qos: .utility)
  private let requests = DispatchQueue(label: "com.aonsoku.artwork-file-requests", qos: .utility)
  private let directory: URL
  private let byteLimit: Int
  private let countLimit: Int
  private struct WeakAsset { weak var value: LockScreenArtworkAsset? }
  private var assets: [String: WeakAsset] = [:]
  private var pending: [(asset: LockScreenArtworkAsset, callbacks: [(URL?) -> Void])] = []
  private var encodingID: String?
  private var pressureObserver: NSObjectProtocol?
  private var textRegions: [String: [CGRect]] = [:]
  private var analyses: [String: LockScreenArtworkMotionAnalysis] = [:]
  private let policy = LockScreenArtworkMotionPolicy.shared

  init(directory: URL? = nil, byteLimit: Int = 24 * 1024 * 1024, countLimit: Int = 12) {
    // Application Support rather than temporary storage: URLs must remain
    // valid while MediaPlayer retains the corresponding artwork object.
    self.directory =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )[0].appendingPathComponent("AonsokuLockScreenArtwork", isDirectory: true)
    self.byteLimit = byteLimit
    self.countLimit = countLimit
    queue.async { self.trim() }
    pressureObserver = NotificationCenter.default.addObserver(
      forName: LockScreenArtworkMotionPolicy.resourcesChanged, object: nil, queue: nil
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
    data: Data, source: CGImage, format: LockScreenArtworkFormat = .tall,
    motion: Bool = false, backend: String = "camera",
    shouldContinue: @escaping () -> Bool = { true },
    completion: @escaping (LockScreenArtworkAsset?) -> Void
  ) {
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
          "\(motion ? "motion-v4-" + backend : "edge-v1")-\(format.width)x\(format.height)-\(digest)"
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
        let renderMeasurement = LockScreenArtworkMeasurement("image-extension")
        guard let preview = LockScreenArtworkRenderer.render(source, format: format) else {
          completion(nil)
          return
        }
        let asset = LockScreenArtworkAsset(
          id: id, preview: preview, source: motion ? source : nil,
          format: format, motion: motion, backend: backend, store: self)
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

  private func preparedAsset(_ asset: LockScreenArtworkAsset, video: URL?) -> LockScreenArtworkAsset
  {
    guard video == nil else { return asset }
    // A deferred or failed motion export still uses the proven immersive
    // static clip, with no inference/multi-frame work in system requests.
    let digest = asset.id.components(separatedBy: "-").last!
    let id = "edge-v1-\(asset.format.width)x\(asset.format.height)-\(digest)"
    if let existing = assets[id]?.value { return existing }
    let fallback = LockScreenArtworkAsset(
      id: id, preview: asset.preview, source: nil,
      format: asset.format, motion: false, store: self)
    fallback.shouldContinue = asset.shouldContinue
    assets[id] = WeakAsset(value: fallback)
    return fallback
  }

  fileprivate func requestVideo(
    for asset: LockScreenArtworkAsset, completion: @escaping (URL?) -> Void
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

  private func enqueue(_ asset: LockScreenArtworkAsset, completion: @escaping (URL?) -> Void) {
    let url = videoURL(for: asset.id)
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
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

  func hasReadyVideo(data: Data, format: LockScreenArtworkFormat, backend: String) -> Bool {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let id = "motion-v4-\(backend)-\(format.width)x\(format.height)-\(digest)"
    return (try? videoURL(for: id).resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 }
      ?? false
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
      finishEncoding(nil)
      return
    }
    #if os(iOS)
      if request.asset.motion,
        let tier = LockScreenArtworkTier.allCases.first(where: {
          $0.backend == request.asset.backend
        }),
        LockScreenArtworkModelManager.shared.modelURL(tier) == nil
      {
        LockScreenArtworkModelManager.shared.request(tier, automatic: true)
        finishEncoding(nil)
        return
      }
    #endif
    var depth: CIImage?
    if request.asset.motion, let source = request.asset.source {
      let digest = request.asset.backend + "-" + request.asset.id.components(separatedBy: "-").last!
      let analysis: LockScreenArtworkMotionAnalysis = autoreleasepool {
        if let cached = analyses[digest] { return cached }
        let measured = LockScreenArtworkMeasurement("analysis backend=\(request.asset.backend)")
        let result: LockScreenArtworkMotionAnalysis
        #if os(iOS)
          if let tier = LockScreenArtworkTier.allCases.first(where: {
            $0.backend == request.asset.backend
          }),
            let modelURL = LockScreenArtworkModelManager.shared.modelURL(tier)
          {
            let ratio = Double(source.width) / Double(source.height)
            if min(source.width, source.height) < 64 || ratio < 0.4 || ratio > 2.5 {
              result = .init(mask: nil, reason: "unsafe-source-geometry")
            } else {
              let model = LockScreenArtworkDepthModel.analyze(
                source,
                candidate: LockScreenArtworkDepthModel.candidate(tier), modelURL: modelURL,
                shouldContinue: { self.canGenerate(request.asset) })
              let content = request.asset.id.components(separatedBy: "-").last!
              if textRegions[content] == nil && self.policy.allowsGeneration
                && request.asset.shouldContinue()
              {
                if textRegions.count >= 8 { textRegions.removeAll() }
                textRegions[content] = LockScreenArtworkMotion.textRegions(source)
              }
              result = .init(
                mask: model.mask, reason: model.reason,
                protectedText: textRegions[content] ?? [])
            }
          } else {
            result = LockScreenArtworkMotion.analyze(source)
          }
        #else
          result = LockScreenArtworkMotion.analyze(source)
        #endif
        measured.finish("mode=\(result.mode) reason=\(result.reason)")
        if analyses.count >= 8 { analyses.removeAll() }
        analyses[digest] = result
        return result
      }
      request.asset.analysisReason = analysis.reason
      depth = LockScreenArtworkMotion.depthImage(
        analysis, source: source, format: request.asset.format)
    }
    let measured = LockScreenArtworkMeasurement(
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
      #if os(iOS)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: directory.path
        )
      #endif
      LockScreenArtworkVideo.write(
        image: request.asset.preview, to: temporary, queue: queue,
        motion: request.asset.motion, depth: depth,
        shouldContinue: { self.canGenerate(request.asset) }
      ) {
        result in
        self.queue.async {
          let final = self.videoURL(for: request.asset.id)
          var output: URL?
          do {
            _ = try result.get()
            #if os(iOS)
              try FileManager.default.setAttributes(
                [
                  .protectionKey: FileProtectionType
                    .completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: temporary.path
              )
            #endif
            try FileManager.default.moveItem(at: temporary, to: final)
            output = final
          } catch {
            // Leave ordinary static artwork installed on any failure.
            #if os(iOS)
              NativeLogger.shared.warn(
                "video export failed domain=\((error as NSError).domain) code=\((error as NSError).code)",
                source: "NowPlayingArtwork")
            #endif
            try? FileManager.default.removeItem(at: temporary)
          }
          measured.finish("success=\(output != nil)")
          request.asset.source = nil
          self.finishEncoding(output)
        }
      }
    } catch {
      #if os(iOS)
        NativeLogger.shared.warn(
          "video export setup failed domain=\((error as NSError).domain) code=\((error as NSError).code)",
          source: "NowPlayingArtwork")
      #endif
      try? FileManager.default.removeItem(at: temporary)
      finishEncoding(nil)
    }
  }

  private func finishEncoding(_ url: URL?) {
    let request = pending.removeFirst()
    encodingID = nil
    request.asset.source = nil
    for callback in request.callbacks { callback(url) }
    trim()
    encodeNext()
  }

  private func canGenerate(_ asset: LockScreenArtworkAsset) -> Bool {
    guard policy.allowsGeneration, asset.shouldContinue() else { return false }
    #if os(iOS)
      if let tier = LockScreenArtworkTier.allCases.first(where: { $0.backend == asset.backend }) {
        guard let ceiling = policy.effectiveTier else { return false }
        let ranks: [LockScreenArtworkTier: Int] = [.p6: 0, .p8: 1, .fp16: 2]
        return ranks[tier]! <= ranks[ceiling]!
      }
    #endif
    return true
  }

  private func trim() {
    assets = assets.filter { $0.value.value != nil }
    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys)
      )
    else { return }
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
