import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func save(_ image: CGImage, to url: URL) throws {
  guard
    let target = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else {
    throw NSError(domain: "Experiment", code: 1)
  }
  CGImageDestinationAddImage(target, image, nil)
  guard CGImageDestinationFinalize(target) else { throw NSError(domain: "Experiment", code: 2) }
}

@main
struct MotionCoverExperiment {
  static func main() async throws {
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let data = try Data(contentsOf: sourceURL)
    guard let image = LockScreenArtworkRenderer.decode(data) else {
      throw NSError(domain: "Decode", code: 1)
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try save(image, to: output.appendingPathComponent("source.png"))
    let context = CIContext(options: [.cacheIntermediates: false])
    let text = LockScreenArtworkMotion.textRegions(image)
    let boxes = text.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
    try JSONSerialization.data(
      withJSONObject: ["origin": "bottom-left", "normalized": true, "regions": boxes],
      options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: output.appendingPathComponent("text-regions.json"))
    let candidates = ["camera"] + LockScreenArtworkDepthModel.candidates.map { $0.id }
    var results: [[String: Any]] = []
    for backend in candidates {
      let analysis: LockScreenArtworkMotionAnalysis = autoreleasepool {
        if let candidate = LockScreenArtworkDepthModel.candidates.first(where: { $0.id == backend })
        {
          let model = LockScreenArtworkDepthModel.analyze(
            image, candidate: candidate, benchmark: true)
          return LockScreenArtworkMotionAnalysis(
            mask: model.mask, reason: model.reason, protectedText: text)
        }
        return LockScreenArtworkMotion.analyze(image)
      }
      let directory = output.appendingPathComponent(backend, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let mask = analysis.mask {
        try save(mask, to: directory.appendingPathComponent("depth-normalized.png"))
      }
      for format in [LockScreenArtworkFormat.square, .tall] {
        guard let preview = LockScreenArtworkRenderer.render(image, format: format) else {
          throw NSError(domain: "Render", code: 1)
        }
        let bounds = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        let depth = LockScreenArtworkMotion.depthImage(analysis, source: image, format: format)
        try save(preview, to: directory.appendingPathComponent("canvas-\(format.height).png"))
        if let depth, let rendered = context.createCGImage(depth, from: bounds) {
          try save(rendered, to: directory.appendingPathComponent("field-\(format.height).png"))
        }
        for index in [0, 36, 72, 108, 143] {
          let frame = LockScreenArtworkMotion.frame(
            preview, depth: depth, phase: Double(index) / 144)
          if let rendered = context.createCGImage(frame, from: bounds) {
            try save(
              rendered, to: directory.appendingPathComponent("frame-\(format.height)-\(index).png"))
          }
        }
        let movie = directory.appendingPathComponent("motion-\(format.height).mp4")
        if FileManager.default.fileExists(atPath: movie.path) {
          try FileManager.default.removeItem(at: movie)
        }
        let measurement = LockScreenArtworkMeasurement("experiment-encode backend=\(backend)")
        let encoded: Result<URL, Error> = await withCheckedContinuation { continuation in
          LockScreenArtworkVideo.write(
            image: preview, to: movie,
            queue: DispatchQueue(label: "experiment.encode"), motion: true, depth: depth
          ) {
            continuation.resume(returning: $0)
          }
        }
        _ = try encoded.get()
        measurement.finish("format=\(format.label)")
        results.append([
          "backend": backend, "format": format.label, "height": format.height,
          "mode": analysis.mode, "reason": analysis.reason,
          "videoBytes":
            (try movie.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0,
        ])
      }
    }
    try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("results.json"), options: .atomic)
    print("Experiment complete: \(output.path)")
  }
}
