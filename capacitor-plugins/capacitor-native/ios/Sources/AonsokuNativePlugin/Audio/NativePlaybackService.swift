import Foundation
import AVFoundation
import MediaPlayer
import UIKit

public final class NativePlaybackService: NSObject {
    public static let shared = NativePlaybackService()
    private var queueRevision = 0
    private var carPlaySelectionGeneration = 0
    private var carPlaySelectionTask: Task<Void, Never>?
    private var lastRecordedGeneration: Int?
    private var accountIdentity: String?
    private var credentialsObserver: NSObjectProtocol?
    private var started = false
    private override init() { super.init() }
    weak var volumeContainerView: UIView?
    private var eventObservers: [UUID: (String, [String: Any]) -> Void] = [:]
    private static weak var activeInstance: NativePlaybackService?

    internal static var dynamicCoverRegistryFromActive: DynamicCoverRegistry<LockScreenArtworkAsset>? {
        activeInstance?.dynamicCoverRegistry
    }

    internal static func executeRemoteControlCommandFromActive(_ command: [String: Any]) -> Bool {
        guard let instance = activeInstance else {
            return false
        }
        return instance.executeRemoteControlCommand(command)
    }

    internal static func getFullStateFromActive() -> [String: Any]? {
        activeInstance?.currentFullState()
    }

    internal static func pauseAndGetFullStateFromActive() -> [String: Any]? {
        activeInstance?.pauseAndGetCurrentFullState()
    }

    internal static func updateRemotePlaybackProjectionFromActive(
        snapshot: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int
    ) -> Bool {
        guard let instance = activeInstance else {
            return false
        }
        instance.updateRemotePlaybackProjection(
            snapshot: snapshot,
            targetDeviceId: targetDeviceId,
            expectedGeneration: expectedGeneration
        )
        return true
    }

    internal static func clearRemotePlaybackProjectionFromActive() -> Bool {
        guard let instance = activeInstance else {
            return false
        }
        instance.clearRemotePlaybackProjection()
        return true
    }

    internal static func prepareHandoffPlaybackFromActive(
        snapshot: [String: Any],
        autoplay: Bool,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let instance = activeInstance else {
            return false
        }
        instance.prepareHandoffPlayback(snapshot: snapshot, autoplay: autoplay, completion: completion)
        return true
    }

    internal static func isSupportedRemoteControlCommand(_ type: String) -> Bool {
        [
            "play",
            "pause",
            "toggle_play_pause",
            "previous",
            "next",
            "seek",
            "set_shuffle",
            "set_repeat",
            "set_volume",
            "play_song",
            "play_album",
            "play_playlist",
            "play_at_index",
            "add_to_queue_next",
            "add_to_queue_last",
            "remove_from_queue",
            "reorder_queue",
            "clear_queue",
            "toggle_like",
        ].contains(type)
    }

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private let audioSession = AVAudioSession.sharedInstance()
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var failedEndObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private let recoveryController = PlaybackRecoveryController()
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?
    private var artworkSettingsObserver: NSObjectProtocol?
    private var artworkModelObserver: NSObjectProtocol?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var coverImageCachedObserver: NSObjectProtocol?
    private let loadQueue = DispatchQueue(label: "com.aonsoku.NativeAudio.load", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "com.aonsoku.NativeAudio.state", qos: .userInitiated)
    private var handoffGeneration = 0
    private var preparedHandoffBefore: (PlaybackPersistState, Bool)?
    private let progressQueue = DispatchQueue(label: "com.aonsoku.NativeAudio.progress", qos: .userInitiated)
    private var wasPlayingBeforeInterruption = false
    private var repeatMode = "off"
    private var shuffleEnabled = false
    private var queueItemCount = 0
    private var queueIndex = 0
    private var currentSourceKind: String?
    private var currentSourceUrl: URL?
    private var currentRadioId: String?
    private var currentRequestId: String?
    private var playbackGeneration = 0
    private var currentMetadata = NativeAudioMetadata()
    private var remotePlaybackProjection: NativeRemotePlaybackProjection?
    private var loadedDurationSeconds: Double?
    private var artworkTask: URLSessionDataTask?
    private var coverDownloadTask: Task<Void, Never>?
    private var coverDownloadArtId: String?
    private var coverDownloadSize: String?
    private var coverDownloadRequestID: UUID?
    private var nowPlayingRevision = 0
    private var artworkResourceObservers: [NSObjectProtocol] = []
    private let artworkGeneration = LockScreenArtworkGeneration()
    private let artworkPreparationQueue = DispatchQueue(label: "com.aonsoku.artwork-preparation", qos: .utility)
    private var artworkPublishedStages: [String: Int] = [:]
    private let dynamicCoverRegistry = DynamicCoverRegistry<LockScreenArtworkAsset>()
    private var publishedArtworkSource: String?
    private var publishedArtworkOriginalReady = false
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private let queueEngine = NativeQueueEngine()
    private let sourceResolver = NativeSourceResolver()
    private let scrobbleBuffer = NativeScrobbleBuffer()
    private let scrobbleSubmitter = NativeScrobbleSubmitter()
    private let downloadManager = NativeDownloadManager()
    private var backgroundCacheSongIds = Set<String>()
    private var backgroundCacheCompletedSongIds = Set<String>()
    private var stalledSinceDate: Date?
    private var pendingStartTime: Double?
    private var pendingAutoplay = false
    private var pendingStartSong: QueueSong?
    private var streamingLoader: StreamingResourceLoader?
    private let loaderQueue = DispatchQueue(label: "com.aonsoku.NativeAudio.loader", qos: .userInitiated)
    private var isQueueEngineActive = false
    private var volumeSliderView: MPVolumeView?
    private var volumeSlider: UISlider?
    private var volumeObservation: NSKeyValueObservation?
    private var isVolumeHUDEnabled = true
    private var volumeOperationGen = 0
    private var lastEmittedPlaybackState: String?
    private var isSeeking = false
    private var isQueueTransitioning = false
    private var isRecoveryReload = false
    private var bufferMismatchFirstSeen: Date?
    private var isInForeground = true
    private var nextSnapshotProgressSeconds: Double?
    private let persistence = PlaybackStatePersistence(
        repository: PlaybackStateRepository(db: DatabaseManager.shared.dbPool)
    )
    private var savedRestoreTime: Double?

    // Sleep Timer
    private var sleepTimer: Timer?
    private var sleepTimerEndDate: Date?
    private var sleepTimerMode: String = "duration"

    public func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        isInForeground = UIApplication.shared.applicationState == .active
        Self.activeInstance = self
        queueEngine.delegate = self
        downloadManager.delegate = self
        recoveryController.delegate = self
        registerLifecycleObservers()
        registerRemoteCommands()
        logNowPlayingArtworkDiagnostics("service-start")

        do {
            try configureAudioSession()
        } catch {
            emitError(code: "audio_session_failed", message: error.localizedDescription)
        }

