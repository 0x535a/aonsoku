import XCTest
@testable import AonsokuKit

final class QueueTests: XCTestCase {
    func testSelectionStartsAtCurrentAndKeepsCompleteSource() {
        let engine = NativeQueueEngine()
        let songs = ["a", "b", "c", "d"].map { makeSong($0) }
        engine.setPlaybackQueue(songs: songs, index: 2, shuffle: false, autoplay: false)
        XCTAssertEqual(engine.contextSongs.map(\.id), ["c", "d"])
        XCTAssertEqual(engine.sourceSongs.map(\.id), ["a", "b", "c", "d"])
        XCTAssertFalse(engine.hasPrev)
        let spy = QueueDelegateSpy()
        engine.delegate = spy
        engine.skipToPrevious(currentTime: 2)
        XCTAssertEqual(spy.seekedSongIds, ["c"])
    }

    func testRepeatRebuildsFromSourceAndPreservesCrossCyclePrevious() {
        let engine = NativeQueueEngine()
        engine.setPlaybackQueue(songs: ["a", "b", "c", "d"].map { makeSong($0) }, index: 2, shuffle: false)
        engine.setLoopState(.all)
        XCTAssertEqual(engine.contextSongs.map(\.id), ["c", "d", "a", "b"])
        engine.skipToNext()
        engine.skipToNext()
        engine.skipToPrevious(currentTime: 0)
        XCTAssertEqual(engine.currentSong?.id, "d")
        engine.setLoopState(.off)
        XCTAssertEqual(engine.contextSongs.map(\.id), ["d"])
        XCTAssertEqual(engine.sourceSongs.map(\.id), ["a", "b", "c", "d"])
    }

    func testRepeatAllPreparesNextCycleBeforeCurrentReachesEnd() {
        let engine = NativeQueueEngine()
        engine.setLoopState(.all)
        engine.setPlaybackQueue(songs: ["a", "b"].map { makeSong($0) }, index: 0, shuffle: false)
        engine.skipToNext()
        XCTAssertEqual(engine.contextSongs.map(\.id), ["a", "b", "a", "b"])
        engine.skipToNext()
        engine.skipToPrevious(currentTime: 0)
        XCTAssertEqual(engine.currentSong?.id, "b")
    }

