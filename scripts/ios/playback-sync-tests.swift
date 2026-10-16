import Foundation

@main
struct PlaybackSyncTests {
    static func song(_ id: String, url: String = "", file: String? = nil) -> QueueSong {
        var values: [String: Any] = ["id": id, "streamUrl": url]
        if let file { values["cachedFileUri"] = file }
        return QueueSong(from: values)
    }

    static func main() throws {
        let queue = NativeQueueEngine()
        queue.setContextQueue(songs: [song("a"), song("b"), song("c")],
            currentIndex: 1, autoplay: false, startTime: nil)
        queue.reorderContextQueue(fromIndex: 0, toIndex: 2)
        precondition(queue.currentSong?.id == "b" && queue.currentIndex == 0)
        queue.skipToNext()
        precondition(queue.currentSong?.id == "c")
        queue.reorderContextQueue(fromIndex: 1, toIndex: 2)
        precondition(queue.currentSong?.id == "c" && queue.currentIndex == 2)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let credentials = ServerCredentials(serverUrl: "https://music.invalid/base/",
            username: "fixture", password: "fixture", authType: "token",
            protocolVersion: "1.16.0", serverType: "navidrome", fallbackUrl: nil)
        let resolver = NativeSourceResolver(cacheDirectories: [temporary],
            credentialsProvider: { credentials })
        let direct = "https://radio.invalid/live?format=aac&maxBitRate=96"
        precondition(resolver.resolveSource(for: song("radio", url: direct))?.url.absoluteString == direct)
        let stream = song("fallback", url:
            "aonsoku-media://stream?id=special%26id&maxBitRate=128&format=mp3")
        let resolved = resolver.resolveSource(for: stream)!
        precondition(resolved.kind == "stream")
        precondition(resolved.url.path == "/base/rest/stream")
        let params = Dictionary(uniqueKeysWithValues:
            URLComponents(url: resolved.url, resolvingAgainstBaseURL: false)!.queryItems!
                .map { ($0.name, $0.value ?? "") })
        precondition(params["id"] == "special&id")
        precondition(params["maxBitRate"] == "128" && params["format"] == "mp3")
        precondition(params["estimateContentLength"] == "true")

        let cached = temporary.appendingPathComponent("fixture.mp3")
        try Data([0, 1, 2]).write(to: cached)
        precondition(resolver.resolveSource(for: song("cached", url: direct,
            file: cached.absoluteString))?.kind == "native-file")
        let anonymous = NativeSourceResolver(cacheDirectories: [], credentialsProvider: { nil })
        precondition(anonymous.resolveSource(for: stream) == nil)
        precondition(anonymous.resolveSource(for: song("radio", url: direct))?.url.absoluteString == direct)
        print("Native queue reorder and source resolution tests passed")
    }
}