        accountIdentity = Self.currentAccountIdentity()
        credentialsObserver = NotificationCenter.default.addObserver(forName: .aonsokuCredentialsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sourceResolver.invalidateCredentialsCache()
            let identity = Self.currentAccountIdentity()
            if identity != self.accountIdentity {
                self.accountIdentity = identity
                self.cancelCarPlayRequests()
                self.clear(NativePlaybackRequest())
            }
        }
        setupVolumeControl()
        restorePlaybackState()
        setupPersistence()
        updateSystemPlaybackModes()
    }

    @discardableResult
    public func observeEvents(_ observer: @escaping (String, [String: Any]) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let token = UUID()
        eventObservers[token] = observer
        stateQueue.async {
            let state = self.currentFullState() ?? [:]
            DispatchQueue.main.async { self.eventObservers[token]?("nativeStateReady", state) }
        }
        return token
    }

    public func removeEventObserver(_ token: UUID) {
        precondition(Thread.isMainThread)
        eventObservers.removeValue(forKey: token)
    }

    private static func currentAccountIdentity() -> String? {
        guard let credentials = KeychainManager.retrieve() else { return nil }
        return credentials.serverUrl + "\n" + credentials.username
    }

    private func notifyListeners(_ name: String, data: [String: Any]) {
        if ["downloadCompleted", "streamCacheCompleted"].contains(name),
           let id = data["songId"] as? String, let size = data["sizeBytes"] as? NSNumber {
            CarPlayLibraryProvider.recordCached(songId: id, size: size.intValue)
        }
        if name == "queueContentsChanged" || name == "queueStateChanged" { queueRevision += 1 }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for observer in Array(self.eventObservers.values) { observer(name, data) }
        }
    }

    deinit {
        if let credentialsObserver { NotificationCenter.default.removeObserver(credentialsObserver) }
        coverDownloadTask?.cancel()
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
        unregisterRemoteCommands()
        removeLifecycleObservers()
        clearPlayer(sendIdleEvent: false, deactivateSession: true)
        volumeObservation?.invalidate()
        volumeSliderView?.removeFromSuperview()
    }

    private func executeRemoteControlCommand(_ command: [String: Any]) -> Bool {
        cancelCarPlaySelection()
        guard let type = command["type"] as? String else {
            return false
        }

        if !Self.isSupportedRemoteControlCommand(type) {
            return false
        }

        if type == "play_song" {
            guard let id = command["song_id"] as? String, !id.isEmpty else {
                return false
            }
            playSongById(id)
            return true
        }

        if type == "play_album" {
            guard let id = command["album_id"] as? String, !id.isEmpty else {
                return false
            }
            playAlbumById(
                id,
                index: command["index"] as? Int ?? 0,
                shuffle: command["shuffle"] as? Bool ?? false
            )
            return true
        }

        if type == "play_playlist" {
            guard let id = command["playlist_id"] as? String, !id.isEmpty else {
                return false
            }
            playPlaylistById(
                id,
                index: command["index"] as? Int ?? 0,
                shuffle: command["shuffle"] as? Bool ?? false
            )
            return true
        }

        if type == "play_at_index" ||
            type == "add_to_queue_next" ||
            type == "add_to_queue_last" {
            let ids = stringArray(command["song_ids"])
            guard !ids.isEmpty else {
                return false
            }
            if type == "add_to_queue_next" || type == "add_to_queue_last" {
                addSongIdsToQueue(
                    ids: ids,
                    position: type == "add_to_queue_next" ? "next" : "last"
                )
                return true
            }
            let index = command["index"] as? Int ?? 0
            playSongIdsAtIndex(ids: ids, index: index)
            return true
        }

        DispatchQueue.main.async {
            switch type {
            case "play":
                do {
                    try self.activateAudioSession()
                    if self.player == nil,
                       self.isQueueEngineActive,
                       let song = self.queueEngine.currentSong {
                        let startTime = self.savedRestoreTime
                        self.savedRestoreTime = nil
                        self.queueEngine.clearRestoredFlag()
                        self.stateQueue.async {
                            self.queueEngine.delegate?.queueEngine(
                                self.queueEngine,
                                loadSong: song,
                                autoplay: true,
                                startTime: startTime
                            )
                        }
                    } else if self.isPlayerAtEnd {
                        self.seekToStartAndPlay()
                    } else {
                        self.player?.play()
                    }
                    self.recoveryController.startProgressMonitoring(
                        generation: self.playbackGeneration,
                        sourceKind: self.recoverySourceKind()
                    )
                } catch {
                    self.emitError(
                        code: "remote_command_failed",
                        message: error.localizedDescription
                    )
                }
            case "pause":
                self.recoveryController.reportUserPause()
                self.player?.pause()
                self.persistence.flushNow()
            case "toggle_play_pause":
                if self.player?.timeControlStatus == .playing {
                    self.recoveryController.reportUserPause()
                    self.player?.pause()
                    self.persistence.flushNow()
                } else {
                    do {
                        try self.activateAudioSession()
                        if self.isPlayerAtEnd {
                            self.seekToStartAndPlay()
                        } else {
                            self.player?.play()
                        }
                    } catch {
                        self.emitError(
                            code: "remote_command_failed",
                            message: error.localizedDescription
                        )
                    }
                }
            case "previous":
                if self.isQueueEngineActive {
                    self.isQueueTransitioning = true
                    let currentTime = self.player?.currentTime().seconds ?? 0
                    self.stateQueue.async {
                        self.queueEngine.skipToPrevious(currentTime: currentTime)
                    }
                }
            case "next":
                if self.isQueueEngineActive {
                    self.isQueueTransitioning = true
                    self.stateQueue.async {
                        self.queueEngine.skipToNext()
                    }
                }
            case "seek":
                let seconds = max(0, self.numberValue(command["seconds"]) ?? 0)
                self.isSeeking = true
                self.player?.seek(
                    to: self.makeTime(seconds),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] _ in
                    self?.isSeeking = false
                    self?.emitProgress()
                    self?.updateNowPlayingPlaybackInfo()
                    self?.persistence.updateProgress(seconds)
                    self?.persistence.flushNow()
                }
            case "set_shuffle":
                let enabled = command["enabled"] as? Bool ?? false
                self.stateQueue.async {
                    self.shuffleEnabled = enabled
                    if self.isQueueEngineActive {
                        self.queueEngine.setShuffleActive(enabled)
                        self.persistence.markStateDirty()
                    }
                }
            case "set_repeat":
                let mode = command["mode"] as? String ?? "off"
                self.stateQueue.async {
                    self.repeatMode = mode
                    if self.isQueueEngineActive,
                       let loopState = LoopState(rawValue: mode) {
                        self.queueEngine.setLoopState(loopState)
                        self.persistence.markStateDirty()
                    }
                }
            case "set_volume":
                let volume = self.numberValue(command["volume"]) ?? 0.5
                self.setSystemVolumeValue(volume)
            case "clear_queue":
                self.stateQueue.async {
                    self.queueEngine.clearUserQueue()
                    self.persistence.markStateDirty()
                }
            case "remove_from_queue":
                let ids = Set(self.stringArray(command["song_ids"]))
                guard !ids.isEmpty else { return }
                self.stateQueue.async {
                    let indices = self.queueEngine.userQueue.enumerated().compactMap { item in
                        ids.contains(item.element.id) ? item.offset : nil
                    }
                    self.queueEngine.removeFromUserQueue(indices: indices)
                    self.persistence.markStateDirty()
                }
            case "reorder_queue":
                let from = command["from"] as? Int ?? -1
                let to = command["to"] as? Int ?? -1
                self.stateQueue.async {
                    self.queueEngine.reorderContextQueue(fromIndex: from, toIndex: to)
                    self.persistence.markStateDirty()
                }
            case "toggle_like":
                self.toggleLikeForCurrentSong()
            default:
                break
            }
        }

        return true
    }

    private func playSongById(_ id: String) {
        playSongIdsAtIndex(ids: [id], index: 0)
    }

    private func playAlbumById(_ id: String, index: Int, shuffle: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let repo = AlbumRepository(db: DatabaseManager.shared.dbPool)
                guard let result = try repo.getWithSongs(id), !result.songs.isEmpty else {
                    return
                }
                self.playQueueSongsAtIndex(
                    songs: result.songs.map { $0.toQueueSong() },
                    index: index,
                    shuffle: shuffle,
                    sourceId: QueueSourceId(type: "album", id: id),
                    sourceName: result.album.name
                )
            } catch {
                NativeLogger.shared.warn(
                    "Failed to execute native play_album: \(error.localizedDescription)",
                    source: "Audio"
                )
            }
        }
    }

    private func playPlaylistById(_ id: String, index: Int, shuffle: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let repo = PlaylistRepository(db: DatabaseManager.shared.dbPool)
                guard let detail = try repo.getDetailById(id) else {
                    return
                }
                let songs = try self.loadQueueSongs(ids: self.playlistEntrySongIds(detail.entriesJson))
                guard !songs.isEmpty else {
                    return
                }
                self.playQueueSongsAtIndex(
                    songs: songs,
                    index: index,
                    shuffle: shuffle,
                    sourceId: QueueSourceId(type: "playlist", id: id),
                    sourceName: detail.name
                )
            } catch {
                NativeLogger.shared.warn(
                    "Failed to execute native play_playlist: \(error.localizedDescription)",
                    source: "Audio"
                )
            }
        }
    }

    private func addSongIdsToQueue(ids: [String], position: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let songs = try self.loadQueueSongs(ids: ids)
                guard !songs.isEmpty else {
                    return
                }

                self.stateQueue.async {
                    self.queueEngine.addToUserQueue(
                        songs: songs,
                        position: position
                    )
                    self.persistence.markStateDirty()
                }
            } catch {
                NativeLogger.shared.warn(
                    "Failed to execute native add_to_queue: \(error.localizedDescription)",
                    source: "Audio"
                )
            }
        }
    }

    private func playSongIdsAtIndex(ids: [String], index: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let songs = try self.loadQueueSongs(ids: ids)
                guard !songs.isEmpty else {
                    return
                }
                self.playQueueSongsAtIndex(
                    songs: songs,
                    index: index,
                    shuffle: false,
                    sourceId: nil,
                    sourceName: nil
                )
            } catch {
                NativeLogger.shared.warn(
                    "Failed to execute native play_at_index: \(error.localizedDescription)",
                    source: "Audio"
                )
            }
        }
    }

    private func playQueueSongsAtIndex(
        songs: [QueueSong],
        index: Int,
        shuffle: Bool,
        sourceId: QueueSourceId?,
        sourceName: String?
    ) {
        let clampedIndex = max(0, min(index, songs.count - 1))
        self.stateQueue.async {
            self.isQueueEngineActive = true
            self.queueEngine.setContextQueue(
                songs: songs,
                currentIndex: clampedIndex,
                autoplay: true,
                startTime: nil,
                sourceId: sourceId,
                sourceName: sourceName
            )
            if shuffle {
                self.queueEngine.setShuffleActive(true)
            }
            self.queueEngine(self.queueEngine, didChangeContents: "queue-edit")
        }
    }

    private func toggleLikeForCurrentSong() {
        stateQueue.async {
            guard let current = self.queueEngine.currentSong else {
                return
            }
            let repo = SongRepository(db: DatabaseManager.shared.dbPool)
            do {
                let song = try repo.getById(current.id)
                let nextStarredAt = song?.starredAt == nil ? Int(Date().timeIntervalSince1970) : nil
                try repo.updateStarred(ids: [current.id], starred: nextStarredAt.map(String.init), starredAt: nextStarredAt)
                DispatchQueue.main.async {
                    MPRemoteCommandCenter.shared().likeCommand.isActive = nextStarredAt != nil
                }
            } catch {
                NativeLogger.shared.warn(
                    "Failed to execute native toggle_like: \(error.localizedDescription)",
                    source: "Audio"
                )
            }
        }
    }

    private func loadQueueSongs(ids: [String]) throws -> [QueueSong] {
        let repo = SongRepository(db: DatabaseManager.shared.dbPool)
        let records = try repo.getByIds(ids: ids)
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ids.compactMap { byId[$0]?.toQueueSong() }
    }

    private func prepareHandoffPlayback(
        snapshot: [String: Any],
        autoplay: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        cancelCarPlaySelection()
        let generation = stateQueue.sync { () -> Int in
            handoffGeneration += 1
            return handoffGeneration
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let songId = snapshot["songId"] as? String, !songId.isEmpty else {
                completion(false)
                return
            }

            do {
                let inUserQueue = snapshot["inUserQueue"] as? Bool ?? false
                var contextIds = self.stringArray(snapshot["contextQueue"])
                if contextIds.isEmpty && !inUserQueue { contextIds = [songId] }
                let userIds = self.stringArray(snapshot["userQueue"])
                let historyIds = self.stringArray(snapshot["restorePrevious"])
                let ids = Array(Set(contextIds + userIds + historyIds + [songId]))
                let resolved = try self.loadQueueSongs(ids: ids)
                let byId = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
                guard ids.allSatisfy({ byId[$0] != nil }) else {
                    completion(false)
                    return
                }
                let songs = contextIds.compactMap { byId[$0] }
                let userSongs = userIds.compactMap { byId[$0] }
                let history = historyIds.compactMap { byId[$0] }
                let resolvedIndex = snapshot["contextIndex"] as? Int ?? (contextIds.firstIndex(of: songId) ?? 0)
                let current = inUserQueue ? userSongs.first : (songs.indices.contains(resolvedIndex) ? songs[resolvedIndex] : nil)
                guard current?.id == songId else {
                    completion(false)
                    return
                }
                let progressSeconds = max(0, self.numberValue(snapshot["progressSeconds"]) ?? 0)
                let repeatMode = snapshot["repeat"] as? String ?? "off"
                let shuffle = snapshot["shuffle"] as? Bool ?? false
                let sourceId = self.parseSnapshotSourceId(snapshot["sourceId"] as? String)
                let sourceName = snapshot["sourceName"] as? String
                let volume = self.numberValue(snapshot["volume"])

                self.stateQueue.async {
                    guard generation == self.handoffGeneration else {
                        completion(false)
                        return
                    }
                    if !autoplay, self.preparedHandoffBefore == nil {
                        let time = self.player?.currentTime().seconds ?? 0
                        self.preparedHandoffBefore = (
                            PlaybackPersistState(from: self.queueEngine, currentTime: time.isFinite ? time : 0),
                            (self.player?.rate ?? 0) > 0
                        )
                    }
                    self.isQueueEngineActive = true
                    var state = PlaybackPersistState(from: self.queueEngine, currentTime: progressSeconds)
                    state.contextSongs = songs
                    state.currentIndex = resolvedIndex
                    state.userQueue = userSongs
                    state.originalContextSongs = songs
                    state.originalUserSongs = userSongs
                    state.playedUserQueueHistory = history
                    state.isInUserQueue = inUserQueue
                    state.isShuffleActive = shuffle
                    state.shuffleHistory = []
                    state.shuffleStartHistory = []
                    state.loopState = repeatMode
                    state.sourceId = sourceId
                    state.sourceName = sourceName
                    self.queueEngine.restoreState(from: state)
                    self.repeatMode = repeatMode
                    self.shuffleEnabled = shuffle
                    if let current {
                        self.queueEngine(self.queueEngine, loadSong: current, autoplay: autoplay, startTime: progressSeconds)
                        self.forceNextSnapshotProgress(progressSeconds)
                    }
                    self.queueEngine(self.queueEngine, didChangeContents: "queue-edit")
                    self.persistence.markStateDirty()
                    if autoplay, let volume {
                        self.setSystemVolumeValue(volume)
                    }
                    if autoplay { self.preparedHandoffBefore = nil }
                    completion(true)
                }
            } catch {
                NativeLogger.shared.warn(
                    "Failed to prepare native handoff playback: \(error.localizedDescription)",
                    source: "Audio"
                )
                completion(false)
            }
        }
    }

    internal static func rollbackHandoffPlaybackFromActive() {
        guard let instance = activeInstance else { return }
        instance.stateQueue.async {
            instance.handoffGeneration += 1
            guard let (state, autoplay) = instance.preparedHandoffBefore else { return }
            instance.preparedHandoffBefore = nil
            instance.queueEngine.restoreState(from: state)
            instance.repeatMode = state.loopState
            instance.shuffleEnabled = state.isShuffleActive
            if let song = instance.queueEngine.currentSong {
                instance.queueEngine(instance.queueEngine, loadSong: song, autoplay: autoplay, startTime: state.currentTime)
                instance.forceNextSnapshotProgress(state.currentTime)
            } else {
                DispatchQueue.main.async {
                    instance.player?.pause()
                    instance.player?.replaceCurrentItem(with: nil)
                }
            }
            instance.queueEngine(instance.queueEngine, didChangeContents: "queue-edit")
            instance.persistence.markStateDirty()
        }
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [String] ?? []).filter { !$0.isEmpty }
    }

    private func parseSnapshotSourceId(_ raw: String?) -> QueueSourceId? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        switch parts[0] {
        case "album", "playlist", "artist", "genre", "radio":
            return QueueSourceId(type: parts[0], id: parts[1])
        default:
            return nil
        }
    }

    private func playlistEntrySongIds(_ entriesJson: String) -> [String] {
        guard let data = entriesJson.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            let id = entry["id"] as? String
            return id?.isEmpty == false ? id : nil
        }
    }

    private func setSystemVolumeValue(_ value: Double) {
        let clampedValue = Float(min(max(value, 0.0), 1.0))
        try? activateAudioSession()

        resolveVolumeSlider { [weak self] slider in
            guard let self else { return }
            guard let slider else {
                self.emitError(
                    code: "volume_control_unavailable",
                    message: "System volume control is unavailable."
                )
                return
            }

            slider.setValue(clampedValue, animated: false)
            slider.sendActions(for: .touchUpInside)
            slider.sendActions(for: .valueChanged)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                let volume = self.audioSession.outputVolume
                self.notifyListeners("systemVolumeChanged", data: ["volume": volume])
            }
        }
    }

    func load(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        if isQueueEngineActive {
            call.resolve()
            return
        }

        guard let source = call.getObject("source") else {
            reject(call, code: "invalid_source", message: "Missing audio source.")
            return
        }

        let startTime = max(0, call.getDouble("startTime") ?? 0)
        let autoplay = call.getBool("autoplay") ?? false
        let metadata = self.metadata(from: call.getObject("metadata"))
        let requestId = call.getString("requestId")

        loadQueue.async { [self] in
            do {
                let resolvedSource = try self.resolveSource(from: source)

                if autoplay {
                    try self.activateAudioSession()
                }

                DispatchQueue.main.async {
                    self.clearPlayer(sendIdleEvent: false)
                    self.playbackGeneration += 1
                    let generation = self.playbackGeneration

                    let item = self.makePlayerItem(url: resolvedSource.url, kind: resolvedSource.kind, songId: resolvedSource.songId)
                    let player = AVPlayer(playerItem: item)
                    self.player = player
                    self.playerItem = item
                    self.currentSourceKind = resolvedSource.kind
                    self.currentSourceUrl = resolvedSource.url
                    self.currentRadioId = resolvedSource.radioId
                    self.currentRequestId = requestId
                    self.remotePlaybackProjection = nil
                    self.currentMetadata = metadata
                    self.loadedDurationSeconds = metadata.duration
                    self.addObservers(for: item, player: player, generation: generation, requestId: requestId)
                    self.addProgressObserver(to: player, generation: generation, requestId: requestId)
                    self.recoveryController.startProgressMonitoring(generation: generation, sourceKind: self.recoverySourceKind())
                    self.updateNowPlayingInfo()

                    self.emitPlaybackState("loading", requestId: requestId)

                    if startTime > 0 {
                        player.seek(to: self.makeTime(startTime))
                    }

                    if autoplay {
                        player.play()
                    }

                    call.resolve()
                }
            } catch {
                DispatchQueue.main.async {
                    self.reject(call, error: error)
                }
            }
        }
    }

    func play(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        DispatchQueue.main.async {
            do {
                if self.player == nil && self.isQueueEngineActive, let song = self.queueEngine.currentSong {
                    try self.activateAudioSession()
                    let startTime = self.savedRestoreTime
                    self.savedRestoreTime = nil
                    self.queueEngine.clearRestoredFlag()
                    self.stateQueue.async {
                        self.queueEngine.delegate?.queueEngine(self.queueEngine, loadSong: song, autoplay: true, startTime: startTime)
                    }
                    call.resolve()
                    return
                }

                guard let player = self.player else {
                    self.reject(call, code: "no_source", message: "No audio source is loaded.")
                    return
                }

                try self.activateAudioSession()
                if self.isPlayerAtEnd {
                    self.seekToStartAndPlay()
                } else {
                    player.play()
                }
                self.recoveryController.startProgressMonitoring(
                    generation: self.playbackGeneration,
                    sourceKind: self.recoverySourceKind()
                )
                call.resolve()
            } catch {
                self.reject(call, error: error)
            }
        }
    }

    func pause(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        DispatchQueue.main.async {
            self.recoveryController.reportUserPause()
            self.player?.pause()
            self.persistence.flushNow()
            call.resolve()
        }
    }

    func stop(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        DispatchQueue.main.async {
            self.player?.pause()
            self.player?.seek(to: .zero)
            self.emitPlaybackState("stopped")
            self.emitProgress()
            self.deactivateAudioSession()
            call.resolve()
        }
    }

    func seek(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async {
            guard let player = self.player else {
                self.reject(call, code: "no_source", message: "No audio source is loaded.")
                return
            }

            self.recoveryController.reportUserSeek()
            let position = max(0, call.getDouble("position") ?? 0)
            self.isSeeking = true
            player.seek(to: self.makeTime(position), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                self.isSeeking = false
                self.emitProgress()
                self.updateNowPlayingPlaybackInfo()
                self.persistence.updateProgress(position)
                self.persistence.flushNow()
                if finished {
                    call.resolve()
                } else {
                    self.reject(call, code: "seek_cancelled", message: "Native seek was cancelled.")
                }
            }
        }
    }

    func setRepeatMode(_ call: NativePlaybackRequest) {
        stateQueue.async {
            let mode = call.getString("mode") ?? "off"
            guard ["off", "one", "all"].contains(mode) else {
                self.reject(call, code: "invalid_repeat_mode", message: "Unsupported repeat mode: \(mode).")
                return
            }

            self.repeatMode = mode
            self.notifyListeners("queueContentsChanged", data: ["reason": "playback-mode"])
            DispatchQueue.main.async { self.updateSystemPlaybackModes() }
            if self.isQueueEngineActive, let loopState = LoopState(rawValue: mode) {
                self.queueEngine.setLoopState(loopState)
                self.persistence.markStateDirty()
            }
            call.resolve()
        }
    }

    func setShuffle(_ call: NativePlaybackRequest) {
        stateQueue.async {
            let enabled = call.getBool("enabled") ?? false
            self.shuffleEnabled = enabled
            self.notifyListeners("nativeMetadataChanged", data: [:])
            DispatchQueue.main.async { self.updateSystemPlaybackModes() }
            if self.isQueueEngineActive {
                self.queueEngine.setShuffleActive(enabled)
                self.persistence.markStateDirty()
            }
            call.resolve()
        }
    }

    func markAsShuffled(_ call: NativePlaybackRequest) {
        stateQueue.async {
            let songsArray = call.getArray("originalSongs") as? [[String: Any]] ?? []
            let originalSongs = songsArray.map { QueueSong(from: $0) }
            self.shuffleEnabled = true
            self.queueEngine.markAsShuffled(originalSongs: originalSongs)
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func setQueue(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        stateQueue.async {
            let items = call.getArray("items") ?? []
            let requestedIndex = call.getInt("index") ?? 0

            guard requestedIndex >= 0 else {
                self.reject(call, code: "invalid_queue", message: "Queue index must be non-negative.")
                return
            }

            if items.isEmpty {
                guard requestedIndex == 0 else {
                    self.reject(call, code: "invalid_queue", message: "Empty native queue must use index 0.")
                    return
                }
                self.queueItemCount = 0
                self.queueIndex = 0
                call.resolve()
                return
            }

            guard requestedIndex < items.count else {
                self.reject(call, code: "invalid_queue", message: "Queue index is outside the native queue.")
                return
            }

            self.queueItemCount = items.count
            self.queueIndex = requestedIndex
            call.resolve()
        }
    }

    func skipToNext(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        if isQueueEngineActive {
            isQueueTransitioning = true
        }
        stateQueue.async {
            if self.isQueueEngineActive {
                self.queueEngine.skipToNext()
            } else {
                self.emitRemoteCommand("next")
            }
            call.resolve()
        }
    }

    func skipToPrevious(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        if isQueueEngineActive {
            isQueueTransitioning = true
        }
        stateQueue.async {
            if self.isQueueEngineActive {
                let currentTime = self.player?.currentTime().seconds ?? 0
                self.queueEngine.skipToPrevious(currentTime: currentTime)
            } else {
                self.emitRemoteCommand("previous")
            }
            call.resolve()
        }
    }

    func updateMetadata(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async {
            self.remotePlaybackProjection = nil
            self.currentMetadata = self.metadata(from: call)
            self.updateNowPlayingInfo()
            call.resolve()
        }
    }

    func updateRemotePlaybackState(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async {
            let metadata = self.metadata(from: call.getObject("metadata"))
            let position = max(0, self.numberValue(call.getValue("position")) ?? 0)
            let duration = max(
                0,
                self.numberValue(call.getValue("duration")) ??
                    metadata.duration ??
                    0
            )
            self.remotePlaybackProjection = NativeRemotePlaybackProjection(
                metadata: metadata,
                isPlaying: call.getBool("isPlaying") ?? false,
                position: position,
                duration: duration,
                isShuffleActive: call.getBool("isShuffleActive") ?? false,
                repeatMode: call.getString("repeatMode") ?? "off",
                volume: self.numberValue(call.getValue("volume")),
                targetDeviceId: call.getString("targetDeviceId"),
                expectedGeneration: call.getInt("expectedGeneration")
            )
            self.currentMetadata = metadata
            self.updateNowPlayingInfo()
            call.resolve()
        }
    }

    func clearRemotePlaybackState(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async {
            self.remotePlaybackProjection = nil
            if self.player != nil || self.isQueueEngineActive {
                self.updateNowPlayingInfo()
            } else {
                self.clearNowPlayingInfo()
            }
            call.resolve()
        }
    }

    private func updateRemotePlaybackProjection(
        snapshot: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int
    ) {
        let songId = snapshot["songId"] as? String ?? ""
        Task.detached(priority: .userInitiated) { [weak self] in
            let song = await self?.loadRemotePlaybackSong(songId: songId)
            await MainActor.run { [weak self] in
                self?.applyRemotePlaybackProjection(
                    snapshot: snapshot,
                    targetDeviceId: targetDeviceId,
                    expectedGeneration: expectedGeneration,
                    song: song
                )
            }
        }
    }

    private func applyRemotePlaybackProjection(
        snapshot: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int,
        song: SongRecord?
    ) {
        let songId = snapshot["songId"] as? String ?? ""
        let duration = max(
            0,
            self.numberValue(snapshot["durationSeconds"]) ?? 0
        )
        let metadata = song?.remotePlaybackMetadata()
            ?? NativeAudioMetadata(
                title: songId.isEmpty ? "Remote playback" : songId,
                artist: snapshot["sourceName"] as? String,
                album: nil,
                duration: duration,
                artworkUrl: nil,
                coverArtId: nil
            )
        self.remotePlaybackProjection = NativeRemotePlaybackProjection(
            metadata: metadata,
            isPlaying: snapshot["isPlaying"] as? Bool ?? false,
            position: max(
                0,
                self.numberValue(snapshot["progressSeconds"]) ?? 0
            ),
            duration: duration,
            isShuffleActive: snapshot["shuffle"] as? Bool ?? false,
            repeatMode: snapshot["repeat"] as? String ?? "off",
            volume: self.numberValue(snapshot["volume"]),
            targetDeviceId: targetDeviceId,
            expectedGeneration: expectedGeneration
        )
        self.currentMetadata = metadata
        self.updateNowPlayingInfo()
    }

    private func clearRemotePlaybackProjection() {
        DispatchQueue.main.async {
            self.remotePlaybackProjection = nil
            if self.player != nil || self.isQueueEngineActive {
                self.updateNowPlayingInfo()
            } else {
                self.clearNowPlayingInfo()
            }
        }
    }

    func preload(_ call: NativePlaybackRequest) {
        call.resolve()
    }

    func clear(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        DispatchQueue.main.async {
            self.clearPlayer(sendIdleEvent: true, deactivateSession: true)
            self.resetControlState()
            self.remotePlaybackProjection = nil
            self.savedRestoreTime = nil
            self.persistence.stopProgressTracking()
            self.stateQueue.async {
                self.isQueueEngineActive = false
                self.queueEngine.setContextQueue(songs: [], currentIndex: 0, autoplay: false, startTime: nil)
                self.queueEngine.setLoopState(.off)
                self.queueRevision += 1
                try? self.persistence.repository.clear()
                self.notifyListeners("queueContentsChanged", data: ["reason": "queue-edit"])
                call.resolve()
            }
        }
    }

    func storeAudioFile(_ call: NativePlaybackRequest) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            reject(call, code: "invalid_cache_request", message: "Missing songId for native audio cache storage.")
            return
        }

        guard let dataBase64 = call.getString("dataBase64"), !dataBase64.isEmpty else {
            reject(call, code: "invalid_cache_request", message: "Missing base64 audio data for native audio cache storage.")
            return
        }

        let contentType = call.getString("contentType") ?? "audio/mpeg"

        DispatchQueue.global(qos: .utility).async {
            do {
                let file = try self.storeCachedAudioFile(
                    songId: songId,
                    dataBase64: dataBase64,
                    contentType: contentType
                )
                CarPlayLibraryProvider.recordCached(songId: songId, size: Int(file.sizeBytes ?? 0))
                DispatchQueue.main.async {
                    call.resolve(self.jsObject(from: file))
                }
            } catch {
                DispatchQueue.main.async {
                    self.reject(call, error: error)
                }
            }
        }
    }

    func resolveAudioFile(_ call: NativePlaybackRequest) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            reject(call, code: "invalid_cache_request", message: "Missing songId for native audio cache resolution.")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let file = try self.resolveCachedAudioFile(songId: songId)
                DispatchQueue.main.async {
                    call.resolve([
                        "file": file.map { self.jsObject(from: $0) } ?? NSNull(),
                    ])
                }
            } catch {
                DispatchQueue.main.async {
                    self.reject(call, error: error)
                }
            }
        }
    }

    func getAudioFileSize(_ call: NativePlaybackRequest) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            reject(call, code: "invalid_cache_request", message: "Missing songId for native audio cache size lookup.")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let file = try self.resolveCachedAudioFile(songId: songId)
                DispatchQueue.main.async {
                    call.resolve([
                        "sizeBytes": file?.sizeBytes.map { NSNumber(value: $0) } ?? NSNull(),
                    ])
                }
            } catch {
                DispatchQueue.main.async {
                    self.reject(call, error: error)
                }
            }
        }
    }

    func deleteAudioFile(_ call: NativePlaybackRequest) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            reject(call, code: "invalid_cache_request", message: "Missing songId for native audio cache deletion.")
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let deleted = try self.deleteCachedAudioFile(songId: songId)
                DispatchQueue.main.async {
                    call.resolve(["deleted": deleted])
                }
            } catch {
                DispatchQueue.main.async {
                    self.reject(call, error: error)
                }
            }
        }
    }

    func clearAudioFiles(_ call: NativePlaybackRequest) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let deletedCount = try self.clearCachedAudioFiles()
                DispatchQueue.main.async {
                    call.resolve(["deletedCount": deletedCount])
                }
            } catch {
                DispatchQueue.main.async {
                    self.reject(call, error: error)
                }
            }
        }
    }

    // MARK: - Debug

    func debugSnapshot() -> AudioDebugSnapshot {
        let currentTime = seconds(from: player?.currentTime() ?? .zero)
        let duration = durationSeconds()
        let buffered = bufferedTime()

        let recoveryDesc: String
        switch recoveryController.state {
        case .idle: recoveryDesc = "idle"
        case .level1(let attempt): recoveryDesc = "level1 (attempt \(attempt))"
        case .level2(let attempt): recoveryDesc = "level2 (attempt \(attempt))"
        case .gaveUp: recoveryDesc = "gaveUp"
        }

        let queueItems = queueEngine.contextSongs.enumerated().map { i, song in
            QueueItemInfo(
                id: song.id,
                title: song.title,
                artist: song.artist,
                duration: song.duration,
                isCurrent: !queueEngine.isInUserQueue && i == queueEngine.currentIndex
            )
        }

        let userQueueItems = queueEngine.userQueue.map { song in
            QueueItemInfo(
                id: song.id,
                title: song.title,
                artist: song.artist,
                duration: song.duration,
                isCurrent: false
            )
        }

        return AudioDebugSnapshot(
            title: currentMetadata.title,
            artist: currentMetadata.artist,
            album: currentMetadata.album,
            isPlaying: player?.timeControlStatus == .playing,
            currentTime: currentTime,
            duration: duration,
            bufferedTime: buffered,
            sourceKind: currentSourceKind,
            bufferEmpty: playerItem?.isPlaybackBufferEmpty ?? true,
            likelyToKeepUp: playerItem?.isPlaybackLikelyToKeepUp ?? false,
            recoveryState: recoveryDesc,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            queueIndex: queueIndex,
            queueItemCount: queueItemCount,
            queue: queueItems,
            userQueue: userQueueItems
        )
    }

    func debugPlayPause() {
        if player?.timeControlStatus == .playing {
            recoveryController.reportUserPause()
            player?.pause()
            emitPlaybackState("paused")
        } else {
            do { try activateAudioSession() } catch { return }
            player?.play()
            emitPlaybackState("playing")
        }
    }

    func debugSkipNext() {
        if isQueueEngineActive {
            stateQueue.async { self.queueEngine.skipToNext() }
        }
    }

    func debugSkipPrevious() {
        if isQueueEngineActive {
            let time = seconds(from: player?.currentTime() ?? .zero)
            stateQueue.async { self.queueEngine.skipToPrevious(currentTime: time) }
        }
    }

    // MARK: - Native Queue Control

    func setContextQueue(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        stateQueue.async {
            let songsArray = call.getArray("songs") as? [[String: Any]] ?? []
            let songs = songsArray.map { QueueSong(from: $0) }
            let currentIndex = call.getInt("currentIndex") ?? 0
            let autoplay = call.getBool("autoplay") ?? true
            let startTime = call.getDouble("startTime")

            var sourceId: QueueSourceId?
            if let srcObj = call.getObject("sourceId"),
               let type = srcObj["type"] as? String,
               let id = srcObj["id"] as? String {
                sourceId = QueueSourceId(type: type, id: id)
            }
            let sourceName = call.getString("sourceName")

            self.isQueueEngineActive = true

            if let mode = call.getString("repeatMode"), let loopState = LoopState(rawValue: mode) {
                self.queueEngine.setLoopState(loopState)
                self.repeatMode = mode
            }

            self.queueEngine.setContextQueue(
                songs: songs,
                currentIndex: currentIndex,
                autoplay: autoplay,
                startTime: startTime,
                sourceId: sourceId,
                sourceName: sourceName
            )
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func addToUserQueue(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        stateQueue.async {
            let songsArray = call.getArray("songs") as? [[String: Any]] ?? []
            let songs = songsArray.map { QueueSong(from: $0) }
            let position = call.getString("position") ?? "last"

            self.queueEngine.addToUserQueue(songs: songs, position: position)
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func removeFromUserQueue(_ call: NativePlaybackRequest) {
        stateQueue.async {
            let indices = call.getArray("indices") as? [Int] ?? []
            self.queueEngine.removeFromUserQueue(indices: indices)
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func clearUserQueue(_ call: NativePlaybackRequest) {
        stateQueue.async {
            self.queueEngine.clearUserQueue()
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func updateContextQueue(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        stateQueue.async {
            let songsArray = call.getArray("songs") as? [[String: Any]] ?? []
            let songs = songsArray.map { QueueSong(from: $0) }
            let currentIndex = call.getInt("currentIndex") ?? 0

            self.queueEngine.updateContextQueue(songs: songs, currentIndex: currentIndex)
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func reorderContextQueue(_ call: NativePlaybackRequest) {
        stateQueue.async {
            let fromIndex = call.getInt("fromIndex") ?? 0
            let toIndex = call.getInt("toIndex") ?? 0

            self.queueEngine.reorderContextQueue(fromIndex: fromIndex, toIndex: toIndex)
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func playAtIndex(_ call: NativePlaybackRequest) {
        cancelCarPlaySelection()
        stateQueue.async {
            let index = call.getInt("index") ?? 0
            let startTime = call.getDouble("startTime")
            self.queueEngine.playAtIndex(index, startTime: startTime)
            self.persistence.markStateDirty()
            call.resolve()
        }
    }

    func getFullState(_ call: NativePlaybackRequest) {
        stateQueue.async {
            call.resolve(self.currentFullState() ?? [:])
        }
    }

    private func currentFullState() -> [String: Any]? {
        let playerCurrentTime = self.player == nil ? (self.savedRestoreTime ?? 0) : self.seconds(from: self.player?.currentTime() ?? .zero)
        let currentTime = self.consumeSnapshotProgressSeconds(
            fallback: playerCurrentTime
        )
        let duration = self.durationSeconds()
        let isPlaying = self.player?.timeControlStatus == .playing

        return self.queueEngine.getFullState(
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying
        )
    }

    private func pauseAndGetCurrentFullState() -> [String: Any]? {
        if Thread.isMainThread {
            self.player?.pause()
            self.persistence.flushNow()
            return self.currentFullState()
        }

        var snapshot: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.player?.pause()
            self.persistence.flushNow()
            snapshot = self.currentFullState()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        return snapshot
    }

    func resolveSongs(_ call: NativePlaybackRequest) {
        let ids = call.getArray("ids") as? [String] ?? []
        guard !ids.isEmpty else {
            call.resolve(["songs": []])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let repo = SongRepository(db: DatabaseManager.shared.dbPool)
                let records = try repo.getByIds(ids: ids)
                let songs = records.map { $0.toDictionary() }
                call.resolve(["songs": songs])
            } catch {
                call.resolve(["songs": []])
            }
        }
    }

    func getScrobbleBuffer(_ call: NativePlaybackRequest) {
        stateQueue.async {
            let entries = self.scrobbleBuffer.getEntriesAsArray()
            call.resolve(["entries": entries])
        }
    }

    func clearScrobbleBuffer(_ call: NativePlaybackRequest) {
        stateQueue.async {
            self.scrobbleBuffer.clear()
            call.resolve()
        }
    }

    func downloadAudioFile(_ call: NativePlaybackRequest) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            reject(call, code: "invalid_download_request", message: "Missing songId for audio download.")
            return
        }

        let maxBitRate = call.getInt("maxBitRate")
        let format = call.getString("format")
        downloadManager.download(songId: songId, maxBitRate: maxBitRate, format: format)
        call.resolve()
    }

    func cancelDownload(_ call: NativePlaybackRequest) {
        if let songId = call.getString("songId") {
            downloadManager.cancel(songId: songId)
        } else {
            downloadManager.cancelAll()
        }
        call.resolve()
    }

    private func storeCachedAudioFile(
        songId: String,
        dataBase64: String,
        contentType: String
    ) throws -> NativeCachedAudioFile {
        guard let data = Data(base64Encoded: dataBase64) else {
            throw NativeAudioPluginError.invalidCacheRequest("Native audio cache data is not valid base64.")
        }

        let directory = try cacheDirectoryURL(createIfNeeded: true)
        _ = try deleteCachedAudioFile(songId: songId)

        let fileName = "\(cacheId(for: songId)).\(fileExtension(for: contentType))"
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])

        let metadata = NativeCachedAudioFileMetadata(
            songId: songId,
            fileName: fileName,
            contentType: contentType,
            lastModifiedAt: Date().timeIntervalSince1970 * 1000
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataURL(for: songId, in: directory), options: [.atomic])

        return try cachedAudioFile(
            songId: songId,
            directory: directory,
            metadata: metadata
        ) ?? NativeCachedAudioFile(
            songId: songId,
            uri: fileURL.absoluteString,
            contentType: contentType,
            sizeBytes: Int64(data.count),
            lastModifiedAt: metadata.lastModifiedAt
        )
    }

    private func resolveCachedAudioFile(songId: String) throws -> NativeCachedAudioFile? {
        let primaryDirectory = try cacheDirectoryURL(createIfNeeded: false)
        if FileManager.default.fileExists(atPath: primaryDirectory.path) {
            if let file = try cachedAudioFile(songId: songId, directory: primaryDirectory) {
                return file
            }
        }

        let secondaryDirectory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: false)
        if secondaryDirectory.path != primaryDirectory.path,
           FileManager.default.fileExists(atPath: secondaryDirectory.path) {
            return try cachedAudioFile(songId: songId, directory: secondaryDirectory)
        }

        return nil
    }

    private func deleteCachedAudioFile(songId: String) throws -> Bool {
        let cacheId = cacheId(for: songId)
        let fileManager = FileManager.default
        var deleted = false

        let primaryDirectory = try cacheDirectoryURL(createIfNeeded: false)
        if fileManager.fileExists(atPath: primaryDirectory.path) {
            let urls = try fileManager.contentsOfDirectory(at: primaryDirectory, includingPropertiesForKeys: nil)
            for url in urls where url.lastPathComponent.hasPrefix("\(cacheId).") {
                try fileManager.removeItem(at: url)
                deleted = true
            }
        }

        let secondaryDirectory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: false)
        if secondaryDirectory.path != primaryDirectory.path,
           fileManager.fileExists(atPath: secondaryDirectory.path) {
            let urls = try fileManager.contentsOfDirectory(at: secondaryDirectory, includingPropertiesForKeys: nil)
            for url in urls where url.lastPathComponent.hasPrefix("\(cacheId).") {
                try fileManager.removeItem(at: url)
                deleted = true
            }
        }

        return deleted
    }

    private func clearCachedAudioFiles() throws -> Int {
        let directory = try cacheDirectoryURL(createIfNeeded: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return 0
        }

        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var deletedAudioFileCount = 0

        for url in urls {
            if url.pathExtension != "json" {
                deletedAudioFileCount += 1
            }
            try fileManager.removeItem(at: url)
        }

        return deletedAudioFileCount
    }

    private func cachedAudioFile(
        songId: String,
        directory: URL,
        metadata: NativeCachedAudioFileMetadata? = nil
    ) throws -> NativeCachedAudioFile? {
        let resolvedMetadata: NativeCachedAudioFileMetadata?
        if let metadata {
            resolvedMetadata = metadata
        } else {
            resolvedMetadata = try readCachedAudioFileMetadata(
                songId: songId,
                directory: directory
            )
        }
        var fileURL: URL?

        if let fileName = resolvedMetadata?.fileName {
            let candidate = directory.appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                fileURL = candidate
            }
        }

        if fileURL == nil {
            fileURL = try findCachedAudioFileURL(songId: songId, directory: directory)
        }

        guard let fileURL else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes?[.size] as? NSNumber)?.int64Value
        let modifiedAt = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSince1970

        return NativeCachedAudioFile(
            songId: songId,
            uri: fileURL.absoluteString,
            contentType: resolvedMetadata?.contentType,
            sizeBytes: sizeBytes,
            lastModifiedAt: resolvedMetadata?.lastModifiedAt ?? modifiedAt.map { $0 * 1000 }
        )
    }

    private func readCachedAudioFileMetadata(
        songId: String,
        directory: URL
    ) throws -> NativeCachedAudioFileMetadata? {
        let url = metadataURL(for: songId, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NativeCachedAudioFileMetadata.self, from: data)
    }

    private func findCachedAudioFileURL(songId: String, directory: URL) throws -> URL? {
        let cacheId = cacheId(for: songId)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        return urls.first {
            $0.lastPathComponent.hasPrefix("\(cacheId).") && $0.pathExtension != "json"
        }
    }

    private func cacheDirectoryURL(createIfNeeded: Bool) throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NativeAudioPluginError.cacheFailure("Unable to locate Application Support directory.")
        }

        let directory = applicationSupport
            .appendingPathComponent("Aonsoku", isDirectory: true)
            .appendingPathComponent("AudioCache", isDirectory: true)

        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var resourceURL = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? resourceURL.setResourceValues(resourceValues)
        }

        return directory
    }

    private func metadataURL(for songId: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(cacheId(for: songId)).json", isDirectory: false)
    }

    private func cacheId(for songId: String) -> String {
        AudioCacheUtils.cacheId(for: songId)
    }

    private func fileExtension(for contentType: String) -> String {
        let normalized = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch normalized {
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/flac", "audio/x-flac":
            return "flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a":
            return "m4a"
        case "audio/aac":
            return "aac"
        case "audio/ogg", "application/ogg":
            return "ogg"
        case "audio/opus":
            return "opus"
        case "audio/wav", "audio/x-wav":
            return "wav"
        default:
            return "audio"
        }
    }

    private func jsObject(from file: NativeCachedAudioFile) -> [String: Any] {
        var object: [String: Any] = [
            "songId": file.songId,
            "uri": file.uri,
        ]

        if let contentType = file.contentType {
            object["contentType"] = contentType
        }
        if let sizeBytes = file.sizeBytes {
            object["sizeBytes"] = NSNumber(value: sizeBytes)
        }
        if let lastModifiedAt = file.lastModifiedAt {
            object["lastModifiedAt"] = lastModifiedAt
        }

        return object
    }

    private func configureAudioSession() throws {
        try audioSession.setCategory(.playback, mode: .default)
    }

    private func activateAudioSession() throws {
        try configureAudioSession()
        try audioSession.setActive(true)
    }

    private func deactivateAudioSession() {
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - System Volume Control

    private func setupVolumeControl() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            try? self.activateAudioSession()

            _ = self.ensureVolumeSlider(forceLayout: true)

            self.volumeObservation = self.audioSession.observe(\.outputVolume, options: [.initial, .new]) { [weak self] _, change in
                guard let self, let newVolume = change.newValue else { return }
                guard self.isInForeground else { return }
                DispatchQueue.main.async {
                    self.notifyListeners("systemVolumeChanged", data: ["volume": newVolume])
                }
            }
        }
    }

    func setSystemVolume(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let value = call.getFloat("value") ?? 0.5
            let clampedValue = min(max(value, 0.0), 1.0)

            try? self.activateAudioSession()

            self.volumeOperationGen += 1
            let gen = self.volumeOperationGen

            if self.isVolumeHUDEnabled {
                let tempVolumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                self.resolveTempVolumeSlider(tempVolumeView: tempVolumeView) { [weak self] slider in
                    guard let self else { return }
                    guard let slider else {
                        call.reject(
                            "System volume control is unavailable.",
                            "volume_control_unavailable"
                        )
                        return
                    }

                    slider.setValue(clampedValue, animated: false)
                    slider.sendActions(for: .touchUpInside)
                    slider.sendActions(for: .valueChanged)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self else { return }
                        let volume = self.audioSession.outputVolume
                        self.notifyListeners("systemVolumeChanged", data: ["volume": volume])
                        call.resolve(["volume": volume])
                    }
                }
                return
            }

            self.resolveVolumeSlider { [weak self] slider in
                guard let self else { return }
                guard let slider else {
                    if self.isVolumeHUDEnabled {
                        self.removeVolumeSliderView()
                    }
                    call.reject(
                        "System volume control is unavailable.",
                        "volume_control_unavailable"
                    )
                    return
                }

                slider.setValue(clampedValue, animated: false)
                slider.sendActions(for: .touchUpInside)
                slider.sendActions(for: .valueChanged)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    let volume = self.audioSession.outputVolume
                    self.notifyListeners("systemVolumeChanged", data: ["volume": volume])
                    call.resolve(["volume": volume])

                    if gen == self.volumeOperationGen, self.isVolumeHUDEnabled {
                        self.removeVolumeSliderView()
                    }
                }
            }
        }
    }

    private func resolveVolumeSlider(
        attemptsRemaining: Int = 4,
        isFirstAttempt: Bool = true,
        completion: @escaping (UISlider?) -> Void
    ) {
        if let slider = ensureVolumeSlider(forceLayout: isFirstAttempt) {
            completion(slider)
            return
        }

        guard attemptsRemaining > 0 else {
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            self.resolveVolumeSlider(
                attemptsRemaining: attemptsRemaining - 1,
                isFirstAttempt: false,
                completion: completion
            )
        }
    }

    private func resolveTempVolumeSlider(
        tempVolumeView: MPVolumeView,
        attemptsRemaining: Int = 4,
        completion: @escaping (UISlider?) -> Void
    ) {
        tempVolumeView.setNeedsLayout()
        tempVolumeView.layoutIfNeeded()
        if let slider = findSlider(in: tempVolumeView) {
            completion(slider)
            return
        }

        guard attemptsRemaining > 0 else {
            completion(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            self.resolveTempVolumeSlider(
                tempVolumeView: tempVolumeView,
                attemptsRemaining: attemptsRemaining - 1,
                completion: completion
            )
        }
    }

    private func ensureVolumeSlider(forceLayout: Bool = false) -> UISlider? {
        if let cached = self.volumeSlider, cached.window != nil {
            return cached
        }
        self.volumeSlider = nil

        var needsLayout = forceLayout
        if self.volumeSliderView == nil {
            guard let containerView = self.volumeContainerView else {
                return nil
            }

            let sliderView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 120, height: 40))
            sliderView.showsRouteButton = false
            sliderView.showsVolumeSlider = true
            sliderView.alpha = 0.001
            sliderView.isUserInteractionEnabled = false
            sliderView.accessibilityElementsHidden = true
            sliderView.clipsToBounds = true
            containerView.addSubview(sliderView)
            self.volumeSliderView = sliderView
            needsLayout = true
        }

        guard let sliderView = self.volumeSliderView else { return nil }
        if needsLayout {
            sliderView.setNeedsLayout()
            sliderView.layoutIfNeeded()
        }

        if let slider = findSlider(in: sliderView) {
            self.volumeSlider = slider
            return slider
        }

        return nil
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider {
            return slider
        }
        for subview in view.subviews {
            if let found = findSlider(in: subview) {
                return found
            }
        }
        return nil
    }

    func getSystemVolume(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async {
            try? self.activateAudioSession()
            let volume = self.audioSession.outputVolume
            call.resolve(["volume": volume])
        }
    }

    func setVolumeHUDEnabled(_ call: NativePlaybackRequest) {
        let enabled = call.getBool("enabled") ?? true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVolumeHUDEnabled = enabled
            if enabled {
                // Let iOS present its own volume overlay outside fullscreen.
                self.removeVolumeSliderView()
            } else {
                // Add a hidden slider view to suppress the system HUD.
                _ = self.ensureVolumeSlider()
            }
            call.resolve()
        }
    }

    func setLikeActive(_ call: NativePlaybackRequest) {
        let active = call.getBool("active") ?? false
        DispatchQueue.main.async {
            MPRemoteCommandCenter.shared().likeCommand.isActive = active
            call.resolve()
        }
    }

    // MARK: - Sleep Timer

    func setSleepTimer(_ call: NativePlaybackRequest) {
        let seconds = call.getDouble("seconds") ?? 0
        let mode = call.getString("mode") ?? "duration"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sleepTimer?.invalidate()
            self.sleepTimerMode = mode

            if mode == "endOfTrack" {
                self.sleepTimerEndDate = nil
            } else {
                self.sleepTimerEndDate = Date().addingTimeInterval(seconds)
                self.sleepTimer = Timer.scheduledTimer(
                    withTimeInterval: seconds,
                    repeats: false
                ) { [weak self] _ in
                    self?.fireSleepTimer()
                }
            }
            call.resolve()
        }
    }

    func cancelSleepTimer(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sleepTimer?.invalidate()
            self.sleepTimer = nil
            self.sleepTimerEndDate = nil
            self.sleepTimerMode = "duration"
            call.resolve()
        }
    }

    func getSleepTimerRemaining(_ call: NativePlaybackRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var remaining: Double = 0
            if let endDate = self.sleepTimerEndDate {
                remaining = max(0, endDate.timeIntervalSinceNow)
            }
            call.resolve(["remainingSeconds": remaining])
        }
    }

    private func fireSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndDate = nil
        sleepTimerMode = "duration"

        player?.pause()
        emitPlaybackState("paused", requestId: currentRequestId)
        updateNowPlayingPlaybackInfo()
        notifyListeners("sleepTimerFired", data: ["reason": "duration"])
    }

    private func removeVolumeSliderView() {
        volumeSlider = nil
        volumeSliderView?.removeFromSuperview()
        volumeSliderView = nil
    }

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default

        if coverImageCachedObserver == nil {
            coverImageCachedObserver = center.addObserver(
                forName: .aonsokuCoverImageCached,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleCoverImageCached(notification)
            }
        }

        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
        }

        if routeChangeObserver == nil {
            routeChangeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioSessionRouteChange(notification)
            }
        }

        if didEnterBackgroundObserver == nil {
            didEnterBackgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.logNowPlayingArtworkDiagnostics("background")
                self?.handleDidEnterBackground()
            }
        }

        if willEnterForegroundObserver == nil {
            willEnterForegroundObserver = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.logNowPlayingArtworkDiagnostics("foreground")
                self?.handleWillEnterForeground()
            }
        }

        if artworkSettingsObserver == nil {
            artworkSettingsObserver = center.addObserver(forName: LockScreenArtworkSettings.changed,
                object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    self.removeImmersiveArtwork(from: &info)
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
                self.updateNowPlayingInfo()
            }
        }
        if artworkModelObserver == nil {
            artworkModelObserver = center.addObserver(forName: LockScreenArtworkModelManager.ready,
                object: nil, queue: .main) { [weak self] _ in
                guard let self, self.currentMetadata.artworkUrl != nil else { return }
                self.updateNowPlayingInfo()
            }
        }
        if artworkResourceObservers.isEmpty {
            // Initialize the policy observer before publication observers so its
            // worker snapshots reflect the new accessibility/resource state.
            _ = LockScreenArtworkMotionPolicy.shared
            for name in [LockScreenArtworkDemand.changed, LockScreenArtworkRequests.changed,
                         UIScreen.didConnectNotification, UIScreen.didDisconnectNotification,
                         UIScreen.modeDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification,
                         Notification.Name.NSProcessInfoPowerStateDidChange,
                         ProcessInfo.thermalStateDidChangeNotification,
                         LockScreenArtworkMotionPolicy.resourcesChanged,
                         UIApplication.didReceiveMemoryWarningNotification] {
                artworkResourceObservers.append(center.addObserver(forName: name, object: nil,
                    queue: .main) { [weak self] note in
                    guard let self else { return }
                    let resourceEvent = [Notification.Name.NSProcessInfoPowerStateDidChange,
                        ProcessInfo.thermalStateDidChangeNotification, LockScreenArtworkMotionPolicy.resourcesChanged,
                        UIApplication.didReceiveMemoryWarningNotification].contains(note.name)
                    if resourceEvent && !LockScreenArtworkSettings.shared.value.resourceProtectionEnabled { return }
                    // Restriction pauses generation without retiring published videos.
                    if resourceEvent && !LockScreenArtworkMotionPolicy.shared.allowsGeneration { return }
                    if self.currentMetadata.artworkUrl != nil {
                        let keepExisting = resourceEvent || [LockScreenArtworkDemand.changed, LockScreenArtworkRequests.changed,
                            UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScreen.modeDidChangeNotification].contains(note.name)
                        if !keepExisting, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                            self.removeImmersiveArtwork(from: &info)
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                        }
                        LockScreenArtworkModelManager.shared.resumeDeferred()
                        self.updateNowPlayingInfo()
                    }
                })
            }
        }
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.logNowPlayingArtworkDiagnostics("active")
                self?.handleDidBecomeActive()
                LockScreenArtworkModelManager.shared.resumeDeferred()
                // Retry artwork prewarming after a background/pressure deferral.
                // Fetching still uses the existing local cover cache.
                if self?.currentMetadata.artworkUrl != nil {
                    self?.updateNowPlayingInfo()
                }
            }
        }
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        for observer in artworkResourceObservers { center.removeObserver(observer) }
        artworkResourceObservers.removeAll()
        if let observer = artworkSettingsObserver { center.removeObserver(observer) }
        if let observer = artworkModelObserver { center.removeObserver(observer) }
        artworkSettingsObserver = nil
        artworkModelObserver = nil

        for observer in [
            interruptionObserver,
            routeChangeObserver,
            didEnterBackgroundObserver,
            willEnterForegroundObserver,
            didBecomeActiveObserver,
            coverImageCachedObserver,
        ] {
            if let observer {
                center.removeObserver(observer)
            }
        }

        interruptionObserver = nil
        routeChangeObserver = nil
        didEnterBackgroundObserver = nil
        willEnterForegroundObserver = nil
        didBecomeActiveObserver = nil
        coverImageCachedObserver = nil
    }

    private func updateSystemPlaybackModes() {
        let center = MPRemoteCommandCenter.shared()
        let shuffle = isQueueEngineActive ? queueEngine.isShuffleActive : shuffleEnabled
        let repeatValue = isQueueEngineActive ? queueEngine.loopState.rawValue : repeatMode
        center.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = repeatValue == "all" ? .all : repeatValue == "one" ? .one : .off
    }

    private func registerRemoteCommands() {
        guard remoteCommandTargets.isEmpty else {
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        remoteCommandTargets.append((
            commandCenter.playCommand,
            commandCenter.playCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if self.remotePlaybackProjection == nil && self.isQueueEngineActive {
                    self.play(NativePlaybackRequest())
                } else {
                    self.emitRemoteCommand("play")
                }
                return .success
            }
        ))

        commandCenter.pauseCommand.isEnabled = true
        remoteCommandTargets.append((
            commandCenter.pauseCommand,
            commandCenter.pauseCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if self.remotePlaybackProjection == nil && self.isQueueEngineActive {
                    self.recoveryController.reportUserPause()
                    self.player?.pause()
                } else {
                    self.emitRemoteCommand("pause")
                }
                return .success
            }
        ))

        commandCenter.togglePlayPauseCommand.isEnabled = true
        remoteCommandTargets.append((
            commandCenter.togglePlayPauseCommand,
            commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if let projection = self.remotePlaybackProjection {
                    self.emitRemoteCommand(projection.isPlaying ? "pause" : "play")
                } else if self.isQueueEngineActive {
                    if self.player?.timeControlStatus == .playing {
                        self.recoveryController.reportUserPause()
                        self.player?.pause()
                    } else {
                        self.play(NativePlaybackRequest())
                    }
                } else {
                    self.emitRemoteCommand("play")
                }
                return .success
            }
        ))

        commandCenter.nextTrackCommand.isEnabled = true
        remoteCommandTargets.append((
            commandCenter.nextTrackCommand,
            commandCenter.nextTrackCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if self.remotePlaybackProjection == nil && self.isQueueEngineActive {
                    DispatchQueue.main.async { self.isQueueTransitioning = true }
                    self.stateQueue.async {
                        self.queueEngine.skipToNext()
                    }
                } else {
                    self.emitRemoteCommand("next")
                }
                return .success
            }
        ))

        commandCenter.previousTrackCommand.isEnabled = true
        remoteCommandTargets.append((
            commandCenter.previousTrackCommand,
            commandCenter.previousTrackCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                if self.remotePlaybackProjection == nil && self.isQueueEngineActive {
                    DispatchQueue.main.async { self.isQueueTransitioning = true }
                    let currentTime = self.player?.currentTime().seconds ?? 0
                    self.stateQueue.async {
                        self.queueEngine.skipToPrevious(currentTime: currentTime)
                    }
                } else {
                    self.emitRemoteCommand("previous")
                }
                return .success
            }
        ))

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        remoteCommandTargets.append((
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                guard let self = self else { return .commandFailed }
                if self.remotePlaybackProjection == nil && self.isQueueEngineActive {
                    self.isSeeking = true
                    self.player?.seek(to: self.makeTime(event.positionTime)) { [weak self] _ in
                        self?.isSeeking = false
                        self?.emitProgress()
                    }
                } else {
                    self.emitRemoteCommand("seek", position: event.positionTime)
                }
                return .success
            }
        ))

        commandCenter.changeShuffleModeCommand.isEnabled = true
        remoteCommandTargets.append((commandCenter.changeShuffleModeCommand,
            commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
                guard let self, let event = event as? MPChangeShuffleModeCommandEvent,
                      self.remotePlaybackProjection == nil else { return .commandFailed }
                self.setShuffle(NativePlaybackRequest(options: ["enabled": event.shuffleType != .off]))
                return .success
            }))
        commandCenter.changeRepeatModeCommand.isEnabled = true
        remoteCommandTargets.append((commandCenter.changeRepeatModeCommand,
            commandCenter.changeRepeatModeCommand.addTarget { [weak self] event in
                guard let self, let event = event as? MPChangeRepeatModeCommandEvent,
                      self.remotePlaybackProjection == nil else { return .commandFailed }
                let mode = event.repeatType == .all ? "all" : event.repeatType == .one ? "one" : "off"
                self.setRepeatMode(NativePlaybackRequest(options: ["mode": mode]))
                return .success
            }))
        updateSystemPlaybackModes()
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.localizedTitle = "♥"
        remoteCommandTargets.append((
            commandCenter.likeCommand,
            commandCenter.likeCommand.addTarget { [weak self] _ in
                guard let self = self else { return .commandFailed }
                self.emitRemoteCommand("like")
                return .success
            }
        ))
    }

    private func unregisterRemoteCommands() {
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
        }

        remoteCommandTargets = []
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        NativeLogger.shared.info("audio session interruption: \(type == .began ? "began" : "ended")", source: "Audio")

        switch type {
        case .began:
            wasPlayingBeforeInterruption = player?.timeControlStatus == .playing
            recoveryController.stopProgressMonitoring()
            player?.pause()
            if isInForeground {
                notifyListeners("interruptionChanged", data: eventData(["type": "began"]))
                emitBuffering(false)
                emitProgress()
            }
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = options.contains(.shouldResume)

            if isInForeground {
                notifyListeners("interruptionChanged", data: eventData([
                    "type": "ended",
                    "shouldResume": shouldResume,
                ]))
            }

            if shouldResume, wasPlayingBeforeInterruption, let player = player {
                do {
                    try activateAudioSession()
                    player.play()
                    recoveryController.startProgressMonitoring(
                        generation: playbackGeneration,
                        sourceKind: recoverySourceKind()
                    )
                } catch {
                    emitError(code: "audio_session_failed", message: error.localizedDescription)
                    if isInForeground { emitCurrentPlaybackState() }
                }
            } else {
                if isInForeground { emitCurrentPlaybackState() }
            }

            wasPlayingBeforeInterruption = false
        @unknown default:
            emitError(code: "unknown_interruption", message: "Native audio received an unknown interruption.")
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        let reason = routeChangeReason(from: notification)

        guard isInForeground else { return }
        notifyListeners("routeChanged", data: eventData(["reason": reason]))
        emitCurrentPlaybackState()
        emitProgress()
    }

    private func handleDidEnterBackground() {
        isInForeground = false
        recoveryController.setBackground(true)
        scrobbleSubmitter.submitPending(buffer: scrobbleBuffer)
        persistence.flushNow()
    }

    private func handleWillEnterForeground() {
        isInForeground = true
        recoveryController.setBackground(false)
        emitCurrentPlaybackState()
        emitProgress()
        let volume = audioSession.outputVolume
        notifyListeners("systemVolumeChanged", data: ["volume": volume])
    }

    private func handleDidBecomeActive() {
        guard !isInForeground else { return }
        isInForeground = true
        emitCurrentPlaybackState()
        emitProgress()
        let volume = audioSession.outputVolume
        notifyListeners("systemVolumeChanged", data: ["volume": volume])
    }

    private func metadata(from call: NativePlaybackRequest) -> NativeAudioMetadata {
        NativeAudioMetadata(
            title: call.getString("title"),
            artist: call.getString("artist"),
            album: call.getString("album"),
            duration: positiveDuration(call.getDouble("duration")),
            artworkUrl: call.getString("artworkUrl"),
            coverArtId: call.getString("coverArtId")
        )
    }

    private func metadata(from object: [String: Any]?) -> NativeAudioMetadata {
        guard let object else {
            return NativeAudioMetadata()
        }

        return NativeAudioMetadata(
            title: object["title"] as? String,
            artist: object["artist"] as? String,
            album: object["album"] as? String,
            duration: positiveDuration(numberValue(object["duration"])),
            artworkUrl: object["artworkUrl"] as? String,
            coverArtId: object["coverArtId"] as? String
        )
    }

    private func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull {
            return nil
        }
        if let value = value as? String {
            return value.isEmpty ? nil : value
        }
        return "\(value)"
    }

    private func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func epochMilliseconds(_ iso: String?) -> Int? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    private func consumeSnapshotProgressSeconds(fallback: Double) -> Double {
        guard let value = nextSnapshotProgressSeconds else {
            return fallback
        }
        nextSnapshotProgressSeconds = nil
        return value
    }

    private func forceNextSnapshotProgress(_ seconds: Double) {
        nextSnapshotProgressSeconds = max(0, seconds)
    }

    private func positiveDuration(_ duration: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0 else {
            return nil
        }

        return duration
    }

    private func updateNowPlayingInfo() {
        updateSystemPlaybackModes()
        notifyListeners("nativeMetadataChanged", data: [:])
        if coverDownloadArtId != currentNowPlayingCoverArtId() {
            cancelCoverDownload()
        }
        artworkPublishedStages.removeAll()
        dynamicCoverRegistry.begin(coverArtId: currentNowPlayingCoverArtId())
        LockScreenArtworkDemand.shared.setCurrentCover(currentNowPlayingCoverArtId())
        nowPlayingRevision += 1
        artworkGeneration.update(nowPlayingRevision)
        let revision = nowPlayingRevision
        artworkTask?.cancel()
        artworkTask = nil

        NativeLogger.shared.info(
            "publish metadata revision=\(revision) coverArtId=\(currentNowPlayingCoverArtId() ?? "nil") " +
                "artworkScheme=\(currentMetadata.artworkUrl.flatMap { URL(string: $0)?.scheme } ?? "nil")",
            source: "NowPlayingArtwork"
        )

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        apply(currentMetadata.title, forKey: MPMediaItemPropertyTitle, to: &info)
        apply(currentMetadata.artist, forKey: MPMediaItemPropertyArtist, to: &info)
        apply(currentMetadata.album, forKey: MPMediaItemPropertyAlbumTitle, to: &info)
        applyNowPlayingPlaybackFields(to: &info)

        if currentMetadata.artworkUrl == nil || publishedArtworkSource != currentMetadata.artworkUrl {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            removeImmersiveArtwork(from: &info)
            publishedArtworkSource = nil
            publishedArtworkOriginalReady = false
        }
        if !publishedArtworkOriginalReady { removeImmersiveArtwork(from: &info) }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let artworkUrl = currentMetadata.artworkUrl {
            loadNowPlayingArtwork(
                artworkUrl,
                coverArtId: currentMetadata.coverArtId,
                revision: revision
            )
        }
    }

    private func updateNowPlayingPlaybackInfo() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return
        }

        applyNowPlayingPlaybackFields(to: &info)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func handleCoverImageCached(_ notification: Notification) {
        guard let cachedCoverArtId = notification.userInfo?[ImageCacheNotification.coverArtIdKey] as? String else {
            NativeLogger.shared.warn(
                "cache notification missing coverArtId",
                source: "NowPlayingArtwork"
            )
            return
        }

        let currentCoverArtId = currentNowPlayingCoverArtId()
        let hasArtworkUrl = currentMetadata.artworkUrl != nil
        let hasNowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
        NativeLogger.shared.info(
            "cache notification received cached=\(cachedCoverArtId) current=\(currentCoverArtId ?? "nil") " +
                "hasArtworkUrl=\(hasArtworkUrl) hasNowPlayingInfo=\(hasNowPlayingInfo)",
            source: "NowPlayingArtwork"
        )

        guard cachedCoverArtId == currentCoverArtId, hasArtworkUrl, hasNowPlayingInfo else {
            NativeLogger.shared.debug(
                "cache notification ignored cached=\(cachedCoverArtId)",
                source: "NowPlayingArtwork"
            )
            return
        }

        NativeLogger.shared.info(
            "cache notification matched; republishing Now Playing",
            source: "NowPlayingArtwork"
        )
        updateNowPlayingInfo()
    }

    private func currentNowPlayingCoverArtId() -> String? {
        if let coverArtId = currentMetadata.coverArtId, !coverArtId.isEmpty {
            return coverArtId
        }

        guard
            let artworkUrl = currentMetadata.artworkUrl,
            let components = URLComponents(string: artworkUrl),
            (components.scheme == "aonsoku-media" || URL(string: artworkUrl)?.lastPathComponent == "getCoverArt")
        else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == "id" })?.value
    }

    private func apply(_ value: String?, forKey key: String, to info: inout [String: Any]) {
        if let value, !value.isEmpty {
            info[key] = value
        } else {
            info.removeValue(forKey: key)
        }
    }

    private func applyNowPlayingPlaybackFields(to info: inout [String: Any]) {
        if let remotePlaybackProjection {
            MPNowPlayingInfoCenter.default().playbackState =
                remotePlaybackProjection.isPlaying ? .playing : .paused

            if remotePlaybackProjection.duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] =
                    remotePlaybackProjection.duration
            } else {
                info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            }

            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
                remotePlaybackProjection.position
            info[MPNowPlayingInfoPropertyPlaybackRate] =
                remotePlaybackProjection.isPlaying ? 1.0 : 0.0
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            return
        }

        let duration = durationSeconds()
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds(
            from: player?.currentTime() ?? .zero
        )
        let isActivelyPlaying = player?.timeControlStatus == .playing ||
            player?.timeControlStatus == .waitingToPlayAtSpecifiedRate ||
            isQueueTransitioning
        MPNowPlayingInfoCenter.default().playbackState =
            isActivelyPlaying ? .playing : .paused
        info[MPNowPlayingInfoPropertyPlaybackRate] = isActivelyPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
    }

    private func loadNowPlayingArtwork(
        _ urlString: String,
        coverArtId explicitCoverArtId: String?,
        revision: Int
    ) {
        let needsOriginal = (LockScreenArtworkController.supported && LockScreenArtworkSettings.shared.value.immersiveEnabled) || LockScreenArtworkDemand.shared.requested
        var coverArtId = explicitCoverArtId
        if let components = URLComponents(string: urlString),
           (components.scheme == "aonsoku-media" || URL(string: urlString)?.lastPathComponent == "getCoverArt"),
           let queryItems = components.queryItems {
            coverArtId = coverArtId ?? queryItems.first(where: { $0.name == "id" })?.value
        }

        NativeLogger.shared.info(
            "artwork load started revision=\(revision) coverArtId=\(coverArtId ?? "nil") " +
                "scheme=\(URL(string: urlString)?.scheme ?? "nil")",
            source: "NowPlayingArtwork"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let coverArtId, !coverArtId.isEmpty {
                let imageCache = ImageCacheManager(db: DatabaseManager.shared.dbPool)
                if let cached = imageCache.readCoverImage(coverArtId: coverArtId),
                   CoverImageQuality.dimensions(cached.data) != nil,
                   let image = LockScreenArtworkRenderer.decode(cached.data) {
                    let ready = CoverImageQuality.isOriginal(cached.quality)
                    NativeLogger.shared.info(
                        "cache hit revision=\(revision) quality=\(cached.quality ?? "unknown") pixels=\(image.width)x\(image.height) immersiveReady=\(ready)",
                        source: "NowPlayingArtwork")
                    self.publishNowPlayingArtwork(image, data: cached.data, source: urlString,
                        revision: revision, originalReady: ready)
                    if ready || !needsOriginal { return }
                }
                // Small/unknown caches remain ordinary Now Playing previews only.
                // One unrestricted request survives same-cover metadata/cache updates.
                self.downloadNowPlayingCover(coverArtId: coverArtId, revision: revision, original: needsOriginal)
                return
            }

            guard let url = URL(string: urlString) else {
                NativeLogger.shared.warn(
                    "invalid artwork URL revision=\(revision)",
                    source: "NowPlayingArtwork"
                )
                return
            }

            let originalURL = CoverImageQuality.unrestrictedURL(url)
            let task = URLSession.shared.dataTask(with: originalURL) { [weak self] data, response, error in
                guard let self else { return }
                if let error {
                    NativeLogger.shared.warn(
                        "network artwork failed revision=\(revision) scheme=\(url.scheme ?? "nil"): \(error.localizedDescription)",
                        source: "NowPlayingArtwork"
                    )
                    return
                }
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode), let data else {
                    NativeLogger.shared.warn(
                        "network artwork returned no data revision=\(revision)",
                        source: "NowPlayingArtwork"
                    )
                    return
                }
                guard CoverImageQuality.dimensions(data) != nil,
                      let image = LockScreenArtworkRenderer.decode(data) else {
                    NativeLogger.shared.warn(
                        "network artwork decode failed revision=\(revision) bytes=\(data.count)",
                        source: "NowPlayingArtwork"
                    )
                    return
                }
                let statusCode = response.statusCode
                NativeLogger.shared.info(
                    "network artwork loaded revision=\(revision) status=\(statusCode) bytes=\(data.count)",
                    source: "NowPlayingArtwork"
                )
                self.publishNowPlayingArtwork(
                    image, data: data, source: urlString, revision: revision, originalReady: true
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.nowPlayingRevision == revision else {
                    task.cancel()
                    return
                }
                self.artworkTask = task
                task.resume()
            }
        }
    }

    private func cancelCoverDownload() {
        coverDownloadTask?.cancel()
        coverDownloadTask = nil
        coverDownloadArtId = nil
        coverDownloadSize = nil
        coverDownloadRequestID = nil
    }

    private func downloadNowPlayingCover(coverArtId: String, revision: Int, original: Bool) {
        let size = original ? CoverImageQuality.original : "800"
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nowPlayingRevision == revision else { return }
            guard self.coverDownloadArtId != coverArtId || self.coverDownloadSize != size || self.coverDownloadTask == nil else { return }
            self.cancelCoverDownload()
            let requestID = UUID()
            self.coverDownloadRequestID = requestID
            self.coverDownloadArtId = coverArtId
            self.coverDownloadSize = size
            if original {
                for format in ["1:1", "3:4"] {
                    LockScreenArtworkDiagnostics.shared.update(format,
                        ["sourceQuality": "waitingForOriginal", "publishedBackend": "ordinary-preview",
                         "sourcePixels": "not ready", "sourceRequest": "getCoverArt without size"])
                }
            }
            NativeLogger.shared.info("cover request started revision=\(revision) quality=\(size)", source: "NowPlayingArtwork")
            self.coverDownloadTask = Task { [weak self] in
                do {
                    _ = try await ImageCacheManager(db: DatabaseManager.shared.dbPool)
                        .downloadCoverImage(coverArtId: coverArtId, size: size)
                    NativeLogger.shared.info("cover cached quality=\(size); awaiting current-cover refresh", source: "NowPlayingArtwork")
                } catch {
                    NativeLogger.shared.warn("cover request failed quality=\(size): \(error.localizedDescription)", source: "NowPlayingArtwork")
                    if original && !Task.isCancelled {
                        for format in ["1:1", "3:4"] {
                            LockScreenArtworkDiagnostics.shared.update(format,
                                ["sourceQuality": "originalUnavailable", "sourceRequest": "retry on foreground/cache/metadata update"])
                        }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.coverDownloadRequestID == requestID else { return }
                    self.coverDownloadTask = nil
                    self.coverDownloadArtId = nil
                    self.coverDownloadSize = nil
                    self.coverDownloadRequestID = nil
                }
            }
        }
    }

    private func removeImmersiveArtwork(from info: inout [String: Any]) {
        // Older SDKs still build a fully functional static-artwork player.
        #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                info.removeValue(forKey: MPNowPlayingInfoProperty3x4AnimatedArtwork)
                info.removeValue(forKey: MPNowPlayingInfoProperty1x1AnimatedArtwork)
            }
        #endif
    }

    private func logNowPlayingArtworkDiagnostics(_ phase: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            var supported: [String] = []
            var tallInstalled = false
            var squareInstalled = false
            var compiled = false
            #if compiler(>=6.2)
                compiled = true
                if #available(iOS 26.0, *) {
                    supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
                    tallInstalled = info[MPNowPlayingInfoProperty3x4AnimatedArtwork] != nil
                    squareInstalled = info[MPNowPlayingInfoProperty1x1AnimatedArtwork] != nil
                }
            #endif
            let orientations = UIApplication.shared.connectedScenes.compactMap {
                ($0 as? UIWindowScene)?.interfaceOrientation.rawValue
            }
            NativeLogger.shared.info(
                "diagnostics phase=\(phase) os=\(UIDevice.current.systemVersion) "
                    + "idiom=\(UIDevice.current.userInterfaceIdiom.rawValue) sdk=\(Bundle.main.object(forInfoDictionaryKey: "DTSDKName") ?? "unknown") "
                    + "compiledAnimated=\(compiled) supportedKeys=\(supported) orientations=\(orientations) "
                    + "appState=\(UIApplication.shared.applicationState.rawValue) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) "
                    + "thermal=\(ProcessInfo.processInfo.thermalState.rawValue) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) "
                    + "revision=\(self.nowPlayingRevision) staticInstalled=\(info[MPMediaItemPropertyArtwork] != nil) tallInstalled=\(tallInstalled) squareInstalled=\(squareInstalled)",
                source: "NowPlayingArtwork"
            )
        }
    }

    private func publishNowPlayingArtwork(
        _ image: CGImage, data: Data, source: String, revision: Int, originalReady: Bool
    ) {
        let sourceDimensions = CoverImageQuality.dimensions(data)
        let staticImage = UIImage(cgImage: image)
        let artwork = MPMediaItemArtwork(boundsSize: staticImage.size) { _ in staticImage }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nowPlayingRevision == revision,
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            if !originalReady { self.removeImmersiveArtwork(from: &info) }
            self.publishedArtworkSource = source
            self.publishedArtworkOriginalReady = originalReady
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            self.logNowPlayingArtworkDiagnostics("ordinary-published")
            for format in ["1:1", "3:4"] {
                LockScreenArtworkDiagnostics.shared.update(format,
                    ["sourceQuality": originalReady ? "originalReady" : "waitingForOriginal",
                     "sourcePixels": "\(sourceDimensions?.width ?? image.width)×\(sourceDimensions?.height ?? image.height)",
                     "decodedPixels": "\(image.width)×\(image.height) (max 1200px)"])
            }
            guard originalReady else { return }

            let options = LockScreenArtworkSettings.shared.value
            guard options.immersiveEnabled || LockScreenArtworkDemand.shared.requested else { return }
            var variants: [(LockScreenArtworkFormat, String)] = []
            #if compiler(>=6.2)
                if #available(iOS 26.0, *) {
                    let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
                    if keys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
                        variants.append((.tall, MPNowPlayingInfoProperty3x4AnimatedArtwork))
                    }
                    if keys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
                        variants.append((.square, MPNowPlayingInfoProperty1x1AnimatedArtwork))
                    }
                }
            #endif
            if variants.isEmpty && LockScreenArtworkDemand.shared.requested { variants = [(.square, "")] }
            if !options.immersiveEnabled, let preferred = variants.first { variants = [preferred] }
            let observations = variants.map { format, key in
                (format, key, LockScreenArtworkRequests.shared.target(portrait: !format.isSquare))
            }
            let budget = LockScreenArtworkRequests.budgetBytes
            let locked = options.immersiveEnabled
            self.artworkPreparationQueue.async { [weak self] in
                guard let self, let sourceSize = LockScreenArtworkResolution.sourceSize(data) else { return }
                let current = { [artworkGeneration = self.artworkGeneration] in artworkGeneration.contains(revision) }
                LockScreenArtworkStore.shared.restoreCached(data: data, shouldContinue: current) { assets in
                    DispatchQueue.main.async {
                        guard self.nowPlayingRevision == revision else { return }
                        for asset in assets {
                            let key = observations.first { $0.0.label == asset.format.label }?.1 ?? ""
                            self.deliverImmersiveArtwork(asset, key: key, revision: revision)
                        }
                    }
                    // Cache restoration/publication is independent of generation policy.
                    guard LockScreenArtworkMotionPolicy.shared.allowsStaticGeneration else { return }
                    // A fullscreen consumer accepts existing files of any size/aspect.
                    // Only the lock-screen producer may request an upgraded format.
                    if !locked && assets.contains(where: { !$0.motion }) && (assets.contains(where: { $0.motion && $0.backend != "camera" }) || !LockScreenArtworkDemand.shared.dynamicRequested) { return }
                    let existing = !locked ? assets.max(by: { ($0.motion ? 1 : 0) < ($1.motion ? 1 : 0) }) : nil
                    let jobs = existing.map { asset in [(asset.format, observations.first { $0.0.label == asset.format.label }?.1 ?? "", (size: CGSize(width: asset.format.width, height: asset.format.height), origin: "reused-existing-video"))] } ?? observations
                    for (format, key, target) in jobs {
                        guard current() else { continue }
                        guard let plan = LockScreenArtworkResolution.plan(source: sourceSize,
                            target: target.size, portrait: !format.isSquare, budgetBytes: budget) else {
                            LockScreenArtworkDiagnostics.shared.update(format.label,
                                ["resolutionReason": "resource-or-hardware-unavailable", "outputPixels": "unavailable", "targetOrigin": target.origin])
                            continue
                        }
                        guard let decoded = LockScreenArtworkRenderer.decode(data, maxPixelSize: plan.decodeLimit) else {
                            LockScreenArtworkDiagnostics.shared.update(format.label, ["resolutionReason": "source-decode-failed"])
                            continue
                        }
                        LockScreenArtworkDiagnostics.shared.update(format.label,
                            ["targetOrigin": target.origin, "targetPixels": "\(target.size.width)×\(target.size.height)",
                             "outputPixels": "\(plan.format.width)×\(plan.format.height)", "resolutionReason": plan.reason,
                             "decodedPixels": "\(decoded.width)×\(decoded.height)", "algorithm": "minimal-extension-v2"])
                        self.prepareImmersiveArtwork(decoded, data: data, format: plan.format, key: key, revision: revision, existing: assets, allowLegacyReuse: !locked, consumerMotion: !locked || format.label == observations.first?.0.label)
                    }
                }
            }
        }
    }

    private func deliverImmersiveArtwork(_ asset: LockScreenArtworkAsset, key: String, revision: Int) {
        guard nowPlayingRevision == revision else { return }
        let stage = asset.motion ? (asset.backend == "camera" ? 1 : 2) : 0
        dynamicCoverRegistry.publish(asset, format: asset.format.consumerFormat, rank: stage)
        let options = LockScreenArtworkSettings.shared.value
        guard options.immersiveEnabled, !asset.motion || (options.dynamicEnabled && LockScreenArtworkMotionPolicy.shared.allowsPlayback), !key.isEmpty else { return }
        let stageKey = "\(revision)-\(asset.format.label)"
        guard stage >= (artworkPublishedStages[stageKey] ?? -1) else { return }
        artworkPublishedStages[stageKey] = stage
        #if compiler(>=6.2)
            if #available(iOS 26.0, *), var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    let preview = UIImage(cgImage: asset.preview)
                    let animated = MPMediaItemAnimatedArtwork(
                        artworkID: asset.id,
                        previewImageRequestHandler: { size, completion in
                            NativeLogger.shared.info(
                                "\(asset.format.label) preview requested revision=\(revision) size=\(size) returning=\(preview.size)",
                                source: "NowPlayingArtwork")
                            completion(preview)
                            DispatchQueue.main.async {
                                LockScreenArtworkRequests.shared.record(format: asset.format, size: size, kind: "preview")
                            }
                        },
                        videoAssetFileURLRequestHandler: { size, completion in
                            let started = Date()
                            DispatchQueue.main.async {
                                LockScreenArtworkRequests.shared.record(format: asset.format, size: size, kind: "video")
                            }
                            NativeLogger.shared.info(
                                "\(asset.format.label) video requested revision=\(revision) size=\(size)",
                                source: "NowPlayingArtwork")
                            asset.requestVideo { url in
                                if url == nil {
                                    NativeLogger.shared.warn(
                                        "\(asset.format.label) video unavailable; using system fallback",
                                        source: "NowPlayingArtwork")
                                }
                                let bytes =
                                    url.flatMap {
                                        try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
                                    } ?? 0
                                NativeLogger.shared.info(
                                    "\(asset.format.label) video returned revision=\(revision) local=\(url?.isFileURL ?? false) bytes=\(bytes) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))",
                                    source: "NowPlayingArtwork")
                                LockScreenArtworkDiagnostics.shared.update(asset.format.label,
                                    ["systemVideo": url == nil ? "unavailable" : "delivered",
                                     "systemBackend": asset.backend, "bytes": "\(bytes)",
                                     "requestMs": "\(Int(Date().timeIntervalSince(started) * 1000)) ms"])
                                completion(url)
                            }
                        }
                    )
                    info[key] = animated
                    LockScreenArtworkDiagnostics.shared.update(asset.format.label,
                        ["publishedRevision": "\(revision)", "publishedBackend": asset.backend,
                         "publishedMode": asset.motion ? "motion" : "static",
                         "publishedReason": asset.analysisReason ?? "disk-cache",
                         "motionAmplitude": "\(asset.parameters.amplitude)×",
                         "motionSpeed": "\(asset.parameters.speed)×",
                         "loopDuration": "\(asset.motion ? asset.parameters.duration : 2) s",
                         "asset": String(asset.id.prefix(45))])
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    NativeLogger.shared.info(
                        "\(asset.format.label) artwork published revision=\(revision)",
                        source: "NowPlayingArtwork")
                    NativeLogger.shared.info("backend=\(asset.backend) motion=\(asset.motion) analysis=\(asset.analysisReason ?? "cached")", source: "NowPlayingArtwork")
                    self.logNowPlayingArtworkDiagnostics("\(asset.format.label)-published")
            }
        #endif
    }

    private func prepareImmersiveArtwork(
        _ image: CGImage, data: Data, format: LockScreenArtworkFormat, key: String, revision: Int, existing: [LockScreenArtworkAsset], allowLegacyReuse: Bool, consumerMotion: Bool
    ) {
        let prepared: (LockScreenArtworkAsset?) -> Void = { [weak self] asset in
            guard let asset else { return }
            DispatchQueue.main.async { self?.deliverImmersiveArtwork(asset, key: key, revision: revision) }
        }
            let reusableDepth = allowLegacyReuse ? existing.first(where: { $0.motion && $0.backend != "camera" && $0.format.label == format.label }) : nil
            let options = LockScreenArtworkSettings.shared.value
            let policy = LockScreenArtworkMotionPolicy.shared
            let target = policy.effectiveTier ?? LockScreenArtworkTier.automatic(memory: ProcessInfo.processInfo.physicalMemory)
            var tier = target
            if ((options.immersiveEnabled && options.dynamicEnabled) || (consumerMotion && LockScreenArtworkDemand.shared.dynamicRequested)) && !LockScreenArtworkStore.shared.hasReadyVideo(data: data, format: format, backend: target.backend),
                let available = LockScreenArtworkModelManager.shared.availableTier(upTo: target) {
                tier = available
            }
            let motion = ((options.immersiveEnabled && options.dynamicEnabled) || (consumerMotion && LockScreenArtworkDemand.shared.dynamicRequested)) && policy.allowsPlayback
            let backend = tier.backend
            LockScreenArtworkDiagnostics.shared.update(format.label,
                ["targetTier": target.rawValue, "selectedTier": tier.rawValue,
                 "policy": policy.generationReason])
            if motion && reusableDepth == nil && policy.allowsGeneration
                && LockScreenArtworkModelManager.shared.modelURL(target) == nil
                && !LockScreenArtworkStore.shared.hasReadyVideo(data: data, format: format, backend: target.backend) {
                LockScreenArtworkModelManager.shared.request(target, automatic: true)
            }
            let current = { [artworkGeneration] in artworkGeneration.contains(revision) }
            let motionCurrent = { current() && ((LockScreenArtworkSettings.shared.value.immersiveEnabled && LockScreenArtworkSettings.shared.value.dynamicEnabled) || (consumerMotion && LockScreenArtworkDemand.shared.dynamicRequested)) }
            let store = LockScreenArtworkStore.shared
            let afterStatic: (LockScreenArtworkAsset?) -> Void = { staticAsset in
                prepared(staticAsset)
                if let reusableDepth {
                    reusableDepth.retainedStaticAsset = staticAsset
                    prepared(reusableDepth); return
                }
                guard motion, motionCurrent() else { return }
                let prepareDepth = {
                    store.prepare(data: data, source: image, format: format,
                        motion: true, backend: backend, shouldContinue: motionCurrent) { depthAsset in
                        guard let depthAsset, depthAsset.motion, depthAsset.backend != "camera" else { return }
                        depthAsset.retainedStaticAsset = staticAsset
                        prepared(depthAsset)
                        store.retireCameraVideo(for: depthAsset)
                    }
                }
                if store.hasReadyVideo(data: data, format: format, backend: backend) {
                    prepareDepth()
                    return
                }
                let afterCamera: (LockScreenArtworkAsset?) -> Void = { cameraAsset in
                    cameraAsset?.retainedStaticAsset = staticAsset
                    prepared(cameraAsset)
                    guard motionCurrent() else { return }
                    prepareDepth()
                }
                if let cachedCamera = existing.first(where: { $0.motion && $0.backend == "camera" && $0.format == format }) { afterCamera(cachedCamera) }
                else { store.prepare(data: data, source: image, format: format, motion: true, backend: "camera", shouldContinue: motionCurrent, completion: afterCamera) }
            }
            if let cachedStatic = existing.first(where: { !$0.motion && $0.format == format }) { afterStatic(cachedStatic) }
            else { store.prepare(data: data, source: image, format: format, shouldContinue: current, completion: afterStatic) }
    }

    private func clearNowPlayingInfo() {
        cancelCoverDownload()
        artworkPublishedStages.removeAll()
        dynamicCoverRegistry.begin(coverArtId: nil)
        LockScreenArtworkDemand.shared.setCurrentCover(nil)
        nowPlayingRevision += 1
        artworkGeneration.update(nowPlayingRevision)
        artworkTask?.cancel()
        artworkTask = nil
        publishedArtworkSource = nil
        publishedArtworkOriginalReady = false
        remotePlaybackProjection = nil
        currentMetadata = NativeAudioMetadata()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func resolveSource(from source: [String: Any]) throws -> ResolvedAudioSource {
        guard let kind = source["kind"] as? String else {
            throw NativeAudioPluginError.invalidSource("Missing source kind.")
        }

        switch kind {
        case "stream":
            let url = try resolveStreamURL(from: source)
            let songId = source["songId"] as? String
            return ResolvedAudioSource(kind: kind, url: url, radioId: nil, songId: songId)
        case "radio":
            guard let urlString = source["url"] as? String, let url = URL(string: urlString) else {
                throw NativeAudioPluginError.invalidSource("Invalid radio stream URL.")
            }
            return ResolvedAudioSource(kind: kind, url: url, radioId: source["radioId"] as? String, songId: nil)
        case "blob":
            throw NativeAudioPluginError.unsupportedSource("Blob URLs are not supported by native iOS playback yet.")
        case "native-file":
            guard let uri = source["uri"] as? String, !uri.isEmpty else {
                throw NativeAudioPluginError.invalidSource("Invalid native cached audio URI.")
            }
            let url = try fileURL(from: uri)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NativeAudioPluginError.invalidSource("Native cached audio file does not exist.")
            }
            return ResolvedAudioSource(kind: kind, url: url, radioId: nil, songId: source["songId"] as? String)
        default:
            throw NativeAudioPluginError.unsupportedSource("Unsupported audio source kind: \(kind).")
        }
    }

    private func resolveStreamURL(from source: [String: Any]) throws -> URL {
        guard let urlString = source["url"] as? String, !urlString.isEmpty else {
            throw NativeAudioPluginError.invalidSource("Invalid audio URL.")
        }

        let isNativeMediaURL =
            URLComponents(string: urlString)?.scheme == "aonsoku-media"
        if isNativeMediaURL {
            guard let request = mediaStreamRequest(
                from: urlString,
                fallbackSongId: source["songId"] as? String
            ) else {
                throw NativeAudioPluginError.invalidSource("Invalid native media stream URL.")
            }

            guard let url = buildAuthenticatedStreamURL(from: request) else {
                throw NativeAudioPluginError.invalidSource("Unable to resolve native media stream URL.")
            }

            return url
        }

        guard let url = URL(string: urlString) else {
            throw NativeAudioPluginError.invalidSource("Invalid audio URL.")
        }

        return url
    }

    private func mediaStreamRequest(
        from urlString: String,
        fallbackSongId: String?
    ) -> NativeMediaStreamRequest? {
        guard
            let components = URLComponents(string: urlString),
            components.scheme == "aonsoku-media"
        else {
            return nil
        }

        let endpoint =
            components.host ??
            components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard endpoint == "stream" else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let songId = queryItems.first { $0.name == "id" }?.value ?? fallbackSongId
        guard let songId, !songId.isEmpty else {
            return nil
        }

        return NativeMediaStreamRequest(
            songId: songId,
            maxBitRate: queryItems.first { $0.name == "maxBitRate" }?.value,
            format: queryItems.first { $0.name == "format" }?.value
        )
    }

    private func buildAuthenticatedStreamURL(
        from request: NativeMediaStreamRequest
    ) -> URL? {
        guard let credentials = KeychainManager.retrieve() else {
            return nil
        }

        var params = SubsonicAuthBuilder.buildQueryParams(
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: credentials.protocolVersion
        )
        params["id"] = request.songId
        // Must be "true" for native AVPlayer: without Content-Length, AVPlayer cannot
        // issue HTTP Range requests, causing buffer stalls and seek failures.
        // (Web uses "false" to work around browser-specific streaming quirks.)
        params["estimateContentLength"] = "true"

        if let maxBitRate = request.maxBitRate, !maxBitRate.isEmpty {
            params["maxBitRate"] = maxBitRate
        }
        if let format = request.format, !format.isEmpty {
            params["format"] = format
        }

        let baseString = "\(credentials.serverUrl)/rest/stream"
        guard var components = URLComponents(string: baseString) else {
            return nil
        }

        components.queryItems = params.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.url
    }

    private func fileURL(from uri: String) throws -> URL {
        if let url = URL(string: uri), url.scheme != nil {
            guard url.isFileURL else {
                throw NativeAudioPluginError.invalidSource("Native cached audio URI must be a file URL.")
            }
            return url
        }

        return URL(fileURLWithPath: uri)
    }

    private func addObservers(
        for item: AVPlayerItem,
        player: AVPlayer,
        generation: Int,
        requestId: String?
    ) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.handleStatusChanged(
                    observedItem,
                    generation: generation,
                    requestId: requestId
                )
            }
        }

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.emitDuration(
                    for: observedItem,
                    generation: generation,
                    requestId: requestId
                )
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
                self?.handleTimeControlStatusChanged(
                    observedPlayer.timeControlStatus,
                    player: observedPlayer,
                    generation: generation,
                    requestId: requestId
                )
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleEnded(generation: generation, requestId: requestId)
        }

        failedEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isCurrentPlayback(item: item, generation: generation) else {
                return
            }
            let currentTime = self.player?.currentTime() ?? .zero
            self.recoveryController.triggerRecovery(
                currentTime: currentTime,
                generation: generation,
                sourceKind: self.recoverySourceKind()
            )
        }

        loadDurationAsync(for: item, generation: generation, requestId: requestId)

        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleStall(player: player, generation: generation)
        }

        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                guard let self, self.isCurrentPlayback(item: observedItem, generation: generation) else { return }
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    self.handleStall(player: player, generation: generation)
                } else if player.timeControlStatus == .playing {
                    self.handleGhostPlayback(player: player, item: observedItem, generation: generation)
                }
            }
        }

        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                self?.recoveryController.reportLikelyToKeepUp(generation: generation)
            }
        }
    }

    private func addProgressObserver(
        to player: AVPlayer,
        generation: Int,
        requestId: String?
    ) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: progressQueue) { [weak self] _ in
            guard let self = self else { return }
            guard self.isCurrentPlayback(player: player, generation: generation) else {
                return
            }
            guard !self.isSeeking else { return }
            let bufferEmpty = self.playerItem?.isPlaybackBufferEmpty ?? false
            let currentTime = player.currentTime()
            let currentSeconds = CMTimeGetSeconds(currentTime)
            if currentSeconds.isFinite {
                self.persistence.updateProgress(currentSeconds)
            }
            DispatchQueue.main.async {
                if !bufferEmpty {
                    self.recoveryController.reportProgress(at: currentTime, generation: generation)
                }
                if !bufferEmpty, let item = self.playerItem {
                    self.checkBufferPositionCoherence(player: player, item: item, generation: generation)
                }
                // Detect end-of-stream when download completed but AVPlayer stalled
                if bufferEmpty,
                   player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                   self.isQueueEngineActive,
                   let song = self.queueEngine.currentSong,
                   self.backgroundCacheCompletedSongIds.contains(song.id) {
                    self.backgroundCacheCompletedSongIds.remove(song.id)
                    self.stalledSinceDate = nil
                    NativeLogger.shared.info("end-of-stream detected via progress check for \(song.id)", source: "Audio")
                    self.handleEnded(generation: generation, requestId: requestId)
                    return
                }
                // Fallback: detect end-of-stream even without download completion
                self.checkEndOfStreamFallback(player: player, generation: generation, requestId: requestId)
            }
            guard self.isInForeground, !self.isQueueTransitioning else { return }
            self.emitProgress(requestId: requestId)
        }
    }

    private func handleStatusChanged(
        _ item: AVPlayerItem,
        generation: Int,
        requestId: String?
    ) {
        guard isCurrentPlayback(item: item, generation: generation) else {
            return
        }

        switch item.status {
        case .readyToPlay:
            emitDuration(for: item, generation: generation, requestId: requestId)
            emitBuffering(false, requestId: requestId)
            handlePendingSeekAndPlay(generation: generation)
        case .failed:
            let currentTime = player?.currentTime() ?? .zero
            recoveryController.triggerRecovery(
                currentTime: currentTime,
                generation: generation,
                sourceKind: recoverySourceKind()
            )
        case .unknown:
            emitPlaybackState("loading", requestId: requestId)
        @unknown default:
            emitError(
                code: "unknown_status",
                message: "Native audio entered an unknown state.",
                requestId: requestId
            )
        }
    }

    private func handleTimeControlStatusChanged(
        _ status: AVPlayer.TimeControlStatus,
        player: AVPlayer,
        generation: Int,
        requestId: String?
    ) {
        guard isCurrentPlayback(player: player, generation: generation) else {
            return
        }

        switch status {
        case .playing:
            isQueueTransitioning = false
            recoveryController.reportPlaybackResumed(generation: generation)
            emitBuffering(false, requestId: requestId)
            emitPlaybackState("playing", requestId: requestId)
            if isQueueEngineActive {
                stateQueue.async { self.scrobbleBuffer.resumeTracking() }
            }
        case .paused:
            if isQueueTransitioning { return }
            if isQueueEngineActive, let item = playerItem {
                let duration = item.duration
                let current = player.currentTime()
                if duration.isNumeric && current.isNumeric {
                    let remaining = CMTimeGetSeconds(duration) - CMTimeGetSeconds(current)
                    if remaining < 0.5 {
                        return
                    }
                }
            }
            emitBuffering(false, requestId: requestId)
            emitPlaybackState("paused", requestId: requestId)
            if isQueueEngineActive {
                stateQueue.async { self.scrobbleBuffer.pauseTracking() }
            }
        case .waitingToPlayAtSpecifiedRate:
            emitBuffering(true, requestId: requestId)
        @unknown default:
            emitBuffering(false, requestId: requestId)
        }
    }

    private func handleStall(player: AVPlayer, generation: Int) {
        guard isCurrentPlayback(player: player, generation: generation) else { return }
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }

        // If the background cache download already completed for this song,
        // this stall is likely end-of-stream, not a network issue.
        if isQueueEngineActive,
           let song = queueEngine.currentSong,
           backgroundCacheCompletedSongIds.contains(song.id) {
            return
        }

        // If currentTime is at the end of loaded ranges and buffer is empty,
        // this is likely end-of-stream (AVPlayer consumed all available data).
        // Let the stall timeout handle it instead of aggressive recovery.
        if let item = playerItem, item.isPlaybackBufferEmpty {
            let currentSeconds = player.currentTime().seconds
            if currentSeconds > 5.0, isAtEndOfLoadedRanges(item: item, position: currentSeconds) {
                return
            }
        }

        let currentTime = player.currentTime()
        recoveryController.triggerRecovery(
            currentTime: currentTime,
            generation: generation,
            sourceKind: recoverySourceKind()
        )
    }

    private func isAtEndOfLoadedRanges(item: AVPlayerItem, position: Double) -> Bool {
        guard let lastRange = item.loadedTimeRanges.last?.timeRangeValue else {
            return true
        }
        let rangeEnd = CMTimeGetSeconds(lastRange.start) + CMTimeGetSeconds(lastRange.duration)
        return position >= rangeEnd - 1.0
    }

    private func handleGhostPlayback(player: AVPlayer, item: AVPlayerItem, generation: Int) {
        guard isCurrentPlayback(player: player, generation: generation) else { return }
        guard !isPlayerAtEnd else { return }
        guard currentSourceKind != "radio" else { return }
        guard item.isPlaybackBufferEmpty else { return }

        let currentSeconds = player.currentTime().seconds
        if currentSeconds > 5.0, isAtEndOfLoadedRanges(item: item, position: currentSeconds) {
            return
        }

        let isPositionBuffered = item.loadedTimeRanges.contains { range in
            let timeRange = range.timeRangeValue
            let start = CMTimeGetSeconds(timeRange.start)
            let end = start + CMTimeGetSeconds(timeRange.duration)
            return currentSeconds >= start && currentSeconds < end
        }
        guard !isPositionBuffered else { return }

        NativeLogger.shared.warn(
            "ghost playback detected: buffer empty at \(String(format: "%.1f", currentSeconds))s but status is .playing",
            source: "Audio"
        )

        player.pause()
        let currentTime = player.currentTime()
        recoveryController.triggerRecovery(
            currentTime: currentTime,
            generation: generation,
            sourceKind: recoverySourceKind()
        )
    }

    private func checkBufferPositionCoherence(player: AVPlayer, item: AVPlayerItem, generation: Int) {
        guard !isSeeking, !isRecoveryReload, !isQueueTransitioning else {
            bufferMismatchFirstSeen = nil
            return
        }
        guard currentSourceKind != "radio" else { return }
        guard !isPlayerAtEnd else {
            bufferMismatchFirstSeen = nil
            return
        }
        guard player.timeControlStatus == .playing else {
            bufferMismatchFirstSeen = nil
            return
        }
        guard !item.isPlaybackBufferEmpty else {
            bufferMismatchFirstSeen = nil
            return
        }

        let currentSeconds = player.currentTime().seconds
        guard currentSeconds.isFinite, currentSeconds > 5.0 else {
            bufferMismatchFirstSeen = nil
            return
        }

        if isPositionWithinLoadedRanges(currentSeconds) {
            bufferMismatchFirstSeen = nil
            return
        }

        if let firstSeen = bufferMismatchFirstSeen {
            if Date().timeIntervalSince(firstSeen) >= 1.5 {
                bufferMismatchFirstSeen = nil
                handleBufferPositionMismatch(player: player, generation: generation)
            }
        } else {
            bufferMismatchFirstSeen = Date()
        }
    }

    private func handleBufferPositionMismatch(player: AVPlayer, generation: Int) {
        guard isCurrentPlayback(player: player, generation: generation) else { return }

        let currentSeconds = player.currentTime().seconds
        let trackDuration = durationSeconds()
        let isNearEnd = currentSeconds > 0 && trackDuration > 0 && (trackDuration - currentSeconds) < 10.0

        if isNearEnd && isQueueEngineActive {
            NativeLogger.shared.info(
                "buffer-position mismatch near end (\(String(format: "%.1f", currentSeconds))s / \(String(format: "%.1f", trackDuration))s) — treating as end-of-stream",
                source: "Audio"
            )
            handleEnded(generation: generation, requestId: currentRequestId)
            return
        }

        NativeLogger.shared.warn(
            "buffer-position mismatch: currentTime=\(String(format: "%.1f", currentSeconds))s not within loaded ranges, seeking to 0",
            source: "Audio"
        )

        isSeeking = true
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.isCurrentPlayback(generation: generation) else { return }
            self.isSeeking = false
            player.play()
            self.emitProgress(requestId: self.currentRequestId)
            self.updateNowPlayingPlaybackInfo()
        }
    }

    private func cancelStallRecovery() {
        recoveryController.reset()
    }

    private func recoverySourceKind() -> RecoverySourceKind {
        switch currentSourceKind {
        case "radio": return .radio
        case "native-file": return .nativeFile
        default: return .stream
        }
    }

    private func removeItemObservers() {
        statusObservation = nil
        durationObservation = nil
        bufferEmptyObservation = nil
        likelyToKeepUpObservation = nil

        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }

        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = failedEndObserver {
            NotificationCenter.default.removeObserver(observer)
            failedEndObserver = nil
        }
        if let observer = stalledObserver {
            NotificationCenter.default.removeObserver(observer)
            stalledObserver = nil
        }
    }

    private func handleEnded(generation: Int, requestId: String?) {
        guard isCurrentPlayback(generation: generation) else {
            return
        }

        if sleepTimerMode == "endOfTrack" {
            sleepTimerMode = "duration"
            player?.pause()
            emitPlaybackState("paused", requestId: requestId)
            updateNowPlayingPlaybackInfo()
            notifyListeners("sleepTimerFired", data: ["reason": "endOfTrack"])
            return
        }

        if isQueueEngineActive {
            isQueueTransitioning = true
            stateQueue.async {
                self.queueEngine.handleEnded()
            }
            return
        }

        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.emitProgress(requestId: requestId)
            self.updateNowPlayingPlaybackInfo()
        }
        emitPlaybackState("ended", requestId: requestId)
        notifyListeners("ended", data: eventData([
            "reason": "finished",
        ], requestId: requestId))
    }

    private func checkEndOfStreamAfterCacheComplete(songId: String) {
        guard isQueueEngineActive else { return }
        guard let currentSong = queueEngine.currentSong, currentSong.id == songId else { return }
        guard let player, let item = playerItem else { return }

        let isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let bufferEmpty = item.isPlaybackBufferEmpty
        if isWaiting && bufferEmpty {
            NativeLogger.shared.info("end-of-stream detected via cache completion for \(songId)", source: "Audio")
            handleEnded(generation: playbackGeneration, requestId: currentRequestId)
        }
    }

    private func checkEndOfStreamFallback(player: AVPlayer, generation: Int, requestId: String?) {
        guard isQueueEngineActive else { return }
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            stalledSinceDate = nil
            return
        }
        guard let item = playerItem, item.isPlaybackBufferEmpty else {
            stalledSinceDate = nil
            return
        }

        let now = Date()
        if stalledSinceDate == nil {
            stalledSinceDate = now
            return
        }

        guard let stalledSince = stalledSinceDate,
              now.timeIntervalSince(stalledSince) >= 3.0 else {
            return
        }

        // Stalled with empty buffer for 3+ seconds — stream likely ended
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        guard currentSeconds > 5.0 else { return }

        stalledSinceDate = nil
        NativeLogger.shared.info("end-of-stream detected via stall timeout at \(String(format: "%.1f", currentSeconds))s", source: "Audio")
        handleEnded(generation: generation, requestId: requestId)
    }

    private func handlePendingSeekAndPlay(generation: Int) {
        guard let startTime = pendingStartTime else { return }
        let autoplay = pendingAutoplay
        let song = pendingStartSong
        pendingStartTime = nil
        pendingAutoplay = false
        pendingStartSong = nil

        guard let player, isCurrentPlayback(generation: generation) else { return }

        player.seek(to: makeTime(startTime), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, self.isCurrentPlayback(generation: generation) else { return }
            if !finished {
                player.seek(to: .zero)
            }
            if autoplay {
                player.play()
                self.persistence.startProgressTracking()
                if let song {
                    self.stateQueue.async {
                        self.scrobbleBuffer.startTracking(songId: song.id, duration: song.duration)
                    }
                    self.scrobbleSubmitter.sendNowPlaying(songId: song.id)
                }
            }
        }
    }

    private func clearPlayer(sendIdleEvent: Bool, deactivateSession: Bool = false) {
        isQueueTransitioning = false
        isRecoveryReload = false
        bufferMismatchFirstSeen = nil
        playbackGeneration += 1
        lastEmittedPlaybackState = nil
        isSeeking = false
        pendingStartTime = nil
        pendingAutoplay = false
        pendingStartSong = nil

        streamingLoader?.cancel()
        streamingLoader?.cleanupTempFile()
        streamingLoader = nil

        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }

        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        if let observer = failedEndObserver {
            NotificationCenter.default.removeObserver(observer)
            failedEndObserver = nil
        }

        if let observer = stalledObserver {
            NotificationCenter.default.removeObserver(observer)
            stalledObserver = nil
        }

        cancelStallRecovery()
        recoveryController.stopProgressMonitoring()
        statusObservation = nil
        durationObservation = nil
        timeControlStatusObservation = nil
        bufferEmptyObservation = nil
        likelyToKeepUpObservation = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        loadedDurationSeconds = nil
        currentSourceKind = nil
        currentRadioId = nil
        currentRequestId = nil

        if sendIdleEvent {
            emitPlaybackState("idle")
            emitBuffering(false)
        }

        if deactivateSession {
            deactivateAudioSession()
            clearNowPlayingInfo()
        }
    }

    private func resetControlState() {
        repeatMode = "off"
        shuffleEnabled = false
        queueItemCount = 0
        queueIndex = 0
    }

    private func restorePlaybackState() {
        if let persisted = persistence.repository.load() {
            guard !persisted.contextSongs.isEmpty else { return }
            queueEngine.restoreState(from: persisted)
            isQueueEngineActive = true
            savedRestoreTime = persisted.currentTime > 0 ? persisted.currentTime : nil
            repeatMode = persisted.loopState
            shuffleEnabled = persisted.isShuffleActive
            return
        }

        if let migrated = migrateFromLegacyQueueState() {
            guard !migrated.contextSongs.isEmpty else { return }
            try? persistence.repository.save(migrated)
            queueEngine.restoreState(from: migrated)
            isQueueEngineActive = true
            savedRestoreTime = migrated.currentTime > 0 ? migrated.currentTime : nil
            repeatMode = migrated.loopState
            shuffleEnabled = migrated.isShuffleActive
        }
    }

    private func migrateFromLegacyQueueState() -> PlaybackPersistState? {
        guard let json = try? DatabaseManager.shared.dbPool.read({ db in
            try String.fetchOne(db, sql: "SELECT stateJson FROM queueState WHERE key = 'current'")
        }) else { return nil }

        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let contextQueue = raw["contextQueue"] as? [String: Any],
              let songsArray = contextQueue["songs"] as? [[String: Any]],
              !songsArray.isEmpty else {
            return nil
        }

        let songs = songsArray.map { self.legacySongToQueueSong($0) }
        let currentIndex = contextQueue["currentIndex"] as? Int ?? 0

        let userQueueObj = raw["userQueue"] as? [String: Any]
        let userQueueSongs = (userQueueObj?["songs"] as? [[String: Any]] ?? []).map { self.legacySongToQueueSong($0) }

        let originalContextSongs = (raw["originalContextSongs"] as? [[String: Any]] ?? []).map { self.legacySongToQueueSong($0) }
        let originalUserSongs = (raw["originalUserSongs"] as? [[String: Any]] ?? []).map { self.legacySongToQueueSong($0) }
        let playedHistory = (raw["playedUserQueueHistory"] as? [[String: Any]] ?? []).map { self.legacySongToQueueSong($0) }

        let isShuffleActive = raw["isShuffleActive"] as? Bool ?? false
        let isInUserQueue = raw["isInUserQueue"] as? Bool ?? false
        let shuffleHistory = raw["shuffleHistory"] as? [String] ?? []
        let shuffleStartHistory = raw["shuffleStartHistory"] as? [String] ?? []

        var sourceId: QueueSourceId?
        if let srcObj = contextQueue["sourceId"] as? [String: Any],
           let type = srcObj["type"] as? String,
           let id = srcObj["id"] as? String {
            sourceId = QueueSourceId(type: type, id: id)
        }
        let sourceName = contextQueue["sourceName"] as? String

        var state = PlaybackPersistState(from: queueEngine, currentTime: 0)
        state.contextSongs = songs
        state.currentIndex = currentIndex
        state.userQueue = userQueueSongs
        state.originalContextSongs = originalContextSongs
        state.originalUserSongs = originalUserSongs
        state.isShuffleActive = isShuffleActive
        state.isInUserQueue = isInUserQueue
        state.shuffleHistory = shuffleHistory
        state.shuffleStartHistory = shuffleStartHistory
        state.playedUserQueueHistory = playedHistory
        state.sourceId = sourceId
        state.sourceName = sourceName
        state.loopState = "off"
        state.currentTime = 0

        try? DatabaseManager.shared.dbPool.write { db in
            try db.execute(sql: "DELETE FROM queueState WHERE key = 'current'")
        }

        return state
    }

    private func legacySongToQueueSong(_ dict: [String: Any]) -> QueueSong {
        let id = dict["id"] as? String ?? ""
        let streamUrl = sourceResolver.buildStreamUrl(songId: id) ?? ""
        var songDict = dict
        songDict["streamUrl"] = streamUrl
        if songDict["coverArtId"] == nil, let coverArt = dict["coverArt"] as? String {
            songDict["coverArtId"] = coverArt
        }
        return QueueSong(from: songDict)
    }

    private func setupPersistence() {
        persistence.setStateProvider { [weak self] in
            guard let self, self.isQueueEngineActive else { return nil }
            let currentTime = self.seconds(from: self.player?.currentTime() ?? .zero)
            return PlaybackPersistState(from: self.queueEngine, currentTime: currentTime)
        }
        if isQueueEngineActive && player != nil {
            persistence.startProgressTracking()
        }
    }

    private func emitPlaybackState(_ state: String, requestId: String? = nil, force: Bool = false) {
        if !force && state == lastEmittedPlaybackState { return }
        lastEmittedPlaybackState = state
        if state == "playing", remotePlaybackProjection == nil, isQueueEngineActive,
           lastRecordedGeneration != playbackGeneration, let songId = queueEngine.currentSong?.id {
            lastRecordedGeneration = playbackGeneration
            CarPlayLibraryProvider.recordPlayed(songId: songId)
        }
        notifyListeners("playbackStateChanged", data: eventData([
            "state": state,
        ], requestId: requestId))
        updateNowPlayingPlaybackInfo()
        AonsokuNativeCoordinationPlugin.publishSnapshotFromActiveAudioState()
    }

    private func emitProgress(requestId: String? = nil) {
        guard let player = player else {
            notifyListeners("progress", data: eventData([
                "currentTime": 0,
                "duration": 0,
                "bufferedTime": 0,
            ], requestId: requestId))
            return
        }

        let currentTime = seconds(from: player.currentTime())
        let duration = durationSeconds()

        notifyListeners("progress", data: eventData([
            "currentTime": currentTime,
            "duration": duration,
            "bufferedTime": bufferedTime(),
        ], requestId: requestId))
    }

    private func emitDuration(
        for item: AVPlayerItem,
        generation: Int? = nil,
        requestId: String? = nil
    ) {
        if let generation, !isCurrentPlayback(item: item, generation: generation) {
            return
        }

        let duration = seconds(from: item.duration)
        guard duration > 0 else {
            return
        }

        if isRecoveryReload, let metaDuration = currentMetadata.duration, metaDuration > 0 {
            let deviation = abs(duration - metaDuration) / metaDuration
            if deviation > 0.1 { return }
        }

        loadedDurationSeconds = duration
        notifyListeners("durationChanged", data: eventData([
            "duration": duration,
        ], requestId: requestId))
        updateNowPlayingPlaybackInfo()
    }

    private func loadDurationAsync(
        for item: AVPlayerItem,
        generation: Int,
        requestId: String?
    ) {
        item.asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self, weak item] in
            DispatchQueue.main.async {
                guard let self, let item else { return }
                guard self.isCurrentPlayback(item: item, generation: generation) else {
                    return
                }

                var error: NSError?
                let status = item.asset.statusOfValue(forKey: "duration", error: &error)
                guard status == .loaded else {
                    return
                }

                let duration = self.seconds(from: item.asset.duration)
                guard duration > 0 else {
                    return
                }

                if self.isRecoveryReload, let metaDuration = self.currentMetadata.duration, metaDuration > 0 {
                    let deviation = abs(duration - metaDuration) / metaDuration
                    if deviation > 0.1 { return }
                }

                self.loadedDurationSeconds = duration
                self.notifyListeners("durationChanged", data: self.eventData([
                    "duration": duration,
                ], requestId: requestId))
                self.updateNowPlayingPlaybackInfo()
            }
        }
    }

    private func emitBuffering(_ isBuffering: Bool, requestId: String? = nil) {
        notifyListeners("bufferingChanged", data: eventData([
            "isBuffering": isBuffering,
        ], requestId: requestId))
    }

    private func emitCurrentPlaybackState() {
        guard let player = player else {
            emitPlaybackState("idle", force: true)
            emitBuffering(false)
            return
        }

        switch player.timeControlStatus {
        case .playing:
            emitBuffering(false)
            emitPlaybackState("playing", force: true)
        case .paused:
            emitBuffering(false)
            emitPlaybackState("paused", force: true)
        case .waitingToPlayAtSpecifiedRate:
            emitBuffering(true)
            emitPlaybackState("loading", force: true)
        @unknown default:
            emitBuffering(false)
        }
    }

    private func emitError(
        code: String,
        message: String,
        requestId: String? = nil
    ) {
        NativeLogger.shared.error("[\(code)] \(message)", source: "Audio")
        notifyListeners("error", data: eventData([
            "code": code,
            "message": message,
        ], requestId: requestId))
    }

    private func emitRemoteCommand(_ command: String, position: Double? = nil) {
        var data: [String: Any] = eventData(["command": command])

        if let position {
            data["position"] = position
        }

        if let remoteControlCommand = buildRemoteControlCommand(command, position: position) {
            var handledNatively = false
            if let targetDeviceId = remotePlaybackProjection?.targetDeviceId {
                handledNatively = AonsokuNativeCoordinationPlugin.sendCommandFromActive(
                    targetDeviceId: targetDeviceId,
                    expectedGeneration: remotePlaybackProjection?.expectedGeneration,
                    command: remoteControlCommand
                )
            }
            if !handledNatively {
                NativeLogger.shared.warn(
                    "Remote control command was not sent natively: \(remoteControlCommand["type"] ?? "unknown")",
                    source: "Audio"
                )
            }
            return
        }

        notifyListeners("remoteCommand", data: data)
    }

    private func buildRemoteControlCommand(_ command: String, position: Double?) -> [String: Any]? {
        guard let projection = remotePlaybackProjection else {
            return nil
        }

        switch command {
        case "play":
            return ["type": "play"]
        case "pause":
            return ["type": "pause"]
        case "togglePlayPause":
            return ["type": "toggle_play_pause"]
        case "next":
            return ["type": "next"]
        case "previous":
            return ["type": "previous"]
        case "seek":
            guard let position else {
                return nil
            }
            return [
                "type": "seek",
                "seconds": max(0, position),
            ]
        case "shuffle":
            return [
                "type": "set_shuffle",
                "enabled": !projection.isShuffleActive,
            ]
        case "like":
            return ["type": "toggle_like"]
        default:
            return nil
        }
    }

    private func eventData(_ data: [String: Any], requestId: String? = nil) -> [String: Any] {
        var resolvedData = data

        if let requestId = requestId ?? currentRequestId {
            resolvedData["requestId"] = requestId
        }

        return resolvedData
    }

    private func isCurrentPlayback(generation: Int) -> Bool {
        generation == playbackGeneration
    }

    private func isCurrentPlayback(item: AVPlayerItem, generation: Int) -> Bool {
        guard let currentItem = playerItem else {
            return false
        }

        return isCurrentPlayback(generation: generation) && item === currentItem
    }

    private func isCurrentPlayback(player observedPlayer: AVPlayer, generation: Int) -> Bool {
        guard let currentPlayer = player else {
            return false
        }

        return isCurrentPlayback(generation: generation) && observedPlayer === currentPlayer
    }

    private func isPositionWithinLoadedRanges(_ positionSeconds: Double) -> Bool {
        guard let item = playerItem, !item.loadedTimeRanges.isEmpty else { return true }
        return item.loadedTimeRanges.contains { range in
            let tr = range.timeRangeValue
            let start = CMTimeGetSeconds(tr.start)
            let end = start + CMTimeGetSeconds(tr.duration)
            return positionSeconds >= start && positionSeconds < (end + 1.0)
        }
    }

    private func playbackErrorCode(for error: Error?, fallback: String) -> String {
        guard let error else {
            return fallback
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return "aborted"
            case NSURLErrorNotConnectedToInternet:
                return "not_connected_to_internet"
            case NSURLErrorTimedOut:
                return "timed_out"
            case NSURLErrorCannotConnectToHost:
                return "cannot_connect_to_host"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "cannot_find_host"
            case NSURLErrorDataNotAllowed:
                return "data_not_allowed"
            default:
                return "network"
            }
        }

        if nsError.domain == AVFoundationErrorDomain {
            return "decode_failed"
        }

        return fallback
    }

    private func reject(_ call: NativePlaybackRequest, error: Error) {
        let pluginError = error as? NativeAudioPluginError
        let code = pluginError?.code ?? "native_error"
        let message = pluginError?.errorDescription ?? error.localizedDescription
        emitError(code: code, message: message)
        call.reject(message, code, error)
    }

    private func reject(_ call: NativePlaybackRequest, code: String, message: String) {
        emitError(code: code, message: message)
        call.reject(message, code)
    }

    private func durationSeconds() -> Double {
        if let duration = currentMetadata.duration, duration > 0 {
            return duration
        }

        if let item = playerItem {
            let itemDuration = seconds(from: item.duration)
            if itemDuration > 0 {
                return itemDuration
            }
        }

        return loadedDurationSeconds ?? 0
    }

    private func bufferedTime() -> Double {
        guard let range = playerItem?.loadedTimeRanges.first?.timeRangeValue else {
            return seconds(from: player?.currentTime() ?? .zero)
        }

        return seconds(from: range.start) + seconds(from: range.duration)
    }

    private func validateSeekResult(savedPosition: CMTime) -> Bool {
        let expectedTime = CMTimeGetSeconds(savedPosition)
        let actualTime = seconds(from: player?.currentTime() ?? .zero)

        if expectedTime <= 2.0 { return true }

        let timeDelta = abs(actualTime - expectedTime)
        if timeDelta > 2.0 { return false }

        if let metaDuration = currentMetadata.duration, metaDuration > 0,
           let item = playerItem {
            let itemDuration = seconds(from: item.duration)
            if itemDuration > 0 {
                let deviation = abs(itemDuration - metaDuration) / metaDuration
                if deviation > 0.1 { return false }
            }
        }

        return true
    }

    private func emitCorrectDurationFromMetadata() {
        guard let metaDuration = currentMetadata.duration, metaDuration > 0 else { return }
        loadedDurationSeconds = metaDuration
        notifyListeners("durationChanged", data: eventData(["duration": metaDuration], requestId: currentRequestId))
        updateNowPlayingPlaybackInfo()
    }

    private func seconds(from time: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else {
            return 0
        }

        return seconds
    }

    private func forwardBufferDuration(for sourceKind: String?) -> TimeInterval {
        switch sourceKind {
        case "radio":
            return 0
        default:
            return .greatestFiniteMagnitude
        }
    }

    private func makePlayerItem(url: URL, kind: String?, songId: String?) -> AVPlayerItem {
        // Play directly from URL (reliable), cache in background
        if kind == "stream", let songId {
            startBackgroundCache(songId: songId)
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = forwardBufferDuration(for: kind)
        return item
    }

    private func startBackgroundCache(songId: String) {
        let cacheId = AudioCacheUtils.cacheId(for: songId)
        let extensions = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio"]

        for directory in sourceResolver.cacheDirectories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for ext in extensions {
                let fileUrl = directory.appendingPathComponent("\(cacheId).\(ext)")
                if FileManager.default.fileExists(atPath: fileUrl.path) {
                    return
                }
            }
        }

        // Also check the primary cache directory (Application Support)
        if let primaryDir = try? cacheDirectoryURL(createIfNeeded: false),
           FileManager.default.fileExists(atPath: primaryDir.path) {
            for ext in extensions {
                let fileUrl = primaryDir.appendingPathComponent("\(cacheId).\(ext)")
                if FileManager.default.fileExists(atPath: fileUrl.path) {
                    return
                }
            }
        }

        backgroundCacheSongIds.insert(songId)
        downloadManager.download(songId: songId)
    }

    private func makeTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    }

    private var isPlayerAtEnd: Bool {
        guard let item = playerItem else { return false }
        let duration = item.duration
        guard duration.isValid, !duration.isIndefinite, duration.seconds > 0 else {
            return false
        }
        let current = player?.currentTime().seconds ?? 0
        return (duration.seconds - current) < 1.0
    }

    private func seekToStartAndPlay() {
        guard let player = player else { return }
        isSeeking = true
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.isSeeking = false
            self.player?.play()
            self.forceNextSnapshotProgress(0)
            self.emitProgress()
            self.updateNowPlayingPlaybackInfo()
        }
    }

    private func resolveArtworkUrl(for song: QueueSong) -> String? {
        let useAlbumCover = PreferencesManager.shared.getNestedBool(
            store: "player_store",
            path: ["settings", "coverArt", "useAlbumCoverForSongs"]
        ) ?? false
        var coverArtId: String?
        if useAlbumCover, let albumId = song.albumId, !albumId.isEmpty {
            coverArtId = albumId
        } else if let id = song.coverArtId, !id.isEmpty {
            coverArtId = id
        }
        guard let id = coverArtId else { return nil }
        return "aonsoku-media://getCoverArt?id=\(id)&size=800"
    }

    private func loadRemotePlaybackSong(songId: String) async -> SongRecord? {
        guard !songId.isEmpty else { return nil }

        let repository = SongRepository(db: DatabaseManager.shared.dbPool)
        if let song = try? repository.getById(songId) {
            return song
        }

        guard let song = await fetchRemotePlaybackSong(songId: songId) else {
            return nil
        }

        try? repository.upsert(song)
        return song
    }

    private func fetchRemotePlaybackSong(songId: String) async -> SongRecord? {
        guard let credentials = KeychainManager.retrieve() else {
            return nil
        }

        do {
            let response = try await SubsonicHTTPClient().request(
                baseUrl: credentials.serverUrl,
                path: "getSong.view",
                credentials: credentials,
                extraQuery: ["id": songId]
            )
            guard let item = response.data["song"] as? [String: Any] else {
                return nil
            }
            return parseRemotePlaybackSong(item)
        } catch {
            NativeLogger.shared.warn(
                "Failed to fetch remote playback song metadata: \(error.localizedDescription)",
                source: "Audio"
            )
            return nil
        }
    }

    private func parseRemotePlaybackSong(_ item: [String: Any]) -> SongRecord? {
        guard let id = item["id"] as? String,
              let title = item["title"] as? String else {
            return nil
        }

        return SongRecord(
            id: id,
            parent: stringValue(item["parent"]),
            title: title,
            album: stringValue(item["album"]),
            artist: stringValue(item["artist"]),
            track: intValue(item["track"]),
            year: intValue(item["year"]),
            genre: stringValue(item["genre"]),
            coverArt: stringValue(item["coverArt"]),
            size: intValue(item["size"]),
            contentType: stringValue(item["contentType"]),
            suffix: stringValue(item["suffix"]),
            duration: intValue(item["duration"]) ?? 0,
            bitRate: intValue(item["bitRate"]),
            path: stringValue(item["path"]),
            playCount: intValue(item["playCount"]),
            discNumber: intValue(item["discNumber"]),
            created: stringValue(item["created"]),
            albumId: stringValue(item["albumId"]),
            artistId: stringValue(item["artistId"]),
            played: stringValue(item["played"]),
            starred: stringValue(item["starred"]),
            starredAt: epochMilliseconds(stringValue(item["starred"])),
            playedAt: epochMilliseconds(stringValue(item["played"])),
            bpm: intValue(item["bpm"]),
            comment: stringValue(item["comment"]),
            sortName: stringValue(item["sortName"]),
            mediaType: stringValue(item["mediaType"]),
            musicBrainzId: stringValue(item["musicBrainzId"]),
            genresJson: jsonString(item["genres"]),
            replayGainJson: jsonString(item["replayGain"])
        )
    }

    private func routeChangeReason(from notification: Notification) -> String {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else {
            return "unknown"
        }

        switch reason {
        case .unknown:
            return "unknown"
        case .newDeviceAvailable:
            return "newDeviceAvailable"
        case .oldDeviceUnavailable:
            return "oldDeviceUnavailable"
        case .categoryChange:
            return "categoryChange"
        case .override:
            return "override"
        case .wakeFromSleep:
            return "wakeFromSleep"
        case .noSuitableRouteForCategory:
            return "noSuitableRouteForCategory"
        case .routeConfigurationChange:
            return "routeConfigurationChange"
        @unknown default:
            return "unknown"
        }
    }
}

