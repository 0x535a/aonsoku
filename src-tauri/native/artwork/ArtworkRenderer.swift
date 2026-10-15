import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum ArtworkFormat {
  case tall
  case square

  var width: Int { 720 }
  var height: Int { self == .tall ? 960 : 720 }
  var label: String { self == .tall ? "3:4" : "1:1" }
}

/// A single continuous image: aspect-fit the source, then extend its actual
/// edge pixels. Blur increases only as we move away from the source boundary.
/// There is no cropped background image or foreground card to join together.
enum ArtworkRenderer {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1200,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  }

  static func sourceRect(for image: CGImage, format: ArtworkFormat = .tall) -> CGRect {
    let width = format.width
    let height = format.height
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    let w = max(1, min(width, Int((Double(image.width) * scale).rounded())))
    let h = max(1, min(height, Int((Double(image.height) * scale).rounded())))
    return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
  }

  static func render(_ image: CGImage, format: ArtworkFormat = .tall) -> CGImage? {
    let width = format.width
    let height = format.height
    let rect = sourceRect(for: image, format: format)
    let w = Int(rect.width)
    let h = Int(rect.height)
    let left = Int(rect.minX)
    let bottom = Int(rect.minY)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    var source = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = source.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let canvas = CGContext(
          data: bytes.baseAddress, width: w, height: h,
          bitsPerComponent: 8, bytesPerRow: w * 4,
          space: colorSpace, bitmapInfo: bitmapInfo
        )
      else { return false }
      // Transparent artwork is flattened consistently for the JPEG/video.
      canvas.setFillColor(CGColor(gray: 0, alpha: 1))
      canvas.fill(CGRect(x: 0, y: 0, width: w, height: h))
      canvas.interpolationQuality = .high
      canvas.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }

    let band = max(1, Double(min(w, h)) * 0.12)
    let reflectionBand = max(1, Double(min(w, h)) * 0.025)
    func coordinate(_ position: Int, start: Int, length: Int) -> Int {
      let local = position - start
      if local >= 0 && local < length { return local }
      let distance = local < 0 ? -local : local - length + 1
      // Reflect a narrow band, gradually stretching it outward. This
      // continues edge texture without repeating the whole album/subject.
      let inset = min(
        length - 1, Int(reflectionBand * (1 - exp(-Double(distance) / reflectionBand))))
      return local < 0 ? inset : length - 1 - inset
    }
    let xs = (0..<width).map { coordinate($0, start: left, length: w) }
    let ys = (0..<height).map { coordinate($0, start: bottom, length: h) }
    var extended = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let src = (ys[y] * w + xs[x]) * 4
        let dst = (y * width + x) * 4
        for c in 0..<3 { extended[dst + c] = source[src + c] }
      }
    }
    func makeImage(_ pixels: [UInt8]) -> CGImage? {
      guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
      return CGImage(
        width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
      )
    }
    guard let base = makeImage(extended) else { return nil }
    let input = CIImage(cgImage: base)
    let filtered = input.clampedToExtent().applyingFilter(
      "CIGaussianBlur", parameters: [kCIInputRadiusKey: band * 0.45]
    ).cropped(to: input.extent)
    var blurred = [UInt8](repeating: 0, count: extended.count)
    blurred.withUnsafeMutableBytes { bytes in
      context.render(
        filtered, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
        bounds: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }
    for y in 0..<height {
      let dy = max(0, bottom - y, y - (bottom + h - 1))
      for x in 0..<width {
        let dx = max(0, left - x, x - (left + w - 1))
        guard dx > 0 || dy > 0 else { continue }
        let t = min(1, hypot(Double(dx), Double(dy)) / band)
        let blend = t * t * (3 - 2 * t)
        let offset = (y * width + x) * 4
        for c in 0..<3 {
          extended[offset + c] = UInt8(
            (Double(extended[offset + c]) * (1 - blend)
              + Double(blurred[offset + c]) * blend).rounded())
        }
      }
    }
    return makeImage(extended)
  }
}