    func testRepeatAllDrainsUserQueueIntoNextPreparedCycle() {
        let engine = NativeQueueEngine()
        engine.setLoopState(.all)
        engine.setPlaybackQueue(songs: ["a", "b"].map { makeSong($0) }, index: 0, shuffle: false)
        engine.playAtIndex(1, startTime: nil)
        engine.addToUserQueue(songs: [makeSong("u")], position: "next")
        engine.skipToNext()
        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "a")
        engine.skipToPrevious(currentTime: 0)
        XCTAssertEqual(engine.currentSong?.id, "u")
    }

    func testSelectingUserOccurrenceRetainsSkippedSongsForPrevious() {
        let engine = NativeQueueEngine()
        engine.setPlaybackQueue(songs: [makeSong("a")], index: 0, shuffle: false)
        engine.addToUserQueue(songs: ["u1", "u2", "u3"].map { makeSong($0) }, position: "last")
        engine.playUserQueueAtIndex(2)
        XCTAssertEqual(engine.currentSong?.id, "u3")
        XCTAssertEqual(engine.playedUserQueueHistory.map(\.id), ["u1", "u2"])
        engine.skipToPrevious(currentTime: 0)
        XCTAssertEqual(engine.currentSong?.id, "u2")
    }

    func testReorderingLaterDuplicateDoesNotMoveCurrentOccurrence() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(songs: ["a", "a", "b", "c"].map { makeSong($0) }, currentIndex: 1,
                               autoplay: false, startTime: nil)
        XCTAssertTrue(engine.reorderContextQueue(fromIndex: 2, toIndex: 3))
        XCTAssertEqual(engine.currentIndex, 1)
    }

    func testSourceQueueSurvivesPersistenceAndOldStatesDecode() throws {
        let engine = NativeQueueEngine()
        engine.setPlaybackQueue(songs: ["a", "b", "c"].map { makeSong($0) }, index: 1, shuffle: false)
        let data = try JSONEncoder().encode(PlaybackPersistState(from: engine, currentTime: 2))
        let restored = NativeQueueEngine()
        restored.restoreState(from: try JSONDecoder().decode(PlaybackPersistState.self, from: data))
        restored.setLoopState(.all)
        XCTAssertEqual(restored.contextSongs.map(\.id), ["b", "c", "a"])

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "sourceSongs")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let old = NativeQueueEngine()
        old.restoreState(from: try JSONDecoder().decode(PlaybackPersistState.self, from: oldData))
        XCTAssertEqual(old.currentSong?.id, "b")
        XCTAssertEqual(old.sourceSongs.map(\.id), ["a", "b", "c"])
    }

    func testSetContextQueueLoadsRequestedSongAndStartPosition() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate

        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 1,
            autoplay: true,
            startTime: 12.5
        )

        XCTAssertEqual(engine.currentSong?.id, "b")
        XCTAssertEqual(delegate.loads.first?.song.id, "b")
        XCTAssertEqual(delegate.loads.first?.autoplay, true)
        XCTAssertEqual(delegate.loads.first?.startTime, 12.5)
    }

    func testUserQueueRunsBeforeRemainingContextAndCanNavigateBack() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b"), makeSong("c")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.addToUserQueue(songs: [makeSong("u1"), makeSong("u2")], position: "last")

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "u1")
        XCTAssertTrue(engine.isInUserQueue)

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "u2")

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "b")
        XCTAssertFalse(engine.isInUserQueue)

        engine.skipToPrevious(currentTime: 0)
        XCTAssertEqual(engine.currentSong?.id, "u2")
        XCTAssertTrue(engine.isInUserQueue)
    }

    func testRepeatOneStillConsumesPendingManualQueue() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.setLoopState(.one)
        engine.addToUserQueue(songs: [makeSong("u")], position: "next")

        engine.handleEnded()

        XCTAssertEqual(engine.currentSong?.id, "u")
        XCTAssertTrue(engine.isInUserQueue)
    }

    func testAutomaticPreloadPredictionMatchesQueueAdvanceSemantics() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        XCTAssertEqual(engine.nextSongForAutomaticAdvance?.id, "b")

        engine.addToUserQueue(songs: [makeSong("u1"), makeSong("u2")], position: "last")
        XCTAssertEqual(engine.nextSongForAutomaticAdvance?.id, "u1")
        engine.skipToNext()
        XCTAssertEqual(engine.nextSongForAutomaticAdvance?.id, "u2")
        engine.skipToNext()
        XCTAssertEqual(engine.nextSongForAutomaticAdvance?.id, "b")
    }

    func testAutomaticPreloadPredictionKeepsRepeatOneAndExtendsShuffledCycles() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b"), makeSong("c")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.setLoopState(.one)
        XCTAssertNil(engine.nextSongForAutomaticAdvance)

        engine.addToUserQueue(songs: [makeSong("u")], position: "last")
        XCTAssertEqual(engine.nextSongForAutomaticAdvance?.id, "u")

        engine.clearUserQueue()
        engine.setLoopState(.all)
        engine.setShuffleActive(true)
        let first = engine.contextSongs.first?.id
        engine.playAtIndex(engine.contextSongs.count - 1, startTime: nil)
        XCTAssertEqual(engine.nextSongForAutomaticAdvance?.id, first)
    }

    func testPreviousRestartsAfterThresholdBeforeChangingQueuePosition() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 1,
            autoplay: false,
            startTime: nil
        )

        engine.skipToPrevious(currentTime: 4)

        XCTAssertEqual(engine.currentSong?.id, "b")
        XCTAssertEqual(delegate.seekedSongIds, ["b"])
    }

    func testReorderRetainsCurrentSongIdentityAndReportsContentChange() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b"), makeSong("c")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )

        engine.reorderContextQueue(fromIndex: 0, toIndex: 2)

        XCTAssertEqual(engine.contextSongs.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(engine.currentSong?.id, "a")
        XCTAssertEqual(engine.currentIndex, 2)
        XCTAssertEqual(delegate.contentReasons, ["queue-edit"])
    }

    func testRemoteReorderUsesFlattenedQueueTiers() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b"), makeSong("c"), makeSong("d")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.addToUserQueue(
            songs: [makeSong("u1"), makeSong("u2")],
            position: "last"
        )

        XCTAssertTrue(engine.reorderFlattenedQueue(fromIndex: 1, toIndex: 2))
        XCTAssertEqual(engine.userQueue.map(\.id), ["u2", "u1"])
        XCTAssertTrue(engine.reorderFlattenedQueue(fromIndex: 3, toIndex: 5))
        XCTAssertEqual(engine.contextSongs.map(\.id), ["a", "c", "d", "b"])
        XCTAssertFalse(engine.reorderFlattenedQueue(fromIndex: 1, toIndex: 3))
    }

    func testRemoteRemovalPrefersUserTierAndProtectsCurrentSong() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("current"), makeSong("duplicate"), makeSong("later")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.addToUserQueue(songs: [makeSong("duplicate")], position: "last")

        XCTAssertTrue(engine.removeSongIds(["duplicate"]))
        XCTAssertTrue(engine.userQueue.isEmpty)
        XCTAssertEqual(engine.contextSongs.map(\.id), ["current", "duplicate", "later"])
        XCTAssertTrue(engine.removeSongIds(["duplicate"]))
        XCTAssertEqual(engine.contextSongs.map(\.id), ["current", "later"])
        XCTAssertFalse(engine.removeSongIds(["current"]))
        XCTAssertEqual(engine.currentSong?.id, "current")
    }

    func testQueueExhaustionDoesNotReloadCurrentSong() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        delegate.loads.removeAll()

        engine.skipToNext()

        XCTAssertEqual(delegate.exhaustionCount, 1)
        XCTAssertTrue(delegate.loads.isEmpty)
        XCTAssertEqual(engine.currentSong?.id, "a")
    }

    func testRepeatAllHasNothingToWrapToWithoutContextSongs() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        // Only user-queued songs, as a handoff or an add to an idle queue makes.
        var state = PlaybackPersistState(from: engine, currentTime: 0)
        state.userQueue = [makeSong("u1"), makeSong("u2")]
        state.isInUserQueue = true
        state.loopState = LoopState.all.rawValue
        engine.restoreState(from: state)

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "u2")
        engine.skipToNext()

        XCTAssertNil(engine.currentSong)
        XCTAssertFalse(engine.isInUserQueue)
        XCTAssertEqual(delegate.loads.map(\.song.id), ["u2"])

        let empty = NativeQueueEngine()
        empty.setLoopState(.all)
        empty.skipToNext()
        XCTAssertNil(empty.currentSong)
    }

    func testShuffleAndUnshuffleReportContentChanges() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        let songs = ["a", "b", "c", "d"].map { makeSong($0) }
        engine.setContextQueue(
            songs: songs,
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        delegate.contentReasons.removeAll()

        engine.setShuffleActive(true)
        XCTAssertTrue(engine.isShuffleActive)
        engine.setShuffleActive(false)

        XCTAssertFalse(engine.isShuffleActive)
        XCTAssertEqual(delegate.contentReasons, ["shuffle", "unshuffle"])
        XCTAssertEqual(engine.contextSongs.map(\.id), ["a", "b", "c", "d"])
    }

    func testClearingShuffleWithNothingToRestoreIsStillReported() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        // Flagged as shuffled, with no original order to put back.
        engine.markAsShuffled(originalSongs: [])
        delegate.contentReasons.removeAll()

        engine.setShuffleActive(false)

        XCTAssertFalse(engine.isShuffleActive)
        XCTAssertEqual(delegate.contentReasons, ["unshuffle"])
        engine.setShuffleActive(false)
        XCTAssertEqual(delegate.contentReasons, ["unshuffle"])
    }

    func testShuffleChangesNothingWhenThereIsNothingToShuffle() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate

        engine.setShuffleActive(true)
        XCTAssertFalse(engine.isShuffleActive)

        engine.setContextQueue(
            songs: [makeSong("only")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        delegate.contentReasons.removeAll()
        engine.setShuffleActive(true)
        engine.setShuffleActive(false)

        XCTAssertFalse(engine.isShuffleActive)
        XCTAssertTrue(delegate.contentReasons.isEmpty)
    }
}

private final class QueueDelegateSpy: NativeQueueEngineDelegate {
    struct Load {
        let song: QueueSong
        let autoplay: Bool
        let startTime: Double?
    }

    var loads: [Load] = []
    var advances: [(Int, String, QueueAdvanceReason)] = []
    var contentReasons: [String] = []
    var exhaustionCount = 0
    var seekedSongIds: [String] = []

    func queueEngine(
        _ engine: NativeQueueEngine,
        loadSong song: QueueSong,
        autoplay: Bool,
        startTime: Double?
    ) {
        loads.append(Load(song: song, autoplay: autoplay, startTime: startTime))
    }

    func queueEngine(
        _ engine: NativeQueueEngine,
        didAdvanceTo index: Int,
        songId: String,
        reason: QueueAdvanceReason
    ) {
        advances.append((index, songId, reason))
    }

    func queueEngine(_ engine: NativeQueueEngine, didChangeContents reason: String) {
        contentReasons.append(reason)
    }

    func queueEngineDidExhaustQueue(_ engine: NativeQueueEngine) {
        exhaustionCount += 1
    }

    func queueEngine(_ engine: NativeQueueEngine, seekToStart song: QueueSong) {
        seekedSongIds.append(song.id)
    }
}