private struct ResolvedAudioSource {
    let kind: String
    let url: URL
    let radioId: String?
    let songId: String?
}

private struct NativeMediaStreamRequest {
    let songId: String
    let maxBitRate: String?
    let format: String?
}

private struct NativeAudioMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var artworkUrl: String?
    var coverArtId: String?
}

private struct NativeRemotePlaybackProjection {
    var metadata: NativeAudioMetadata
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var isShuffleActive: Bool
    var repeatMode: String
    var volume: Double?
    var targetDeviceId: String?
    var expectedGeneration: Int?
}

extension SongRecord {


    fileprivate func remotePlaybackMetadata() -> NativeAudioMetadata {
        let coverArtId = remotePlaybackCoverArtId()
        return NativeAudioMetadata(
            title: title,
            artist: artist,
            album: album,
            duration: Double(duration),
            artworkUrl: coverArtId.map {
                "aonsoku-media://getCoverArt?id=\($0)&size=800"
            },
            coverArtId: coverArtId
        )
    }

    func remotePlaybackCoverArtId() -> String? {
        let useAlbumCover = PreferencesManager.shared.getNestedBool(
            store: "player_store",
            path: ["settings", "coverArt", "useAlbumCoverForSongs"]
        ) ?? false
        if useAlbumCover, let albumId, !albumId.isEmpty {
            return albumId
        }
        if let coverArt, !coverArt.isEmpty {
            return coverArt
        }
        if let albumId, !albumId.isEmpty {
            return albumId
        }
        return nil
    }


}

