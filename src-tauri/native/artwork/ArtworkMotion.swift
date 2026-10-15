import AppKit
import CoreGraphics
import CoreImage
import Darwin
import Foundation
import Vision

/// Only the small normalized depth map and text geometry survive inference.
struct ArtworkMotionAnalysis {
  let mask: CGImage?
  let reason: String
  let protectedText: [CGRect]
  init(mask: CGImage?, reason: String, protectedText: [CGRect] = []) {
    self.mask = mask
    self.reason = reason
    self.protectedText = protectedText
  }
  var mode: String { mask == nil ? "camera" : "parallax" }
  var canCache: Bool {
    mask != nil || reason == "unsafe-source-geometry" || reason == "camera-fallback-no-depth"
  }
}

enum ArtworkMotion {
  static let frameRate = 24
  static let frameCount = 144
  static let duration = 6.0
  private static let context = CIContext(options: [.cacheIntermediates: false])
  // Unlike CIDisplacementDistortion (a gradient/bump effect), this kernel
  // translates flat foreground/background regions by their actual depth.
  private static let kernel: CIKernel? = {
    let source = """
      #include <CoreImage/CoreImage.h>
      using namespace metal;
      [[stitchable]] float4 coverMotion(coreimage::sampler image,
          coreimage::sampler depth, float2 offset, coreimage::destination dest) {
          float2 p = dest.coord();
          float d = depth.sample(depth.transform(p)).r;
          return image.sample(image.transform(p + offset * (2.0 * d - 1.0)));
      }
      """
    ArtworkDiagnostics.shared.setRenderer("compiling Metal kernel")
    do {
      let result = try CIKernel.kernels(withMetalString: source).first
      ArtworkDiagnostics.shared.setRenderer(result == nil ? "unavailable" : "Metal ready")
      return result
    } catch {
      ArtworkDiagnostics.shared.setRenderer("Metal failed: \(error.localizedDescription)")
      return nil
    }
  }()
  static var parallaxAvailable: Bool { kernel != nil }

  /// Normalized Vision coordinates, origin at bottom-left. Never record text.
  static func textRegions(_ image: CGImage) -> [CGRect] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    if #available(iOS 16.0, macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    let languages = ["en-US", "ja-JP", "zh-Hans", "zh-Hant"].filter { supported.contains($0) }
    if !languages.isEmpty { request.recognitionLanguages = languages }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let detection = VNDetectTextRectanglesRequest()
    guard (try? handler.perform([request, detection])) != nil else { return [] }
    var regions = (request.results ?? []).compactMap { observation -> CGRect? in
      guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3,
        candidate.string.filter({ !$0.isWhitespace }).count >= 2
      else { return nil }
      return observation.boundingBox
    }
    // Stylized/boxed title lettering can have low OCR confidence. Use
    // detected horizontal text lines too; avoid isolated eye/circle shapes.
    for result in detection.results ?? [] {
      let box = result.boundingBox
      if box.width > 0.08 && box.height > 0.01 && box.width > box.height * 1.8 {
        regions.append(box)
      }
    }
    return regions
  }

  static func analyze(_ image: CGImage) -> ArtworkMotionAnalysis {
    .init(mask: nil, reason: "camera-fallback-no-depth")
  }

  static func depthImage(
    _ analysis: ArtworkMotionAnalysis, source: CGImage,
    format: ArtworkFormat
  ) -> CIImage? {
    guard let mask = analysis.mask else { return nil }
    let rect = ArtworkRenderer.sourceRect(for: source, format: format)
    // Depth is scalar data, not a display image. Disabling its color-space
    // conversion keeps 0.5 neutral instead of gamma-shifting it to ~0.21.
    let field = CIImage(cgImage: mask, options: [.colorSpace: NSNull()]).transformed(
      by: CGAffineTransform(
        scaleX: rect.width / Double(mask.width), y: rect.height / Double(mask.height))
    )
    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    .composited(over: CIImage(color: .black))
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
    .cropped(to: CGRect(x: 0, y: 0, width: format.width, height: format.height))
    guard !analysis.protectedText.isEmpty else { return field }
    var protection = CIImage(color: .black)
    for text in analysis.protectedText {
      let box = CGRect(
        x: rect.minX + text.minX * rect.width,
        y: rect.minY + text.minY * rect.height,
        width: text.width * rect.width, height: text.height * rect.height
      )
      .insetBy(dx: -12, dy: -12)
      protection = CIImage(color: .white).cropped(to: box).composited(over: protection)
    }
    protection = protection.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
    // Neutral depth has zero relative shift. Camera motion still moves all
    // glyphs rigidly together; soft margins avoid a sharp displacement seam.
    return CIImage(
      color: CIColor(
        red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
        colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!
    )
    .applyingFilter(
      "CIBlendWithMask",
      parameters: [
        kCIInputBackgroundImageKey: field, kCIInputMaskImageKey: protection,
      ]
    ).cropped(to: field.extent)
  }

  /// The function is periodic in phase; the next frame after 143 is frame 0.
  /// A tiny overscan hides displaced borders without stretching the subject.
  static func frame(
    _ image: CGImage, depth: CIImage?, phase: Double,
    parameters: ArtworkMotionParameters = .init()
  ) -> CIImage {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let input = CIImage(cgImage: image).clampedToExtent()
    let angle = phase * 2 * Double.pi
    let factor =
      (depth == nil ? 1 : parameters.amplitude) * Double(min(image.width, image.height)) / 720
    let amplitude = (depth == nil ? 4.0 : 1.5) * factor
    let cameraX = amplitude * sin(angle)
    let cameraY = amplitude * sin(2 * angle) * 0.5
    // Restore the smooth periodic zoom. Zoom is dimensionless: only pixel
    // displacement scales with output resolution, not the zoom percentage.
    let zoomAmplitude = depth == nil ? 1 : parameters.amplitude
    let scale = depth == nil
      ? 1.025 + 0.0125 * (1 - cos(angle))
      : 1 + 0.04 * zoomAmplitude + 0.004 * zoomAmplitude * (1 - cos(angle))
    let transform = CGAffineTransform(
      translationX: bounds.midX + cameraX,
      y: bounds.midY + cameraY
    )
    .scaledBy(x: scale, y: scale)
    .translatedBy(x: -bounds.midX, y: -bounds.midY)
    let camera = input.transformed(by: transform)
    if let depth, let kernel,
      let warped = kernel.apply(
        extent: bounds,
        roiCallback: { index, rect in
          index == 0 ? rect.insetBy(dx: -14 * factor, dy: -14 * factor) : rect
        },
        arguments: [
          camera, depth,
          CIVector(x: 10 * factor * sin(angle), y: 4 * factor * sin(2 * angle)),
        ])
    {
      return warped.cropped(to: bounds)
    }
    return camera.cropped(to: bounds)
  }
}

