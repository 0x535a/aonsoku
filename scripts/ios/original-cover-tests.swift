import Foundation
import CoreGraphics
import ImageIO
import GRDB

struct ServerCredentials {
    let serverUrl = "https://cover-qa.invalid"
    let username = "fixture"
    let password = "fixture"
    let authType = "token"
    let protocolVersion = "1.16.0"
}
enum KeychainManager { static func retrieve() -> ServerCredentials? { ServerCredentials() } }
final class NativeLogger {
    static let shared = NativeLogger()
    func info(_ message: String, source: String) {}
}

final class FixtureURLProtocol: URLProtocol {
    static var image = Data()
    static var requests: [URL] = []
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.fail ? 503 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.image)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct OriginalCoverTests {
    static func image(_ width: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let database = try DatabasePool(path: work.appendingPathComponent("cache.sqlite").path)
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE cacheMeta (key TEXT PRIMARY KEY, id TEXT NOT NULL, type TEXT NOT NULL, source TEXT NOT NULL, triggersJson TEXT, coverSize TEXT, sizeBytes INTEGER NOT NULL, cachedAt INTEGER NOT NULL, lastAccessedAt INTEGER NOT NULL, removedFromServer BOOLEAN)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let manager = ImageCacheManager(db: database, session: URLSession(configuration: config), directory: work.appendingPathComponent("images"))
        let thumbnail = image(100)
        let full = image(1600)
        try thumbnail.write(to: directory.appendingPathComponent("thumbnail.png"))
        try full.write(to: directory.appendingPathComponent("original.png"))
        _ = try manager.storeCoverImage(coverArtId: "cover", data: thumbnail, contentType: "image/png", coverSize: "100")
        precondition(!CoverImageQuality.isOriginal(manager.readCoverImage(coverArtId: "cover")?.quality), "Thumbnail must not qualify for immersion")
        FixtureURLProtocol.image = full
        _ = try await manager.downloadCoverImage(coverArtId: "cover", size: CoverImageQuality.original)
        let request = URLComponents(url: FixtureURLProtocol.requests.last!, resolvingAgainstBaseURL: false)!
        precondition(!request.queryItems!.contains { $0.name == "size" }, "Original request must omit size")
        precondition(request.queryItems!.contains { $0.name == "id" && $0.value == "cover" })
        var snapshot = manager.readCoverImage(coverArtId: "cover")!
        precondition(CoverImageQuality.isOriginal(snapshot.quality) && snapshot.data == full)
        _ = try manager.storeCoverImage(coverArtId: "cover", data: thumbnail, contentType: "image/jpeg", coverSize: "800")
        snapshot = manager.readCoverImage(coverArtId: "cover")!
        precondition(snapshot.data == full && snapshot.quality == "original", "Late thumbnails must not downgrade originals")
        let otherManager = ImageCacheManager(db: database, directory: work.appendingPathComponent("images"))
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            _ = try! otherManager.storeCoverImage(coverArtId: "cover", data: thumbnail,
                contentType: "image/png", coverSize: index % 2 == 0 ? "100" : "1200")
        }
        precondition(manager.readCoverImage(coverArtId: "cover")!.data == full, "Cross-instance writes must be serialized")
        FixtureURLProtocol.fail = true
        do { _ = try await manager.downloadCoverImage(coverArtId: "cover", size: "original"); preconditionFailure("503 must fail") }
        catch { precondition(manager.readCoverImage(coverArtId: "cover")!.data == full) }
        do { _ = try manager.storeCoverImage(coverArtId: "cover", data: Data("not an image".utf8), contentType: "image/png", coverSize: "original"); preconditionFailure("Invalid images must fail") }
        catch { precondition(manager.readCoverImage(coverArtId: "cover")!.data == full) }
        _ = try manager.storeCoverImage(coverArtId: "small-original", data: thumbnail, contentType: "image/png", coverSize: "original")
        precondition(CoverImageQuality.isOriginal(manager.readCoverImage(coverArtId: "small-original")!.quality), "A small real original must not wait forever")
        let source = URL(string: "https://cover-qa.invalid/rest/getCoverArt?id=cover&size=300&t=fixture")!
        let unrestricted = URLComponents(url: CoverImageQuality.unrestrictedURL(source), resolvingAgainstBaseURL: false)!
        precondition(!unrestricted.queryItems!.contains { $0.name == "size" })
        let results = ["thumbnailGate": "passed", "originalRequest": "passed", "lateThumbnail": "passed", "concurrentWrites": "passed", "failedDownloadRetainsOriginal": "passed", "invalidImage": "passed", "smallOriginal": "passed", "originalPixels": "1600x1600"]
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"))
        print("Original cover cache and readiness tests passed")
    }
}