private struct NativeCachedAudioFile {
    var songId: String
    var uri: String
    var contentType: String?
    var sizeBytes: Int64?
    var lastModifiedAt: Double?
}



private enum NativeAudioPluginError: LocalizedError {
    case invalidSource(String)
    case unsupportedSource(String)
    case invalidCacheRequest(String)
    case cacheFailure(String)

    var code: String {
        switch self {
        case .invalidSource:
            return "invalid_source"
        case .unsupportedSource:
            return "unsupported_source"
        case .invalidCacheRequest:
            return "invalid_cache_request"
        case .cacheFailure:
            return "cache_failure"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidSource(let message):
            return message
        case .unsupportedSource(let message):
            return message
        case .invalidCacheRequest(let message):
            return message
        case .cacheFailure(let message):
            return message
        }
    }
}

// MARK: - NativeQueueEngineDelegate

extension NativePlaybackService: NativeQueueEngineDelegate {
    func queueEngine(_ engine: NativeQueueEngine, loadSong song: QueueSong, autoplay: Bool, startTime: Double?) {
        queueRevision += 1
        if let entry = scrobbleBuffer.stopTracking() {
            scrobbleSubmitter.submitIfEligible(
                entry: ScrobbleEntry(songId: entry.songId, playedDurationMs: entry.playedDurationMs, timestamp: entry.timestamp),
                songDurationSeconds: entry.timestamp
            )
        }

        playbackGeneration += 1
        let generation = playbackGeneration

        loadQueue.async { [self] in
            guard let resolved = self.sourceResolver.resolveSource(for: song) else {
                DispatchQueue.main.async {
                    self.isQueueTransitioning = false
                    if KeychainManager.retrieve() == nil {
                        self.emitError(code: "missing_credentials", message: "Cannot resolve audio source: Keychain credentials are missing. Please re-configure the server.")
                    } else {
                        self.emitError(code: "invalid_source", message: "Cannot resolve audio source for song: \(song.id)")
                    }
                }
                return
            }

            do {
                try self.configureAudioSession()
                if autoplay {
                    try self.activateAudioSession()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isQueueTransitioning = false
                    self.emitError(code: "audio_session_failed", message: error.localizedDescription)
                }
                return
            }

            DispatchQueue.main.async {
                guard self.playbackGeneration == generation else { return }

                self.clearPlayer(sendIdleEvent: false)
                self.playbackGeneration = generation

                let item = self.makePlayerItem(url: resolved.url, kind: resolved.kind, songId: song.id)
                let player = AVPlayer(playerItem: item)
                self.player = player
                self.playerItem = item
                self.currentSourceKind = resolved.kind
                self.currentSourceUrl = resolved.url
                self.currentRadioId = nil
                self.currentRequestId = nil

                var metadata = NativeAudioMetadata()
                metadata.title = song.title
                metadata.artist = song.artist
                metadata.album = song.album
                metadata.duration = song.duration
                metadata.artworkUrl = self.resolveArtworkUrl(for: song)
                self.currentMetadata = metadata
                self.loadedDurationSeconds = metadata.duration

                self.addObservers(for: item, player: player, generation: generation, requestId: nil)
                self.addProgressObserver(to: player, generation: generation, requestId: nil)
                self.recoveryController.startProgressMonitoring(generation: generation, sourceKind: self.recoverySourceKind())
                self.updateNowPlayingInfo()

                self.emitPlaybackState("loading")

                if let startTime = startTime, startTime > 0 {
                    // Defer seek + play until item is ready
                    self.pendingStartTime = startTime
                    self.pendingAutoplay = autoplay
                    self.pendingStartSong = song
                } else if autoplay {
                    self.pendingStartTime = nil
                    self.pendingAutoplay = false
                    self.pendingStartSong = nil
                    player.play()
                    self.persistence.startProgressTracking()
                    self.stateQueue.async {
                        self.scrobbleBuffer.startTracking(songId: song.id, duration: song.duration)
                    }
                    self.scrobbleSubmitter.sendNowPlaying(songId: song.id)
                }
            }
        }
    }

