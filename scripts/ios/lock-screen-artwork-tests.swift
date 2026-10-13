import AVFoundation
import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(
            domain: "ArtworkTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func png(_ image: CGImage) -> Data {
    let result = NSMutableData()
    let target = CGImageDestinationCreateWithData(
        result, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(target, image, nil)
    precondition(CGImageDestinationFinalize(target))
    return result as Data
}

private func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes {
        let canvas = CGContext(
            data: $0.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private func fixture(width: Int, height: Int) -> CGImage {
    let canvas = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(
        colorsSpace: canvas.colorSpace,
        colors: [
            CGColor(red: 0.05, green: 0.18, blue: 0.32, alpha: 1),
            CGColor(red: 0.72, green: 0.42, blue: 0.25, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    canvas.drawLinearGradient(
        gradient, start: .zero,
        end: CGPoint(x: width, y: height), options: [])
    canvas.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.38, alpha: 1))
    canvas.fillEllipse(
        in: CGRect(
            x: Double(width) * 0.3, y: Double(height) * 0.3,
            width: Double(width) * 0.4, height: Double(height) * 0.4))
    // Detailed foreground and asymmetric edge stripes expose cropping,
    // orientation mistakes, and unintended repeated subjects.
    canvas.setFillColor(CGColor(gray: 0.9, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: max(1, width / 50), height: height))
    canvas.setFillColor(CGColor(gray: 0.08, alpha: 1))
    canvas.fill(
        CGRect(
            x: width - max(1, width / 50), y: 0,
            width: max(1, width / 50), height: height))
    return canvas.makeImage()!
}

private func prepare(
    _ store: LockScreenArtworkStore, data: Data, image: CGImage,
    format: LockScreenArtworkFormat = .tall
) async
    -> LockScreenArtworkAsset?
{
    await withCheckedContinuation { continuation in
        store.prepare(data: data, source: image, format: format) {
            continuation.resume(returning: $0)
        }
    }
}

private func video(_ asset: LockScreenArtworkAsset) async -> URL? {
    await withCheckedContinuation { continuation in
        asset.requestVideo { continuation.resume(returning: $0) }
    }
}

private func releasedVideo(_ store: LockScreenArtworkStore, image: CGImage) async -> URL {
    let asset = await prepare(store, data: png(image), image: image)!
    return await video(asset)!
}

@main
struct ArtworkTests {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let examples = [
            ("square", 600, 600), ("landscape", 900, 500), ("portrait", 400, 900),
            ("native-3x4", 600, 800), ("wide", 800, 100), ("tall", 100, 800), ("tiny", 1, 1),
        ]
        var images: [(String, CGImage, CGImage)] = []
        let started = Date()
        for format in [LockScreenArtworkFormat.tall, .square] {
            for (name, width, height) in examples {
                let source = fixture(width: width, height: height)
                let result = LockScreenArtworkRenderer.render(source, format: format)!
                try require(
                    result.width == format.width && result.height == format.height,
                    "\(name): incorrect output ratio")
                let rect = LockScreenArtworkRenderer.sourceRect(for: source, format: format)
                let w = Int(rect.width)
                let h = Int(rect.height)
                let scaled = CGContext(
                    data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                scaled.interpolationQuality = .high
                scaled.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
                let expected = pixels(scaled.makeImage()!)
                let actual = pixels(result)
                // Compare every pixel of the resampled source: no subject cropping,
                // deformation beyond integer rounding, or blur inside the source.
                for y in 0..<h {
                    for x in 0..<w {
                        let a = ((y + Int(rect.minY)) * 720 + x + Int(rect.minX)) * 4
                        let b = (y * w + x) * 4
                        for c in 0..<4 {
                            try require(
                                actual[a + c] == expected[b + c], "\(name): source pixel changed")
                        }
                    }
                }
                try require(
                    stride(from: 3, to: actual.count, by: 4).allSatisfy { actual[$0] == 255 },
                    "\(name): transparent hole in output")
                // Smooth source regions should not acquire a color step at the join.
                if rect.minY > 0 && w > 10 {
                    let x = Int(rect.midX)
                    for y in [Int(rect.minY), Int(rect.maxY)] {
                        for c in 0..<3 {
                            let delta = abs(
                                Int(actual[(y * 720 + x) * 4 + c])
                                    - Int(actual[((y - 1) * 720 + x) * 4 + c]))
                            try require(delta < 6, "\(name): hard edge at vertical join")
                        }
                    }
                }
                if format == .tall {
                    images.append((name, source, result))
                } else {
                    try png(result).write(to: output.appendingPathComponent(name + "-1x1.png"))
                }
            }
        }
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let cover = LockScreenArtworkRenderer.decode(fixtureData)!
        images.append(("repository-cover", cover, LockScreenArtworkRenderer.render(cover)!))
        try require(
            LockScreenArtworkRenderer.decode(Data([0, 1, 2])) == nil, "invalid image accepted")

        let huge = LockScreenArtworkRenderer.decode(png(fixture(width: 4000, height: 2000)))!
        try require(max(huge.width, huge.height) <= 1200, "large image decode was not bounded")
        let transparent = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        transparent.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        let flattened = pixels(LockScreenArtworkRenderer.render(transparent.makeImage()!)!)
        try require(
            stride(from: 3, to: flattened.count, by: 4).allSatisfy { flattened[$0] == 255 },
            "transparent image was not flattened")

        // EXIF orientation is applied before deriving the portrait geometry.
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, fixture(width: 160, height: 80),
            [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let oriented = LockScreenArtworkRenderer.decode(jpeg as Data)!
        try require(oriented.width == 80 && oriented.height == 160, "EXIF orientation lost")

        let store = LockScreenArtworkStore(directory: scratch, byteLimit: 1, countLimit: 1)
        var first: LockScreenArtworkAsset? = await prepare(store, data: fixtureData, image: cover)
        try require(first != nil, "preview preparation failed")
        let same = await prepare(store, data: fixtureData, image: cover)
        try require(first === same, "same album preparation was not coalesced")
        try require(
            !FileManager.default.fileExists(atPath: scratch.path),
            "video encoded before system request")
        async let a = video(same!)
        async let b = video(same!)
        let (urlA, urlB) = await (a, b)
        try require(urlA != nil && urlA == urlB, "concurrent video requests were not coalesced")
        let file = urlA!
        let movie = AVURLAsset(url: file)
        let videoTracks = try await movie.loadTracks(withMediaType: .video)
        let audioTracks = try await movie.loadTracks(withMediaType: .audio)
        let size = try await videoTracks[0].load(.naturalSize)
        let duration = try await movie.load(.duration)
        try require(
            size == CGSize(width: 720, height: 960), "encoded video has incorrect dimensions")
        try require(audioTracks.isEmpty, "artwork video contains audio")
        try require(abs(duration.seconds - 2) < 0.05, "unexpected artwork duration")
        let generator = AVAssetImageGenerator(asset: movie)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame0 = try await generator.image(at: .zero).image
        let frame1 = try await generator.image(at: CMTime(value: 1, timescale: 1)).image
        let p0 = pixels(frame0)
        let p1 = pixels(frame1)
        let preview = pixels(first!.preview)
        let motion =
            zip(p0, p1).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(p0.count)
        let error =
            zip(p0, preview).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
            / Double(p0.count)
        FileHandle.standardError.write(
            Data("Frame motion MAE=\(motion), preview MAE=\(error)\n".utf8))
        try require(motion < 1, "static artwork video visibly changes between frames")
        try require(error < 8, "video differs from preview (orientation/color)")
        let cached = await video(first!)
        try require(cached == file, "repeated request did not reuse disk video")

        let square = await prepare(store, data: fixtureData, image: cover, format: .square)!
        try require(square.id != first!.id, "square asset reused tall identity")
        try require(
            square.preview.width == 720 && square.preview.height == 720,
            "square preview ratio incorrect")
        let squareFile = await video(square)!
        try require(squareFile != file, "square video replaced tall video")
        let squareMovie = AVURLAsset(url: squareFile)
        let squareTracks = try await squareMovie.loadTracks(withMediaType: .video)
        let squareSize = try await squareTracks[0].load(.naturalSize)
        let squareDuration = try await squareMovie.load(.duration)
        let squareAudio = try await squareMovie.loadTracks(withMediaType: .audio)
        try require(
            squareSize == CGSize(width: 720, height: 720) && abs(squareDuration.seconds - 2) < 0.05
                && squareAudio.isEmpty,
            "square video is not a silent two-second 1:1 clip")
        let squareGenerator = AVAssetImageGenerator(asset: squareMovie)
        let squareFrame0 = try await squareGenerator.image(at: .zero).image
        let squareFrame1 = try await squareGenerator.image(at: CMTime(value: 1, timescale: 1)).image
        try require(pixels(squareFrame0) == pixels(squareFrame1), "square clip changes over time")

        let secondData = png(images[0].1)
        let second = await prepare(store, data: secondData, image: images[0].1)!
        try require(second.id != first!.id, "new content reused stale artwork ID")
        let secondURL = await video(second)!
        try require(
            FileManager.default.fileExists(atPath: file.path), "live first artwork was evicted")
        try require(
            FileManager.default.fileExists(atPath: secondURL.path),
            "live second artwork was evicted")
        first = nil
        // 'same' intentionally still holds the first asset: system retention
        // past a track switch must keep the file valid even above the budget.
        _ = await prepare(store, data: png(images[1].1), image: images[1].1)
        try require(
            FileManager.default.fileExists(atPath: file.path), "retained artwork URL invalidated")
        withExtendedLifetime(same) {}

        let evicting = LockScreenArtworkStore(
            directory: scratch.appendingPathComponent("eviction"), byteLimit: 1, countLimit: 1)
        let unpinnedURL = await releasedVideo(evicting, image: images[0].1)
        let next = await prepare(evicting, data: png(images[1].1), image: images[1].1)!
        try require(
            !FileManager.default.fileExists(atPath: unpinnedURL.path),
            "unpinned cache entry exceeded budget")
        withExtendedLifetime(next) {}

        let failing = LockScreenArtworkStore(directory: URL(fileURLWithPath: "/dev/null/artwork"))
        let unavailable = await prepare(failing, data: secondData, image: images[0].1)!
        let failedURL = await video(unavailable)
        try require(failedURL == nil, "encoding failure did not return nil fallback")

        // Restart reuse requires no live memory entry from the original store.
        let restarted = LockScreenArtworkStore(directory: scratch)
        let restored = await prepare(restarted, data: fixtureData, image: cover)!
        let reused = await video(restored)
        try require(reused == file, "video cache not reused after store restart")

        let sheet = CGContext(
            data: nil, width: 1600, height: 1000, bitsPerComponent: 8,
            bytesPerRow: 1600 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sheet.setFillColor(CGColor(gray: 0.12, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        for (index, example) in images.enumerated() {
            let x = (index % 4) * 400
            let y = 500 - (index / 4) * 500
            sheet.draw(example.2, in: CGRect(x: x + 200, y: y + 90, width: 180, height: 240))
            let scale = min(180.0 / Double(example.1.width), 240.0 / Double(example.1.height))
            let w = Double(example.1.width) * scale
            let h = Double(example.1.height) * scale
            sheet.draw(
                example.1,
                in: CGRect(
                    x: Double(x) + 100 - w / 2, y: Double(y) + 210 - h / 2,
                    width: w, height: h))
            sheet.textPosition = CGPoint(x: x + 20, y: y + 55)
            let label = NSAttributedString(
                string: example.0 + "   →   3:4",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white,
                ])
            CTLineDraw(CTLineCreateWithAttributedString(label), sheet)
            try png(example.2).write(to: output.appendingPathComponent(example.0 + ".png"))
        }
        try png(sheet.makeImage()!).write(to: output.appendingPathComponent("contact-sheet.png"))
        try Data(contentsOf: file).write(
            to: output.appendingPathComponent("static-artwork.mp4"), options: .atomic)
        print(
            "PASS: 3:4 + 1:1 source preservation, seams, ratios, transparency, bounded decode, EXIF, lazy/coalesced video, static frames, cache reuse/eviction, live-file protection, failure fallback"
        )
        print(
            String(
                format: "Native validation completed in %.2fs. QA artifacts: %@",
                Date().timeIntervalSince(started), output.path))
    }
}
