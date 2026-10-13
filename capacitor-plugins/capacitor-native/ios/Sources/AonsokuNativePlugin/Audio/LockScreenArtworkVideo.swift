import AVFoundation
import CoreGraphics
import Foundation

enum LockScreenArtworkError: Error {
    case encodingFailed
}

/// An audio-free, two-second H.264 clip holding a single frame. It is an asset
/// for the system artwork API; it never becomes an item in the audio player.
enum LockScreenArtworkVideo {
    private final class Request {
        var submitted = false
        var completion: ((Result<URL, Error>) -> Void)?

        init(_ completion: @escaping (Result<URL, Error>) -> Void) {
            self.completion = completion
        }

        func finish(_ result: Result<URL, Error>) {
            let callback = completion
            completion = nil
            callback?(result)
        }
    }

    static func write(
        image: CGImage, to url: URL, queue: DispatchQueue,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: image.width,
                    AVVideoHeightKey: image.height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 2_000_000,
                        AVVideoMaxKeyFrameIntervalKey: 1,
                    ],
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: image.width,
                    kCVPixelBufferHeightKey as String: image.height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ]
            )
            guard writer.canAdd(input) else { throw LockScreenArtworkError.encodingFailed }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? LockScreenArtworkError.encodingFailed
            }
            writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                let buffer
            else {
                writer.cancelWriting()
                throw LockScreenArtworkError.encodingFailed
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard
                let canvas = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer),
                    width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                )
            else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                writer.cancelWriting()
                throw LockScreenArtworkError.encodingFailed
            }
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let request = Request(completion)
            // Finish before MediaPlayer's approximately 30-second request
            // timeout even if an encoder stops requesting more input.
            queue.asyncAfter(deadline: .now() + 20) { [weak request, weak writer] in
                guard let request, request.completion != nil, let writer else { return }
                writer.cancelWriting()
                request.finish(.failure(LockScreenArtworkError.encodingFailed))
            }
            input.requestMediaDataWhenReady(on: queue) {
                guard request.completion != nil, !request.submitted else { return }
                if input.isReadyForMoreMediaData {
                    guard adaptor.append(buffer, withPresentationTime: .zero) else {
                        writer.cancelWriting()
                        request.finish(
                            .failure(writer.error ?? LockScreenArtworkError.encodingFailed))
                        return
                    }
                    // One sample spans the whole session. This avoids both
                    // redundant encoding and inter-frame quantization changes.
                    request.submitted = true
                    input.markAsFinished()
                    writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
                    writer.finishWriting {
                        queue.async {
                            if writer.status == .completed {
                                request.finish(.success(url))
                            } else {
                                request.finish(
                                    .failure(writer.error ?? LockScreenArtworkError.encodingFailed))
                            }
                        }
                    }
                } else if writer.status == .failed || writer.status == .cancelled {
                    request.finish(.failure(writer.error ?? LockScreenArtworkError.encodingFailed))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }
}