    func queueEngine(_ engine: NativeQueueEngine, didAdvanceTo index: Int, songId: String, reason: QueueAdvanceReason) {
        persistence.markStateDirty()
        forceNextSnapshotProgress(0)
        notifyListeners("queueStateChanged", data: [
            "currentIndex": index,
            "songId": songId,
            "reason": reason.rawValue,
            "isInUserQueue": engine.isInUserQueue,
        ])
        AonsokuNativeCoordinationPlugin.publishSnapshotFromActiveAudioState()
    }

    func queueEngine(_ engine: NativeQueueEngine, didChangeContents reason: String) {
        persistence.markStateDirty()
        notifyListeners("queueContentsChanged", data: [
            "reason": reason,
        ])
        AonsokuNativeCoordinationPlugin.publishSnapshotFromActiveAudioState()
    }

    func queueEngineDidExhaustQueue(_ engine: NativeQueueEngine) {
        if let entry = scrobbleBuffer.stopTracking() {
            scrobbleSubmitter.submitIfEligible(
                entry: ScrobbleEntry(songId: entry.songId, playedDurationMs: entry.playedDurationMs, timestamp: entry.timestamp),
                songDurationSeconds: entry.timestamp
            )
        }
        forceNextSnapshotProgress(0)
        DispatchQueue.main.async {
            self.isSeeking = true
            self.player?.pause()
            self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                self.isSeeking = false
                self.isQueueTransitioning = false
                self.emitPlaybackState("ended")
                self.emitProgress()
                self.updateNowPlayingPlaybackInfo()
            }
        }
        notifyListeners("ended", data: [
            "reason": "finished",
        ])
    }

    func queueEngine(_ engine: NativeQueueEngine, seekToStart song: QueueSong) {
        DispatchQueue.main.async {
            guard let player = self.player else { return }
            self.isSeeking = true
            player.seek(to: CMTime.zero) { [weak self] finished in
                guard let self = self else { return }
                self.isSeeking = false
                guard finished else { return }
                player.play()
                self.forceNextSnapshotProgress(0)
                self.emitPlaybackState("playing")
                self.stateQueue.async {
                    if let entry = self.scrobbleBuffer.stopTracking() {
                        self.scrobbleSubmitter.submitIfEligible(
                            entry: ScrobbleEntry(songId: entry.songId, playedDurationMs: entry.playedDurationMs, timestamp: entry.timestamp),
                            songDurationSeconds: entry.timestamp
                        )
                    }
                    self.scrobbleBuffer.startTracking(songId: song.id, duration: song.duration)
                }
                self.scrobbleSubmitter.sendNowPlaying(songId: song.id)
            }
        }
    }
}

