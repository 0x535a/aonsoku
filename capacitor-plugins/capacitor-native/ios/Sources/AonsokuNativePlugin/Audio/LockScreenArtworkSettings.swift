import Foundation

/// Thresholds use physical RAM, never free RAM or model file size. Devices
/// reporting between 4 and 6 GiB use P8; above 6 GiB is the 8+ GB device class.
enum LockScreenArtworkTier: String, CaseIterable, Codable {
  case fp16, p8, p6
  var backend: String { "dav2-\(self == .fp16 ? "f16" : rawValue)" }
  var lower: Self { self == .fp16 ? .p8 : .p6 }
  static func automatic(memory: UInt64) -> Self {
    if memory <= 4 * 1024 * 1024 * 1024 { return .p6 }
    if memory <= 6 * 1024 * 1024 * 1024 { return .p8 }
    return .fp16
  }
  static func select(
    quality: String, memory: UInt64, thermal: Int,
    memoryPressure: Bool = false, recovering: Bool = false,
    availableMemory: UInt64? = nil
  ) -> Self? {
    guard thermal < 2, !memoryPressure else { return nil }
    var chosen = Self(rawValue: quality) ?? automatic(memory: memory)
    if let availableMemory {
      if availableMemory < 96 * 1024 * 1024 { return nil }
      if availableMemory < 192 * 1024 * 1024 {
        chosen = .p6
      } else if availableMemory < 320 * 1024 * 1024 && chosen == .fp16 {
        chosen = .p8
      }
    }
    if recovering { return .p6 }
    return thermal == 1 ? chosen.lower : chosen
  }
}

struct LockScreenArtworkOptions: Codable {
  var immersiveEnabled = true
  // Opt in before fetching any optional model or generating motion.
  var dynamicEnabled = false
  var quality = "auto"
  var wifiOnly = true
}

final class LockScreenArtworkSettings {
  static let shared = LockScreenArtworkSettings()
  static let changed = Notification.Name("AonsokuLockScreenArtworkSettingsChanged")
  private let lock = NSLock()
  private var options = LockScreenArtworkOptions()
  private let key = "ios-lock-screen-artwork"

  private init() {
    #if os(iOS)
      if let raw = PreferencesManager.shared.getString(key), let data = raw.data(using: .utf8),
        let restored = try? JSONDecoder().decode(LockScreenArtworkOptions.self, from: data)
      {
        options = restored
      }
    #endif
  }
  var value: LockScreenArtworkOptions {
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
      guard quality == "auto" || LockScreenArtworkTier(rawValue: quality) != nil else {
        throw NSError(domain: "ArtworkSettings", code: 1)
      }
      next.quality = quality
    }
    let data = try JSONEncoder().encode(next)
    lock.lock()
    options = next
    lock.unlock()
    #if os(iOS)
      PreferencesManager.shared.setValue(key, value: String(decoding: data, as: UTF8.self))
    #endif
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Self.changed, object: nil)
    }
  }
}
