import Foundation

final class NativeLogger {
    static let shared = NativeLogger()

    struct Entry {
        let timestamp: Date
        let level: Level
        let message: String
        let source: String

        enum Level: String, CaseIterable {
            case debug, info, warn, error
        }
    }

    private var buckets: [String: [Entry]] = [:]
    private let maxEntriesPerSource = 200
    private let queue = DispatchQueue(label: "com.aonsoku.NativeLogger")
    #if DEBUG
    private let artworkTraceEnabled = ProcessInfo.processInfo.environment["AONSOKU_ARTWORK_TRACE"] == "1"
    private var artworkTraceStarted = false
    #endif

    private init() {}

    func log(_ level: Entry.Level, _ message: String, source: String = "") {
        #if DEBUG
        if source == "NowPlayingArtwork" || source == "ImageCache" {
            print("[\(source)][\(level.rawValue)] \(message)")
        }
        #endif

        queue.async {
            let entry = Entry(timestamp: Date(), level: level, message: message, source: source)
            let key = source.isEmpty ? "_default" : source
            var bucket = self.buckets[key] ?? []
            if bucket.count >= self.maxEntriesPerSource {
                bucket.removeFirst()
            }
            bucket.append(entry)
            self.buckets[key] = bucket
            #if DEBUG
            if self.artworkTraceEnabled && source == "NowPlayingArtwork" {
                self.appendArtworkTrace(entry)
            }
            #endif
        }
    }

    #if DEBUG
    /// Opt-in, bounded, app-local trace retrievable with devicectl. It contains
    /// artwork diagnostics only, never the web console or credential requests.
    private func appendArtworkTrace(_ entry: Entry) {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = directory.appendingPathComponent("lock-screen-artwork-debug.jsonl")
        guard let encoded = try? JSONSerialization.data(withJSONObject: [
            "time": entry.timestamp.timeIntervalSince1970,
            "level": entry.level.rawValue,
            "message": entry.message,
        ]) else { return }
        var line = encoded
        line.append(10)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if !artworkTraceStarted || size > 512 * 1024 {
                try line.write(to: file, options: .atomic)
                artworkTraceStarted = true
            } else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            // Diagnostic I/O must never affect playback.
        }
    }
    #endif

    func debug(_ message: String, source: String = "") {
        log(.debug, message, source: source)
    }

    func info(_ message: String, source: String = "") {
        log(.info, message, source: source)
    }

    func warn(_ message: String, source: String = "") {
        log(.warn, message, source: source)
    }

    func error(_ message: String, source: String = "") {
        log(.error, message, source: source)
    }

    func getEntries() -> [Entry] {
        queue.sync {
            buckets.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        }
    }

    func clear() {
        queue.async { self.buckets.removeAll() }
    }
}