// MARK: - NativeDownloadManagerDelegate

extension NativePlaybackService: NativeDownloadManagerDelegate {
    func downloadManager(_ manager: NativeDownloadManager, didProgress songId: String, loaded: Int64, total: Int64) {
        if backgroundCacheSongIds.contains(songId) { return }
        notifyListeners("downloadProgress", data: [
            "songId": songId,
            "loaded": NSNumber(value: loaded),
            "total": NSNumber(value: total),
        ])
    }

    func downloadManager(_ manager: NativeDownloadManager, didComplete songId: String, fileUrl: URL, contentType: String, sizeBytes: Int64) {
        if backgroundCacheSongIds.remove(songId) != nil {
            backgroundCacheCompletedSongIds.insert(songId)
            notifyListeners("streamCacheCompleted", data: [
                "songId": songId,
                "uri": fileUrl.absoluteString,
                "contentType": contentType,
                "sizeBytes": NSNumber(value: sizeBytes),
            ])
            checkEndOfStreamAfterCacheComplete(songId: songId)
            return
        }
        notifyListeners("downloadCompleted", data: [
            "songId": songId,
            "uri": fileUrl.absoluteString,
            "contentType": contentType,
            "sizeBytes": NSNumber(value: sizeBytes),
        ])
    }

    func downloadManager(_ manager: NativeDownloadManager, didFail songId: String, error: Error) {
        if backgroundCacheSongIds.remove(songId) != nil {
            NativeLogger.shared.warn("background cache failed for \(songId): \(error.localizedDescription)", source: "Audio")
            return
        }
        notifyListeners("downloadFailed", data: [
            "songId": songId,
            "error": error.localizedDescription,
        ])
    }
}

