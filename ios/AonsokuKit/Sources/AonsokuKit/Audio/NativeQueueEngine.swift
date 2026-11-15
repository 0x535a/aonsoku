import Foundation

public struct QueueSong: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let artistId: String?
    public let album: String
    public let albumId: String?
    public let duration: Double
    public let coverArtId: String?
    /// A logical library reference or an original external audio URL. Resolved
    /// authenticated/proxy URLs belong only to the playback transport.
    public let streamUrl: String
    public let cachedFileUri: String?
    /// Loudness tags for ReplayGain; nil when the server sent none.
    public let replayGain: AudioReplayGain?

    public init(
        id: String,
        title: String,
        artist: String,
        artistId: String? = nil,
        album: String,
        albumId: String? = nil,
        duration: Double,
        coverArtId: String? = nil,
        streamUrl: String,
        cachedFileUri: String? = nil,
        replayGain: AudioReplayGain? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.albumId = albumId
        self.duration = duration
        self.coverArtId = coverArtId
        self.streamUrl = LibraryMediaReference.canonicalStreamURL(streamUrl, songID: id)
        self.cachedFileUri = cachedFileUri
        self.replayGain = replayGain
    }

    init(from dict: [String: Any]) {
        self.init(
            id: dict["id"] as? String ?? "",
            title: dict["title"] as? String ?? "",
            artist: dict["artist"] as? String ?? "",
            artistId: dict["artistId"] as? String,
            album: dict["album"] as? String ?? "",
            albumId: dict["albumId"] as? String,
            duration: dict["duration"] as? Double ?? 0,
            coverArtId: dict["coverArtId"] as? String,
            streamUrl: dict["streamUrl"] as? String ?? "",
            cachedFileUri: dict["cachedFileUri"] as? String,
            replayGain: (dict["replayGain"] as? [String: Any]).flatMap(AudioReplayGain.init(from:))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, artistId, album, albumId, duration, coverArtId
        case streamUrl, cachedFileUri, replayGain
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            title: try values.decode(String.self, forKey: .title),
            artist: try values.decode(String.self, forKey: .artist),
            artistId: try values.decodeIfPresent(String.self, forKey: .artistId),
            album: try values.decode(String.self, forKey: .album),
            albumId: try values.decodeIfPresent(String.self, forKey: .albumId),
            duration: try values.decode(Double.self, forKey: .duration),
            coverArtId: try values.decodeIfPresent(String.self, forKey: .coverArtId),
            streamUrl: try values.decode(String.self, forKey: .streamUrl),
            cachedFileUri: try values.decodeIfPresent(String.self, forKey: .cachedFileUri),
            replayGain: try values.decodeIfPresent(AudioReplayGain.self, forKey: .replayGain)
        )
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "artist": artist,
            "album": album,
            "duration": duration,
            "streamUrl": streamUrl,
        ]
        if let artistId = artistId { dict["artistId"] = artistId }
        if let albumId = albumId { dict["albumId"] = albumId }
        if let coverArtId = coverArtId { dict["coverArtId"] = coverArtId }
        if let cachedFileUri = cachedFileUri { dict["cachedFileUri"] = cachedFileUri }
        if let replayGain = replayGain { dict["replayGain"] = replayGain.toDict() }
        return dict
    }
}

enum LoopState: String {
    case off
    case one
    case all
}

enum QueueAdvanceReason: String {
    case next
    case previous
    case ended
    case skip
}

protocol NativeQueueEngineDelegate: AnyObject {
    func queueEngine(_ engine: NativeQueueEngine, loadSong song: QueueSong, autoplay: Bool, startTime: Double?)
    func queueEngine(_ engine: NativeQueueEngine, didAdvanceTo index: Int, songId: String, reason: QueueAdvanceReason)
    func queueEngine(_ engine: NativeQueueEngine, didChangeContents reason: String)
    func queueEngineDidExhaustQueue(_ engine: NativeQueueEngine)
    func queueEngine(_ engine: NativeQueueEngine, seekToStart song: QueueSong)
}

