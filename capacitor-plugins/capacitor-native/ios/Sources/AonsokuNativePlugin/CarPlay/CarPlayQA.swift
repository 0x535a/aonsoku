#if DEBUG
    import Foundation
    import UIKit
    import CarPlay

    /// Explicit opt-in fixture for an isolated simulator bundle. No real server or
    /// credentials are installed. Release builds contain no fixture entry point.
    @MainActor
    public enum CarPlayQA {
        public static var enabled: Bool {
            #if targetEnvironment(simulator)
                ProcessInfo.processInfo.environment["AONSOKU_CARPLAY_QA"] == "1"
                    && Bundle.main.bundleIdentifier?.hasSuffix(".carplay-qa") == true
            #else
                false
            #endif
        }

        public static func run() {
            Task { @MainActor in
                var checks: [String] = []
                do {
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let wav = directory.appendingPathComponent("carplay-qa.wav")
                    try silentWAV().write(to: wav)
                    let song = QueueSong(from: [
                        "id": "carplay-fixture", "title": "CarPlay fixture",
                        "artist": "Offline QA", "duration": 30.0, "cachedFileUri": wav.absoluteString,
                    ])
                    let engine = NativeQueueEngine()
                    engine.setContextQueue(songs: [song, song], currentIndex: 0, autoplay: false, startTime: nil)
                    try PlaybackStateRepository(db: DatabaseManager.shared.dbPool).save(
                        PlaybackPersistState(from: engine, currentTime: 3))
                    let playback = NativePlaybackService.shared
                    playback.start()
                    let restored = await snapshot()
                    try require(
                        restored.queue.count == 2 && restored.currentTime == 3 && !restored.isPlaying, "cold restore")
                    checks.append("cold restore without WebView")
                    let root = CarPlayTemplateController().makeRootTemplate()
                    try require(
                        root.templates.count == 3 && root.templates.allSatisfy { $0 is CPListTemplate },
                        "official templates")
                    checks.append("three Apple list-template tabs")
                    try await command(.play)
                    try await wait { $0.isPlaying && $0.currentTime >= 3 }
                    checks.append("restored source starts at saved progress")
                    playback.start()
                    let running = await snapshot()
                    try require(
                        running.isPlaying && running.queue.count == 2 && running.currentTime >= 3, "idempotent start")
                    checks.append("repeated initialization retains playback")
                    try await command(.pause)
                    try await wait { !$0.isPlaying }
                    try await command(.repeatMode("all"))
                    let repeated = await snapshot()
                    try require(repeated.repeatMode == "all", "repeat mode")
                    let oldEntry = repeated.queue[0]
                    try await command(.next)
                    do {
                        try await command(.queueEntry(oldEntry))
                        throw QAError.failed("stale queue selection accepted")
                    } catch QAError.failed(let message) where message == "stale queue selection accepted" {
                        throw QAError.failed(message)
                    } catch { checks.append("stale queue occurrence rejected") }
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        playback.setContextQueue(
                            NativePlaybackRequest(
                                options: [
                                    "songs": Array(repeating: song.toDict(), count: 205),
                                    "currentIndex": 0, "autoplay": false,
                                ], success: { _ in continuation.resume() }))
                    }
                    let middle = await snapshot(offset: 100)
                    let last = await snapshot(offset: 200)
                    try require(
                        middle.queue.count == 100 && middle.queue.first?.index == 100 && middle.queueTotal == 205,
                        "queue middle page")
                    try require(last.queue.count == 5 && last.queue.first?.index == 200, "queue last page")
                    checks.append("queue pagination preserves duplicate occurrences")
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        playback.clear(NativePlaybackRequest(success: { _ in continuation.resume() }))
                    }
                    let cleared = await snapshot()
                    try require(cleared.queue.isEmpty && !cleared.isPlaying && cleared.repeatMode == "off", "clear queue")
                    checks.append("clear releases queue and playback")
                    let containsWebView = UIApplication.shared.connectedScenes.compactMap {
                        ($0.delegate as? UIWindowSceneDelegate)?.window ?? nil
                    }
                    .contains { containsWebView($0) }
                    try require(!containsWebView, "WebView unexpectedly created")
                    checks.append("no WKWebView created")
                    write(["passed": true, "checks": checks])
                } catch { write(["passed": false, "checks": checks, "error": error.localizedDescription]) }
            }
        }

        private enum QAError: LocalizedError {
            case failed(String)
            var errorDescription: String? {
                if case .failed(let text) = self { return text }
                return nil
            }
        }

        private static func require(_ result: Bool, _ message: String) throws {
            if !result { throw QAError.failed(message) }
        }

        private static func snapshot(offset: Int = 0) async -> CarPlayPlaybackSnapshot {
            await withCheckedContinuation { continuation in
                NativePlaybackService.shared.carPlaySnapshot(queueOffset: offset) { continuation.resume(returning: $0) }
            }
        }

        private static func command(_ command: CarPlayPlaybackCommand) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NativePlaybackService.shared.performCarPlay(command) { continuation.resume(with: $0) }
            }
        }

        private static func wait(_ predicate: (CarPlayPlaybackSnapshot) -> Bool) async throws {
            for _ in 0..<100 {
                if predicate(await snapshot()) { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw QAError.failed("Playback state timed out")
        }

        private static func containsWebView(_ view: UIView) -> Bool {
            if NSStringFromClass(type(of: view)).contains("WKWebView") { return true }
            return view.subviews.contains { containsWebView($0) }
        }

        private static func write(_ result: [String: Any]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("carplay-qa-result.json")
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            print("CARPLAY_QA: \(result)")
        }

        private static func silentWAV() -> Data {
            let bytes: UInt32 = 11025 * 30 * 2
            var data = Data()
            func append<T: FixedWidthInteger>(_ value: T) {
                var value = value.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: "RIFF".utf8)
            append(bytes + 36)
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(11025))
            append(UInt32(22050))
            append(UInt16(2))
            append(UInt16(16))
            data.append(contentsOf: "data".utf8)
            append(bytes)
            data.append(Data(repeating: 0, count: Int(bytes)))
            return data
        }
    }
#endif