// MARK: - PlaybackRecoveryDelegate

extension NativePlaybackService: PlaybackRecoveryDelegate {
    func recoverySeek(_ controller: PlaybackRecoveryController, to time: CMTime, generation: Int) {
        guard isCurrentPlayback(generation: generation), let player else { return }

        if case .level1(let attempt) = controller.state {
            notifyListeners("recoveryAttempt", data: [
                "level": 1,
                "attempt": attempt,
                "maxAttempts": 3,
            ])
        }

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.isCurrentPlayback(generation: generation) else { return }
            player.play()
        }
    }

    func recoveryReload(_ controller: PlaybackRecoveryController, generation: Int, savedPosition: CMTime) {
        guard isCurrentPlayback(generation: generation) else {
            controller.reloadDidComplete(success: false, generation: generation)
            return
        }

        if case .level2(let attempt) = controller.state {
            notifyListeners("recoveryAttempt", data: [
                "level": 2,
                "attempt": attempt,
                "maxAttempts": 2,
            ])
        }

        if isQueueEngineActive, let song = queueEngine.currentSong {
            loadQueue.async { [self] in
                self.sourceResolver.invalidateCredentialsCache()
                guard let resolved = self.sourceResolver.resolveSource(for: song) else {
                    DispatchQueue.main.async {
                        controller.reloadDidComplete(success: false, generation: generation)
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.applyReloadedSource(url: resolved.url, kind: resolved.kind, generation: generation, savedPosition: savedPosition, controller: controller)
                }
            }
        } else if let sourceUrl = currentSourceUrl {
            applyReloadedSource(url: sourceUrl, kind: currentSourceKind, generation: generation, savedPosition: savedPosition, controller: controller)
        } else {
            controller.reloadDidComplete(success: false, generation: generation)
        }
    }

    private func applyReloadedSource(url: URL, kind: String?, generation: Int, savedPosition: CMTime, controller: PlaybackRecoveryController) {
        guard isCurrentPlayback(generation: generation) else {
            controller.reloadDidComplete(success: false, generation: generation)
            return
        }

        removeItemObservers()
        isRecoveryReload = true

        streamingLoader?.cancel()
        streamingLoader?.cleanupTempFile()

        let songId = isQueueEngineActive ? queueEngine.currentSong?.id : nil
        let item = makePlayerItem(url: url, kind: kind, songId: songId)
        player?.replaceCurrentItem(with: item)
        playerItem = item
        currentSourceKind = kind
        currentSourceUrl = url

        addObservers(for: item, player: player!, generation: generation, requestId: currentRequestId)
        addProgressObserver(to: player!, generation: generation, requestId: currentRequestId)

        player?.seek(to: savedPosition, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.isCurrentPlayback(generation: generation) else {
                controller.reloadDidComplete(success: false, generation: generation)
                return
            }

            let savedSeconds = CMTimeGetSeconds(savedPosition)
            let rangeOk = savedSeconds <= 5.0 || self.isPositionWithinLoadedRanges(savedSeconds)

            if rangeOk && self.validateSeekResult(savedPosition: savedPosition) {
                self.isRecoveryReload = false
                self.player?.play()
                controller.reloadDidComplete(success: true, generation: generation)
            } else {
                let trackDuration = self.durationSeconds()
                let isNearEnd = savedSeconds > 0 && trackDuration > 0 && (trackDuration - savedSeconds) < 10.0

                if isNearEnd && self.isQueueEngineActive {
                    NativeLogger.shared.info(
                        "recovery reload near end (\(String(format: "%.1f", savedSeconds))s / \(String(format: "%.1f", trackDuration))s) — treating as end-of-stream",
                        source: "Audio"
                    )
                    self.isRecoveryReload = false
                    self.handleEnded(generation: generation, requestId: self.currentRequestId)
                } else {
                    self.player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        guard let self, self.isCurrentPlayback(generation: generation) else {
                            controller.reloadDidComplete(success: false, generation: generation)
                            return
                        }
                        self.isRecoveryReload = false
                        self.emitCorrectDurationFromMetadata()
                        self.player?.play()
                        controller.reloadDidComplete(success: true, generation: generation)
                    }
                }
            }
        }
    }

    func recoveryExhausted(_ controller: PlaybackRecoveryController, generation: Int) {
        isRecoveryReload = false
        guard isCurrentPlayback(generation: generation) else { return }

        if isQueueEngineActive {
            if queueEngine.hasNext {
                isQueueTransitioning = true
                stateQueue.async {
                    self.queueEngine.skipToNext()
                }
            } else {
                emitError(code: "recovery_failed", message: "Playback recovery exhausted all attempts.")
                emitPlaybackState("failed")
            }
        } else {
            emitError(code: "recovery_failed", message: "Playback recovery exhausted all attempts.")
            emitPlaybackState("failed")
        }
    }

    func recoverySetBuffering(_ controller: PlaybackRecoveryController, isBuffering: Bool) {
        emitBuffering(isBuffering)
    }

    func recoveryDidBegin(_ controller: PlaybackRecoveryController) {
        NativeLogger.shared.warn("playback recovery began", source: "Audio")
        if isQueueEngineActive {
            stateQueue.async { self.scrobbleBuffer.pauseTracking() }
        }
    }

    func recoveryDidSucceed(_ controller: PlaybackRecoveryController) {
        NativeLogger.shared.info("playback recovery succeeded", source: "Audio")
        if isQueueEngineActive {
            stateQueue.async { self.scrobbleBuffer.resumeTracking() }
        }
        recoveryController.startProgressMonitoring(generation: playbackGeneration, sourceKind: recoverySourceKind())
    }
}