class NativeQueueEngine {
    weak var delegate: NativeQueueEngineDelegate?

    private(set) var contextSongs: [QueueSong] = []
    /// Complete selection, independent of the played/upcoming queue window.
    private(set) var sourceSongs: [QueueSong] = []
    private(set) var originalContextSongs: [QueueSong] = []
    private(set) var currentIndex: Int = 0

    private(set) var userQueue: [QueueSong] = []
    private(set) var originalUserSongs: [QueueSong] = []
    private(set) var isInUserQueue: Bool = false
    private(set) var playedUserQueueHistory: [QueueSong] = []

    private(set) var loopState: LoopState = .off
    private(set) var isShuffleActive: Bool = false
    private(set) var shuffleHistory: [String] = []
    private(set) var shuffleStartHistory: [String] = []
    private(set) var sourceId: QueueSourceId?
    private(set) var sourceName: String?

    private let shuffleEngine = NativeShuffleEngine()
    private let prevSeekThreshold: Double = 3.0

    private var maxShuffleHistory: Int {
        max(20, min(contextSongs.count / 2, 200))
    }

    private var maxShuffleStartHistory: Int {
        max(10, min(sourceSongs.count / 4, 50))
    }

    var currentSong: QueueSong? {
        if isInUserQueue, !userQueue.isEmpty {
            return userQueue.first
        }
        guard currentIndex >= 0, currentIndex < contextSongs.count else {
            return nil
        }
        return contextSongs[currentIndex]
    }

    var hasNext: Bool {
        if isInUserQueue && userQueue.count > 1 { return true }
        if !isInUserQueue && !userQueue.isEmpty { return true }
        if currentIndex < contextSongs.count - 1 { return true }
        if loopState == .all && !contextSongs.isEmpty { return true }
        return false
    }

    var hasPrev: Bool {
        if !playedUserQueueHistory.isEmpty { return true }
        if isInUserQueue { return true }
        if currentIndex > 0 { return true }
        return false
    }

    /// The item that natural end-of-track advancement will select, when it
    /// can be known without mutating the queue. AudioService uses this to
    /// stage exactly one AVQueuePlayer item ahead of the current song.
    ///
    /// Repeat-one only advances while a user-queued song remains. Repeat-all
    /// copies the rendered cycle, including its shuffle order.
    var nextSongForAutomaticAdvance: QueueSong? {
        if loopState == .one {
            if isInUserQueue {
                return userQueue.count > 1 ? userQueue[1] : nil
            }
            return userQueue.first
        }

        if isInUserQueue {
            if userQueue.count > 1 { return userQueue[1] }
            if currentIndex < contextSongs.count - 1 {
                return contextSongs[currentIndex + 1]
            }
            if loopState == .all {
                return contextSongs.first
            }
            return nil
        }

        if let queued = userQueue.first { return queued }
        if currentIndex < contextSongs.count - 1 {
            return contextSongs[currentIndex + 1]
        }
        if loopState == .all {
            return contextSongs.first
        }
        return nil
    }

    // MARK: - Queue Setup

    static func playbackSongs(_ songs: [QueueSong], index: Int, loop: LoopState, shuffle: Bool) -> [QueueSong] {
        guard !songs.isEmpty else { return [] }
        let index = max(0, min(index, songs.count - 1))
        let ordered = Array(songs[index...]) + (loop == .all ? Array(songs[..<index]) : [])
        guard shuffle, let first = ordered.first else { return ordered }
        return [first] + NativeShuffleEngine().shuffleWithGapAvoidance(Array(ordered.dropFirst()), history: [])
    }