/// Main-thread lifecycle snapshots are read by the utility encoder. Returning
/// to the foreground retries preparation; system URL handlers never run AI.
final class ArtworkMotionPolicy {
  static let shared = ArtworkMotionPolicy()
  private let lock = NSLock()
  private var foreground = true
  private var memoryPauseUntil = Date.distantPast
  private var memoryDowngradeUntil = Date.distantPast
  private var observers: [NSObjectProtocol] = []
  private var reduceMotion = false
  private var pressureSource: DispatchSourceMemoryPressure?

  private init() {
    // Initialized by the host on AppKit's main thread. All worker reads use
    // these snapshots rather than touching NSApplication from an encoder.
    foreground = !NSApplication.shared.isHidden
    reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let center = NotificationCenter.default
    for name in [
      NSApplication.didUnhideNotification, NSApplication.didHideNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          guard let self else { return }
          self.lock.lock()
          self.foreground = !NSApplication.shared.isHidden
          self.lock.unlock()
          center.post(name: Self.resourcesChanged, object: nil)
        })
    }
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.lock.lock()
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.lock.unlock()
        center.post(name: Self.resourcesChanged, object: nil)
      })
    let pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    pressure.setEventHandler { [weak self] in self?.noteMemoryPressure() }
    pressureSource = pressure
    pressure.resume()
  }

  static let resourcesChanged = Notification.Name("AonsokuArtworkResourcesChanged")
  private func noteMemoryPressure() {
    lock.lock()
    memoryPauseUntil = Date().addingTimeInterval(60)
    memoryDowngradeUntil = Date().addingTimeInterval(180)
    lock.unlock()
    NotificationCenter.default.post(name: Self.resourcesChanged, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 61) {
      NotificationCenter.default.post(name: Self.resourcesChanged, object: nil)
    }
  }
  private var availableMemory: UInt64? {
    // Desktop headroom uses host VM pages, not iOS process memory limits.
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(vm_kernel_page_size)
  }

  var resolutionBudgetBytes: UInt64 {
    min(
      ProcessInfo.processInfo.physicalMemory / 8,
      (availableMemory ?? ProcessInfo.processInfo.physicalMemory / 4) / 4)
  }

  var generationReason: String {
    lock.lock()
    let active = foreground
    let paused = Date() <= memoryPauseUntil
    lock.unlock()
    if paused { return "memoryPressure" }
    if !active { return "background" }
    if ProcessInfo.processInfo.thermalState.rawValue >= 2 { return "thermal" }
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return "lowPower" }
    if !allowsPlayback { return "reduceMotion" }
    if effectiveTier == nil { return "memoryPressure" }
    return "ready"
  }
  var effectiveTier: ArtworkTier? {
    lock.lock()
    let pressured = Date() <= memoryPauseUntil
    let recovering = Date() <= memoryDowngradeUntil
    lock.unlock()
    if pressured { return nil }
    var chosen =
      ArtworkTier(rawValue: ArtworkSettings.shared.value.quality)
      ?? ArtworkTier.automatic(memory: ProcessInfo.processInfo.physicalMemory)
    if let headroom = availableMemory {
      if headroom < 512 * 1024 * 1024 { return nil }
      if headroom < 1024 * 1024 * 1024 {
        chosen = .p6
      } else if headroom < 2 * 1024 * 1024 * 1024 && chosen == .fp16 {
        chosen = .p8
      }
    }
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    if thermal >= 2 { return nil }
    return recovering ? .p6 : (thermal == 1 ? chosen.lower : chosen)
  }

  var allowsGeneration: Bool {
    lock.lock()
    let allowed = foreground && Date() > memoryPauseUntil
    lock.unlock()
    return allowed && allowsPlayback && effectiveTier != nil
      && ProcessInfo.processInfo.thermalState.rawValue < 2
  }

  var allowsStaticGeneration: Bool {
    lock.lock()
    defer { lock.unlock() }
    return foreground && Date() > memoryPauseUntil
  }

  var allowsPlayback: Bool {
    lock.lock()
    let reduced = reduceMotion || Date() <= memoryPauseUntil
    lock.unlock()
    return !reduced && !ProcessInfo.processInfo.isLowPowerModeEnabled
      && ProcessInfo.processInfo.thermalState.rawValue < 2
  }
}

/// Revision cancellation without reading plugin/player state on a worker.
final class ArtworkGeneration {
  private let lock = NSLock()
  private var revision = 0
  func update(_ revision: Int) {
    lock.lock()
    self.revision = revision
    lock.unlock()
  }
  func contains(_ revision: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return self.revision == revision
  }
}