// MARK: - StreamingResourceLoaderDelegate

extension NativePlaybackService: StreamingResourceLoaderDelegate {
    func resourceLoader(_ loader: StreamingResourceLoader, didCompleteCache fileURL: URL, contentType: String, sizeBytes: Int64) {
        let songId = loader.songId

        notifyListeners("bufferComplete", data: eventData([
            "songId": songId,
        ]))

        DispatchQueue.global(qos: .utility).async {
            do {
                let directory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true)
                let ext = AudioCacheUtils.fileExtension(for: contentType)
                let cacheId = AudioCacheUtils.cacheId(for: songId)
                let destURL = directory.appendingPathComponent("\(cacheId).\(ext)", isDirectory: false)

                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: fileURL, to: destURL)

                let metadata = NativeCachedAudioFileMetadata(
                    songId: songId,
                    fileName: "\(cacheId).\(ext)",
                    contentType: contentType,
                    lastModifiedAt: Date().timeIntervalSince1970 * 1000
                )
                let metadataData = try JSONEncoder().encode(metadata)
                let metadataURL = directory.appendingPathComponent("\(cacheId).json", isDirectory: false)
                try metadataData.write(to: metadataURL, options: [.atomic])

                DispatchQueue.main.async {
                    self.notifyListeners("streamCacheCompleted", data: [
                        "songId": songId,
                        "uri": destURL.absoluteString,
                        "contentType": contentType,
                        "sizeBytes": NSNumber(value: sizeBytes),
                    ])
                }
            } catch {
                NativeLogger.shared.warn("stream cache persist failed for \(songId): \(error.localizedDescription)", source: "Audio")
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func resourceLoader(_ loader: StreamingResourceLoader, didFailWithError error: Error) {
        NativeLogger.shared.warn("stream resource loader failed for \(loader.songId): \(error.localizedDescription)", source: "Audio")
    }
}

// MARK: - CarPlay transport-independent API

extension NativePlaybackService {
    private func cancelCarPlaySelection() {
        if Thread.isMainThread { cancelCarPlayRequests() }
        else { DispatchQueue.main.async { self.cancelCarPlayRequests() } }
    }

    public func carPlaySnapshot(
        queueOffset: Int = 0, queueLimit: Int = 100,
        _ completion: @escaping (CarPlayPlaybackSnapshot) -> Void
    ) {
        precondition(Thread.isMainThread)
        let isPlaying = player?.timeControlStatus == .playing
        let isRemote = remotePlaybackProjection != nil
        let currentTime = player == nil ? (savedRestoreTime ?? 0) : seconds(from: player?.currentTime() ?? .zero)
        stateQueue.async {
            let engine = self.queueEngine
            let revision = self.queueRevision
            var entries: [CarPlayQueueEntry] = []
            let offset = max(0, queueOffset)
            let limit = max(1, queueLimit)
            let currentCount = !engine.isInUserQueue && engine.currentSong != nil ? 1 : 0
            if offset == 0, !engine.isInUserQueue, let song = engine.currentSong {
                entries.append(CarPlayQueueEntry(id: song.id, title: song.title, artist: song.artist,
                    isCurrent: true, index: engine.currentIndex, isUserQueue: false, revision: revision))
            }
            entries += engine.userQueue.enumerated().dropFirst(max(0, offset - currentCount))
                .prefix(max(0, limit - entries.count)).map { index, song in
                CarPlayQueueEntry(id: song.id, title: song.title, artist: song.artist,
                    isCurrent: engine.isInUserQueue && index == 0, index: index, isUserQueue: true, revision: revision)
            }
            let start = min(engine.currentIndex + 1, engine.contextSongs.count)
            let contextOffset = start + max(0, offset - currentCount - engine.userQueue.count)
            entries += engine.contextSongs.enumerated().dropFirst(contextOffset).prefix(max(0, limit - entries.count)).map { index, song in
                CarPlayQueueEntry(id: song.id, title: song.title, artist: song.artist,
                    isCurrent: false, index: index, isUserQueue: false, revision: revision)
            }
            let snapshot = CarPlayPlaybackSnapshot(title: engine.currentSong?.title,
                isPlaying: isPlaying, currentTime: currentTime, isRemote: isRemote, shuffle: engine.isShuffleActive,
                repeatMode: engine.loopState.rawValue, queueOffset: offset,
                queueTotal: currentCount + engine.userQueue.count + engine.contextSongs.count - start, queue: entries)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    public func performCarPlay(_ command: CarPlayPlaybackCommand,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard remotePlaybackProjection == nil else { completion(.failure(CarPlayError.remotePlayback)); return }
        cancelCarPlaySelection()
        let call = NativePlaybackRequest(success: { _ in
            DispatchQueue.main.async { completion(.success(())) }
        }, failure: { message, code, _ in
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "AonsokuPlayback", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message, "code": code ?? "native_error"])))
            }
        })
        switch command {
        case .play: play(call)
        case .pause: pause(call)
        case .next: skipToNext(call)
        case .previous: skipToPrevious(call)
        case .shuffle(let enabled):
            setShuffle(NativePlaybackRequest(options: ["enabled": enabled], success: { _ in completion(.success(())) }))
        case .repeatMode(let mode):
            setRepeatMode(NativePlaybackRequest(options: ["mode": mode], success: { _ in completion(.success(())) },
                failure: { message, _, _ in completion(.failure(NSError(domain: "AonsokuPlayback", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]))) }))
        case .queueEntry(let entry):
            stateQueue.async {
                guard entry.revision == self.queueRevision else { call.reject(CarPlayError.staleSelection.localizedDescription); return }
                let songs = entry.isUserQueue ? self.queueEngine.userQueue : self.queueEngine.contextSongs
                guard songs.indices.contains(entry.index), songs[entry.index].id == entry.id else {
                    call.reject(CarPlayError.staleSelection.localizedDescription); return
                }
                if entry.isUserQueue { self.queueEngine.playUserQueueAtIndex(entry.index) }
                else { self.queueEngine.playAtIndex(entry.index, startTime: nil) }
                self.persistence.markStateDirty()
                call.resolve()
            }
        }
    }

    public func playCarPlayLibrary(_ route: CarPlayLibraryRoute, pageOffset: Int, pageLimit: Int = 40,
                                    index: Int, expectedId: String, sourceName: String,
                                    completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard remotePlaybackProjection == nil else { completion(.failure(CarPlayError.remotePlayback)); return }
        carPlaySelectionGeneration += 1
        let generation = carPlaySelectionGeneration
        carPlaySelectionTask?.cancel()
        carPlaySelectionTask = Task { @MainActor in
            do {
                let songs = try await CarPlayLibraryProvider().selection(route, pageOffset: pageOffset, pageLimit: pageLimit,
                    index: index, expectedId: expectedId)
                try Task.checkCancellation()
                guard self.carPlaySelectionGeneration == generation, self.remotePlaybackProjection == nil else {
                    throw CancellationError()
                }
                let queueIndex: Int
                let sourceId: QueueSourceId?
                switch route {
                case .album(let id): queueIndex = index; sourceId = QueueSourceId(type: "album", id: id)
                case .playlist(let id): queueIndex = index; sourceId = QueueSourceId(type: "playlist", id: id)
                default: queueIndex = index - pageOffset; sourceId = nil
                }
                self.playQueueSongsAtIndex(songs: songs, index: queueIndex, shuffle: false,
                                           sourceId: sourceId, sourceName: sourceName)
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    public func cancelCarPlayRequests() {
        precondition(Thread.isMainThread)
        carPlaySelectionGeneration += 1
        carPlaySelectionTask?.cancel()
        carPlaySelectionTask = nil
    }
}