    /// Product-level selection shared by the phone, CarPlay and remote commands.
    /// Low-level setContextQueue still accepts already prepared transport queues.
    func setPlaybackQueue(
        songs: [QueueSong], index: Int, shuffle: Bool, autoplay: Bool = true,
        sourceId: QueueSourceId? = nil, sourceName: String? = nil
    ) {
        let prepared = Self.playbackSongs(songs, index: index, loop: loopState, shuffle: shuffle)
        setContextQueue(songs: prepared, currentIndex: 0, autoplay: autoplay, startTime: nil,
                        sourceId: sourceId, sourceName: sourceName)
        sourceSongs = songs
        originalContextSongs = songs
        if shuffle { markAsShuffled(originalSongs: songs) }
    }

    func setContextQueue(
        songs: [QueueSong],
        currentIndex: Int,
        autoplay: Bool,
        startTime: Double?,
        sourceId: QueueSourceId? = nil,
        sourceName: String? = nil
    ) {
        self.contextSongs = songs
        self.sourceSongs = songs
        self.originalContextSongs = []
        self.currentIndex = max(0, min(currentIndex, songs.count - 1))
        self.userQueue = []
        self.originalUserSongs = []
        self.isInUserQueue = false
        self.playedUserQueueHistory = []
        self.isShuffleActive = false
        self.shuffleHistory = []
        self.sourceId = sourceId
        self.sourceName = sourceName

        if let song = self.currentSong {
            delegate?.queueEngine(self, loadSong: song, autoplay: autoplay, startTime: startTime)
        }
    }

