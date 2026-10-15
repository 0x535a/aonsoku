import Foundation

/// The macOS host sets its app-scoped root once before touching singletons.
enum ArtworkStorage {
  static var root: URL?
  static var license: URL?
  static func directory(_ name: String) -> URL {
    let base =
      root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent(name, isDirectory: true)
  }
}

/// Thresholds use physical RAM, never free RAM or model file size. Devices
/// reporting between 4 and 6 GiB use P8; above 6 GiB is the 8+ GB device class.
enum ArtworkTier: String, CaseIterable, Codable {
  case fp16, p8, p6
  var backend: String { "dav2-\(self == .fp16 ? "f16" : rawValue)" }
  var lower: Self { self == .fp16 ? .p8 : .p6 }
  static func automatic(memory: UInt64) -> Self {
    if memory <= 4 * 1024 * 1024 * 1024 { return .p6 }
    if memory <= 6 * 1024 * 1024 * 1024 { return .p8 }
    return .fp16
  }

}

struct ArtworkOptions: Codable {
  var immersiveEnabled = true
  // Opt in before fetching any optional model or generating motion.
  var dynamicEnabled = false
  var quality = "auto"
  var wifiOnly = true
  var motionAmplitude = 1.0
  var motionSpeed = 1.0
  var motionParameters: ArtworkMotionParameters {
    .init(amplitude: motionAmplitude, speed: motionSpeed)
  }
  init() {}
  private enum CodingKeys: String, CodingKey {
    case immersiveEnabled, dynamicEnabled, quality, wifiOnly, motionAmplitude, motionSpeed
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    immersiveEnabled = try values.decodeIfPresent(Bool.self, forKey: .immersiveEnabled) ?? true
    dynamicEnabled = try values.decodeIfPresent(Bool.self, forKey: .dynamicEnabled) ?? false
    quality = try values.decodeIfPresent(String.self, forKey: .quality) ?? "auto"
    wifiOnly = try values.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
    let amplitude = try values.decodeIfPresent(Double.self, forKey: .motionAmplitude) ?? 1
    let speed = try values.decodeIfPresent(Double.self, forKey: .motionSpeed) ?? 1
    let parameters = ArtworkMotionParameters(amplitude: amplitude, speed: speed)
    motionAmplitude = parameters.amplitude
    motionSpeed = parameters.speed
  }
}

/// One complete loop at 24fps. All speeds stay within Apple's <30s guidance.
struct ArtworkMotionParameters {
  static let speeds: [Double] = [0.5, 0.75, 1, 1.5, 2]
  let amplitude: Double
  let speed: Double
  init(amplitude: Double = 1, speed: Double = 1) {
    self.amplitude = amplitude.isFinite ? (min(2, max(0.5, amplitude)) * 100).rounded() / 100 : 1
    self.speed = Self.speeds.contains(speed) ? speed : 1
  }
  var frameCount: Int { Int((144 / speed).rounded()) }
  var duration: Double { Double(frameCount) / 24 }
  var cacheKey: String { "a\(Int((amplitude * 100).rounded()))-s\(Int((speed * 100).rounded()))" }
}

final class ArtworkSettings {
  static let shared = ArtworkSettings()
  static let changed = Notification.Name("AonsokuArtworkSettingsChanged")
  private let lock = NSLock()
  private var options = ArtworkOptions()

  private init() {
    if let data = try? Data(
      contentsOf: ArtworkStorage.directory("preferences").appendingPathComponent("artwork.json")),
      let restored = try? JSONDecoder().decode(ArtworkOptions.self, from: data)
    {
      options = restored
    }
  }
  var value: ArtworkOptions {
    lock.lock()
    defer { lock.unlock() }
    return options
  }
  func configure(_ update: [String: Any]) throws {
    lock.lock()
    var next = options
    lock.unlock()
    if let enabled = update["immersiveEnabled"] as? Bool { next.immersiveEnabled = enabled }
    if let enabled = update["dynamicEnabled"] as? Bool { next.dynamicEnabled = enabled }
    if let wifiOnly = update["wifiOnly"] as? Bool { next.wifiOnly = wifiOnly }
    if let quality = update["quality"] as? String {
      guard quality == "auto" || ArtworkTier(rawValue: quality) != nil else {
        throw NSError(domain: "ArtworkSettings", code: 1)
      }
      next.quality = quality
    }
    if let amplitude = update["motionAmplitude"] as? Double {
      guard amplitude.isFinite, (0.5...2).contains(amplitude) else {
        throw NSError(domain: "ArtworkSettings", code: 2)
      }
      next.motionAmplitude = (amplitude * 100).rounded() / 100
    }
    if let speed = update["motionSpeed"] as? Double {
      guard ArtworkMotionParameters.speeds.contains(speed) else {
        throw NSError(domain: "ArtworkSettings", code: 3)
      }
      next.motionSpeed = speed
    }
    let data = try JSONEncoder().encode(next)
    let folder = ArtworkStorage.directory("preferences")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent("artwork.json"), options: .atomic)
    lock.lock()
    options = next
    lock.unlock()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Self.changed, object: nil)
    }
  }
}

/// Explicit consumer intent; cache reads and system file callbacks never add work.
final class ArtworkDemand {
  static let shared = ArtworkDemand()
  static let changed = Notification.Name("ArtworkGenerationDemandChanged")
  private let lock = NSLock()
  private var cover: String?
  private var entries: [String: (owner: UUID, cover: String, motion: Bool)] = [:]
  func setCurrentCover(_ value: String?) {
    lock.lock()
    cover = value
    lock.unlock()
  }
  var requested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.values.contains { $0.cover == cover }
  }
  var dynamicRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.values.contains { $0.cover == cover && $0.motion }
  }
  func add(owner: UUID, cover: String, motion: Bool) -> String? {
    lock.lock()
    guard entries.values.filter({ $0.owner == owner }).count < 8 else {
      lock.unlock()
      return nil
    }
    let id = UUID().uuidString
    entries[id] = (owner, cover, motion)
    lock.unlock()
    notify()
    return id
  }
  func remove(_ id: String, owner: UUID) {
    lock.lock()
    let found = entries[id]?.owner == owner
    if found { entries.removeValue(forKey: id) }
    lock.unlock()
    if found { notify() }
  }
  func releaseAll(owner: UUID) {
    lock.lock()
    let count = entries.count
    entries = entries.filter { $0.value.owner != owner }
    let changed = entries.count != count
    lock.unlock()
    if changed { notify() }
  }
  private func notify() {
    DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
  }
}
