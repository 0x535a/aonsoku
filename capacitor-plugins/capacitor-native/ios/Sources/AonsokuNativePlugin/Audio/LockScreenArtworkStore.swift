import CoreGraphics
import CryptoKit
import Foundation

/// Captured by the system artwork handlers. A live asset pins its video file
/// against eviction, including after the player switches to another cover.
final class LockScreenArtworkAsset {
    let id: String
    let preview: CGImage
    private let store: LockScreenArtworkStore

    fileprivate init(id: String, preview: CGImage, store: LockScreenArtworkStore) {
        self.id = id
        self.preview = preview
        self.store = store
    }

    func requestVideo(_ completion: @escaping (URL?) -> Void) {
        store.requestVideo(for: self, completion: completion)
    }
}

final class LockScreenArtworkStore {
    static let shared = LockScreenArtworkStore()
    private let queue = DispatchQueue(label: "com.aonsoku.lock-screen-artwork", qos: .utility)
    private let directory: URL
    private let byteLimit: Int
    private let countLimit: Int
    private struct WeakAsset { weak var value: LockScreenArtworkAsset? }
    private var assets: [String: WeakAsset] = [:]
    private var pending: [(asset: LockScreenArtworkAsset, callbacks: [(URL?) -> Void])] = []
    private var encodingID: String?

    init(directory: URL? = nil, byteLimit: Int = 24 * 1024 * 1024, countLimit: Int = 12) {
        // Application Support rather than temporary storage: URLs must remain
        // valid while MediaPlayer retains the corresponding artwork object.
        self.directory =
            directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("AonsokuLockScreenArtwork", isDirectory: true)
        self.byteLimit = byteLimit
        self.countLimit = countLimit
        queue.async { self.trim() }
    }

    func prepare(
        data: Data, source: CGImage, completion: @escaping (LockScreenArtworkAsset?) -> Void
    ) {
        queue.async {
            autoreleasepool {
                // Content-based identity shares assets across album tracks and
                // invalidates them on cover replacement. No authenticated URL
                // or server/album identifier is stored on disk.
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let id = "edge-v1-720x960-\(digest)"
                if let existing = self.assets[id]?.value {
                    completion(existing)
                    return
                }
                guard let preview = LockScreenArtworkRenderer.render(source) else {
                    completion(nil)
                    return
                }
                let asset = LockScreenArtworkAsset(id: id, preview: preview, store: self)
                self.assets[id] = WeakAsset(value: asset)
                self.trim()
                completion(asset)
            }
        }
    }

    fileprivate func requestVideo(
        for asset: LockScreenArtworkAsset, completion: @escaping (URL?) -> Void
    ) {
        queue.async {
            let url = self.videoURL(for: asset.id)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: url.path)
                completion(url)
                return
            }
            // A zero-length remnant has never been handed to MediaPlayer.
            // Remove it so atomic promotion of a fresh export can recover.
            try? FileManager.default.removeItem(at: url)
            if let index = self.pending.firstIndex(where: { $0.asset.id == asset.id }) {
                self.pending[index].callbacks.append(completion)
            } else {
                self.pending.append((asset, [completion]))
            }
            self.encodeNext()
        }
    }

    private func videoURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("mp4")
    }

    private func encodeNext() {
        guard encodingID == nil, let request = pending.first else { return }
        encodingID = request.asset.id
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
            "tmp.mp4")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: directory.path
                )
            #endif
            LockScreenArtworkVideo.write(image: request.asset.preview, to: temporary, queue: queue)
            {
                result in
                self.queue.async {
                    let final = self.videoURL(for: request.asset.id)
                    var output: URL?
                    do {
                        _ = try result.get()
                        #if os(iOS)
                            try FileManager.default.setAttributes(
                                [
                                    .protectionKey: FileProtectionType
                                        .completeUntilFirstUserAuthentication
                                ],
                                ofItemAtPath: temporary.path
                            )
                        #endif
                        try FileManager.default.moveItem(at: temporary, to: final)
                        output = final
                    } catch {
                        // Leave ordinary static artwork installed on any failure.
                        try? FileManager.default.removeItem(at: temporary)
                    }
                    self.finishEncoding(output)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            finishEncoding(nil)
        }
    }

    private func finishEncoding(_ url: URL?) {
        let request = pending.removeFirst()
        encodingID = nil
        for callback in request.callbacks { callback(url) }
        trim()
        encodeNext()
    }

    private func trim() {
        assets = assets.filter { $0.value.value != nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys)
            )
        else { return }
        var entries = files.filter {
            $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(".tmp.mp4")
        }
        .map { url -> (URL, Int, Date) in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        while !entries.isEmpty && (bytes > byteLimit || count > countLimit) {
            let (url, size, _) = entries.removeFirst()
            let id = url.deletingPathExtension().lastPathComponent
            guard assets[id]?.value == nil else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                bytes -= size
                count -= 1
            }
        }
        // Only this process's active encoder owns a temporary file. Clean up
        // interrupted exports from previous launches, never an active export.
        if encodingID == nil {
            for file in files where file.lastPathComponent.hasSuffix(".tmp.mp4") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