    func updateContextQueue(songs: [QueueSong], currentIndex: Int) {
        let previousSongId = self.currentSong?.id
        self.contextSongs = songs
        self.currentIndex = max(0, min(currentIndex, songs.count - 1))
        self.originalContextSongs = originalContextSongs.filter { orig in
            songs.contains { $0.id == orig.id }
        }

        let newSongId = self.currentSong?.id
        if previousSongId != newSongId {
            if let song = self.currentSong {
                delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: nil)
                delegate?.queueEngine(self, didAdvanceTo: self.currentIndex, songId: song.id, reason: .skip)
            }
        } else {
            delegate?.queueEngine(self, didChangeContents: "queue-edit")
        }
    }

    @discardableResult
    func reorderContextQueue(fromIndex: Int, toIndex: Int) -> Bool {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < contextSongs.count,
              toIndex >= 0, toIndex < contextSongs.count else { return false }

        let song = contextSongs.remove(at: fromIndex)
        contextSongs.insert(song, at: toIndex)
        if fromIndex == currentIndex { currentIndex = toIndex }
        else if fromIndex < currentIndex && toIndex >= currentIndex { currentIndex -= 1 }
        else if fromIndex > currentIndex && toIndex <= currentIndex { currentIndex += 1 }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
        return true
    }

    /// Reorders the flattened protocol queue: played context, user queue,
    /// then the remaining context. Cross-tier moves are intentionally rejected.
    @discardableResult
    func reorderFlattenedQueue(fromIndex: Int, toIndex: Int) -> Bool {
        guard fromIndex != toIndex else { return false }
        let contextPlayedCount = currentIndex + 1
        let userRange = contextPlayedCount..<(contextPlayedCount + userQueue.count)

        if userRange.contains(fromIndex), userRange.contains(toIndex) {
            let from = fromIndex - contextPlayedCount
            let to = toIndex - contextPlayedCount
            let song = userQueue.remove(at: from)
            userQueue.insert(song, at: to)
            delegate?.queueEngine(self, didChangeContents: "queue-edit")
            return true
        }

        let upcomingStart = contextPlayedCount + userQueue.count
        guard fromIndex >= upcomingStart, toIndex >= upcomingStart else {
            return false
        }
        return reorderContextQueue(
            fromIndex: fromIndex - userQueue.count,
            toIndex: toIndex - userQueue.count
        )
    }

    /// Removes each requested song from the user tier first, matching the web
    /// queue's tier detection, then from upcoming context if it was not queued.
    @discardableResult
    func removeSongIds(_ songIds: [String]) -> Bool {
        var changed = false
        for id in songIds {
            if let index = userQueue.firstIndex(where: { $0.id == id }) {
                guard !(isInUserQueue && index == 0) else { continue }
                userQueue.remove(at: index)
                originalUserSongs.removeAll { $0.id == id }
                changed = true
                continue
            }
            if let index = contextSongs.firstIndex(where: { $0.id == id }),
               index != currentIndex {
                contextSongs.remove(at: index)
                originalContextSongs.removeAll { $0.id == id }
                if index < currentIndex { currentIndex -= 1 }
                changed = true
            }
        }
        if changed {
            delegate?.queueEngine(self, didChangeContents: "queue-edit")
        }
        return changed
    }

    func addToUserQueue(songs: [QueueSong], position: String) {
        if position == "next" {
            let insertIndex = isInUserQueue ? 1 : 0
            userQueue.insert(contentsOf: songs, at: min(insertIndex, userQueue.count))
        } else {
            userQueue.append(contentsOf: songs)
        }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func removeFromUserQueue(indices: [Int]) {
        let sorted = indices.sorted(by: >)
        for idx in sorted where idx >= 0 && idx < userQueue.count {
            userQueue.remove(at: idx)
        }
        if userQueue.isEmpty && isInUserQueue {
            isInUserQueue = false
        }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func clearUserQueue() {
        userQueue = []
        originalUserSongs = []
        playedUserQueueHistory = []
        if isInUserQueue {
            isInUserQueue = false
        }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func clearAll() {
        contextSongs = []
        sourceSongs = []
        originalContextSongs = []
        currentIndex = 0
        userQueue = []
        originalUserSongs = []
        isInUserQueue = false
        playedUserQueueHistory = []
        loopState = .off
        isShuffleActive = false
        shuffleHistory = []
        shuffleStartHistory = []
        sourceId = nil
        sourceName = nil
        isRestored = false
    }

    func playAtIndex(_ index: Int, startTime: Double?) {
        guard index >= 0, index < contextSongs.count else { return }
        isInUserQueue = false
        currentIndex = index
        ensureNextCycle()
        if let song = currentSong {
            delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: startTime)
            delegate?.queueEngine(self, didAdvanceTo: currentIndex, songId: song.id, reason: .skip)
        }
    }

    // MARK: - Playback Control

    /// Select an occurrence, rather than a song ID (a queue may contain duplicates).
    func playUserQueueAtIndex(_ index: Int) {
        guard userQueue.indices.contains(index) else { return }
        playedUserQueueHistory.append(contentsOf: userQueue.prefix(index))
        userQueue.removeFirst(index)
        isInUserQueue = true
        if let song = currentSong {
            delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: nil)
            delegate?.queueEngine(self, didAdvanceTo: currentIndex, songId: song.id, reason: .skip)
            delegate?.queueEngine(self, didChangeContents: "queue-edit")
        }
    }

    func handleEnded() {
        if loopState == .one {
            let userQueueRemaining = isInUserQueue
                ? userQueue.count - 1
                : userQueue.count
            if userQueueRemaining > 0 {
                advanceToNext(reason: .ended)
                return
            }
            if let song = currentSong {
                delegate?.queueEngine(self, seekToStart: song)
            }
            return
        }
        if loopState == .all, !isInUserQueue, userQueue.isEmpty,
           contextSongs.count == 1, let song = currentSong {
            delegate?.queueEngine(self, seekToStart: song)
            return
        }
        advanceToNext(reason: .ended)
    }

    func skipToNext() {
        advanceToNext(reason: .next)
    }

    func skipToPrevious(currentTime: Double) {
        if currentTime > prevSeekThreshold || !hasPrev {
            if let song = currentSong {
                delegate?.queueEngine(self, seekToStart: song)
            }
            return
        }
        advanceToPrevious()
    }

    // MARK: - Advance Logic

    private func advanceToNext(reason: QueueAdvanceReason) {
        if isInUserQueue {
            let consumed = userQueue.removeFirst()
            playedUserQueueHistory.append(consumed)
            pushShuffleHistory(consumed.id)

            if !userQueue.isEmpty {
                notifyAdvance(reason: reason)
                return
            }

            isInUserQueue = false
            ensureNextCycle(advancing: true)
            if currentIndex < contextSongs.count - 1 {
                currentIndex += 1
            }
            notifyAdvance(reason: reason)
            return
        }

        if !userQueue.isEmpty {
            if let song = currentSong {
                pushShuffleHistory(song.id)
            }
            isInUserQueue = true
            notifyAdvance(reason: reason)
            return
        }

        if let song = currentSong {
            pushShuffleHistory(song.id)
        }

        if loopState == .all && contextSongs.count > 1 { ensureNextCycle(advancing: true) }
        if currentIndex < contextSongs.count - 1 {
            currentIndex += 1
            notifyAdvance(reason: reason)
            return
        }

        if loopState == .all {
            notifyAdvance(reason: reason)
            return
        }

        delegate?.queueEngineDidExhaustQueue(self)
    }

    private func advanceToPrevious() {
        if !playedUserQueueHistory.isEmpty {
            let restored = playedUserQueueHistory.removeLast()
            userQueue.insert(restored, at: 0)
            let wasInUserQueue = isInUserQueue
            isInUserQueue = true

            if !wasInUserQueue && currentIndex > 0 {
                currentIndex -= 1
            }

            notifyAdvance(reason: .previous)
            return
        }

        if isInUserQueue {
            isInUserQueue = false
            notifyAdvance(reason: .previous)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
            notifyAdvance(reason: .previous)
        }
    }

    private func ensureNextCycle(advancing: Bool = false) {
        guard loopState == .all, contextSongs.count > 1,
              currentIndex + (advancing ? 1 : 0) >= contextSongs.count - 1 else { return }
        // Keep the rendered order, including shuffle, and retain previous-track
        // navigation across the cycle boundary, just like the web queue.
        let count = max(sourceSongs.count, contextSongs.count)
        contextSongs.append(contentsOf: Array(contextSongs.prefix(count)))
    }

    private func notifyAdvance(reason: QueueAdvanceReason) {
        guard let song = currentSong else { return }
        delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: nil)
        delegate?.queueEngine(self, didAdvanceTo: currentIndex, songId: song.id, reason: reason)
    }

    // MARK: - Shuffle

    func setShuffleActive(_ active: Bool) {
        if active {
            applyShuffle()
        } else {
            applyUnshuffle()
        }
    }

    func markAsShuffled(originalSongs: [QueueSong]) {
        isShuffleActive = true
        sourceSongs = originalSongs
        originalContextSongs = originalSongs
        if let song = currentSong {
            shuffleStartHistory = shuffleEngine.pushToHistory(
                shuffleStartHistory,
                id: song.id,
                maxLen: maxShuffleStartHistory
            )
        }
    }

    func setLoopState(_ state: LoopState, rebuild: Bool = true) {
        guard loopState != state else { return }
        self.loopState = state
        if rebuild { rebuildPlaybackQueue(shuffle: isShuffleActive) }
    }

    private func rebuildPlaybackQueue(shuffle: Bool) {
        guard let song = currentSong,
              let index = sourceSongs.firstIndex(where: { $0.id == song.id }) else { return }
        contextSongs = Self.playbackSongs(sourceSongs, index: index, loop: loopState, shuffle: shuffle)
        currentIndex = 0
        originalContextSongs = sourceSongs
    }

    private func applyShuffle() {
        guard contextSongs.count + userQueue.count > 1 else { return }

        originalContextSongs = contextSongs

        if let song = currentSong {
            shuffleStartHistory = shuffleEngine.pushToHistory(
                shuffleStartHistory, id: song.id, maxLen: maxShuffleStartHistory
            )
        }

        rebuildPlaybackQueue(shuffle: true)

        if !userQueue.isEmpty {
            originalUserSongs = userQueue
            userQueue = shuffleEngine.shuffleWithGapAvoidance(userQueue, history: shuffleHistory)
        }

        isShuffleActive = true
        delegate?.queueEngine(self, didChangeContents: "shuffle")
    }

    private func applyUnshuffle() {
        guard !originalContextSongs.isEmpty else {
            // Nothing to put back in order, but the flag is part of the
            // published queue state.
            guard isShuffleActive else { return }
            isShuffleActive = false
            delegate?.queueEngine(self, didChangeContents: "unshuffle")
            return
        }

        rebuildPlaybackQueue(shuffle: false)

        if !originalUserSongs.isEmpty {
            userQueue = originalUserSongs
            originalUserSongs = []
        }

        originalContextSongs = sourceSongs
        playedUserQueueHistory = []
        isShuffleActive = false
        shuffleHistory = []
        delegate?.queueEngine(self, didChangeContents: "unshuffle")
    }

    private func pushShuffleHistory(_ id: String) {
        shuffleHistory = shuffleEngine.pushToHistory(shuffleHistory, id: id, maxLen: maxShuffleHistory)
    }

    // MARK: - State Restoration

    private(set) var isRestored: Bool = false

    func restoreState(from persisted: PlaybackPersistState) {
        contextSongs = persisted.contextSongs
        sourceSongs = persisted.sourceSongs ?? (persisted.originalContextSongs.isEmpty
            ? persisted.contextSongs : persisted.originalContextSongs)
        currentIndex = persisted.currentIndex
        userQueue = persisted.userQueue
        originalContextSongs = persisted.originalContextSongs
        originalUserSongs = persisted.originalUserSongs
        isShuffleActive = persisted.isShuffleActive
        shuffleHistory = persisted.shuffleHistory
        shuffleStartHistory = persisted.shuffleStartHistory
        loopState = LoopState(rawValue: persisted.loopState) ?? .off
        isInUserQueue = persisted.isInUserQueue
        playedUserQueueHistory = persisted.playedUserQueueHistory
        sourceId = persisted.sourceId
        sourceName = persisted.sourceName
        isRestored = true
    }

    func clearRestoredFlag() {
        isRestored = false
    }

    // MARK: - State Export

    func getFullState(currentTime: Double, duration: Double, isPlaying: Bool) -> [String: Any] {
        let sourceIdValue: Any = sourceId.map { ["type": $0.type, "id": $0.id] } ?? NSNull()
        let sourceNameValue: Any = sourceName ?? NSNull()

        return [
            "contextQueue": [
                "songs": contextSongs.map { $0.toDict() },
                "currentIndex": currentIndex,
                "sourceId": sourceIdValue,
                "sourceName": sourceNameValue,
            ],
            "sourceQueue": ["songs": sourceSongs.map { $0.toDict() }],
            "userQueue": userQueue.map { $0.toDict() },
            "originalContextSongs": originalContextSongs.map { $0.toDict() },
            "originalUserSongs": originalUserSongs.map { $0.toDict() },
            "isInUserQueue": isInUserQueue,
            "isShuffleActive": isShuffleActive,
            "shuffleHistory": shuffleHistory,
            "shuffleStartHistory": shuffleStartHistory,
            "playedUserQueueHistory": playedUserQueueHistory.map { $0.toDict() },
            "loopState": loopState.rawValue,
            "isPlaying": isPlaying,
            "currentTime": currentTime,
            "duration": duration,
            "currentSongId": currentSong?.id ?? NSNull(),
            "isRestored": isRestored,
        ]
    }
}
