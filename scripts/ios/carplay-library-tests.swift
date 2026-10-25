import Foundation
import GRDB

// Isolated database and credentials: no app database, Keychain or external server access.
public struct ServerCredentials {
    let serverUrl: String
    let username: String
    let password: String
    let authType: String
    let protocolVersion: String
    let serverType: String
    let fallbackUrl: String?
    public init(
        serverUrl: String, username: String = "fixture", password: String = "fixture",
        authType: String = "token", protocolVersion: String = "1.16.0",
        serverType: String = "subsonic", fallbackUrl: String? = nil
    ) {
        self.serverUrl = serverUrl
        self.username = username
        self.password = password
        self.authType = authType
        self.protocolVersion = protocolVersion
        self.serverType = serverType
        self.fallbackUrl = fallbackUrl
    }
}

enum KeychainManager { static func retrieve() -> ServerCredentials? { nil } }
final class DatabaseManager {
    static let shared = DatabaseManager()
    static let normalizeFunction = DatabaseFunction("normalize", argumentCount: 1, pure: true) { args in
        String.fromDatabaseValue(args[0])?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
    let directory: URL
    let dbPool: DatabasePool
    private init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPool = try! DatabasePool(path: directory.appendingPathComponent("fixture.sqlite").path)
        var migrator = DatabaseMigrator()
        Migrations.registerAll(&migrator)
        try! migrator.migrate(dbPool)
    }
}

final class FixtureURLProtocol: URLProtocol {
    static var requests = 0
    static var status = 503
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct CarPlayLibraryTests {
    static func main() async throws {
        let database = DatabaseManager.shared
        defer { try? FileManager.default.removeItem(at: database.directory) }
        let db = database.dbPool
        let cache = database.directory.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO artist (id, name, albumCount) VALUES ('artist', 'Artist', 1)")
            try db.execute(
                sql:
                    "INSERT INTO album (id, name, artist, artistId, songCount, duration) VALUES ('album', 'Album', 'Artist', 'artist', 46, 460)"
            )
            for i in 0..<46 {
                let id = String(format: "song-%02d", i)
                try db.execute(
                    sql:
                        "INSERT INTO song (id, title, artist, albumId, track, duration, starredAt, playedAt) VALUES (?, ?, 'Artist', 'album', ?, 10, ?, ?)",
                    arguments: [id, id, i, i < 3 ? 100 : nil, i == 3 ? 100 : nil])
            }
            try db.execute(
                sql: "INSERT INTO playHistory (songJson, playedAt) VALUES (?, 200), (?, 190)",
                arguments: ["{\"id\":\"song-01\"}", "{\"id\":\"song-01\"}"])
            try db.execute(
                sql:
                    "INSERT INTO playlistDetail (id, name, songCount, duration, isPublic, entriesJson) VALUES ('playlist', 'Playlist', 3, 30, 0, ?)",
                arguments: ["[{\"id\":\"song-02\"},{\"id\":\"song-01\"},{\"id\":\"song-02\"}]"])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let http = SubsonicHTTPClient(session: URLSession(configuration: config))
        let provider = CarPlayLibraryProvider(
            db: db, credentials: { ServerCredentials(serverUrl: "https://fixture.invalid") },
            cacheDirectories: [cache], http: http)
        let first = try await provider.page(.album("album"))
        precondition(first.items.count == 40 && first.nextOffset == 40)
        let second = try await provider.page(.album("album"), offset: 40)
        precondition(second.items.count == 6 && second.nextOffset == nil)
        precondition(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        let queue = try await provider.selection(.album("album"), pageOffset: 40, index: 43, expectedId: "song-43")
        precondition(queue.count == 46 && queue[43].id == "song-43")
        let favorites = try await provider.page(.favorites)
        precondition(favorites.items.map(\.id) == ["song-00", "song-01", "song-02"])
        let recent = try await provider.page(.recent)
        precondition(recent.items.map(\.id) == ["song-01", "song-03"])
        let playlist = try await provider.page(.playlist("playlist"))
        precondition(playlist.items.map(\.id) == ["song-02", "song-01", "song-02"])
        let duplicates = try await provider.selection(
            .playlist("playlist"), pageOffset: 0, index: 2, expectedId: "song-02")
        precondition(duplicates.map(\.id) == ["song-02", "song-01", "song-02"])
        do {
            _ = try await provider.selection(.album("album"), pageOffset: 0, index: 1, expectedId: "song-00")
            preconditionFailure("Stale selection was accepted")
        } catch CarPlayError.staleSelection {}
        let anonymous = CarPlayLibraryProvider(db: db, credentials: { nil }, cacheDirectories: [cache], http: http)
        do {
            _ = try await anonymous.page(.albums)
            preconditionFailure("Unauthenticated query succeeded")
        } catch CarPlayError.notLoggedIn {}
        do {
            _ = try await provider.page(.playlist("uncached"))
            preconditionFailure("Network failure was hidden")
        } catch SubsonicHTTPError.httpError(let status, _) { precondition(status == 503) }
        precondition(FixtureURLProtocol.requests == 1)
        FixtureURLProtocol.status = 200
        FixtureURLProtocol.body = Data(
            """
            {"subsonic-response":{"status":"ok","playlist":{"id":"fetched","name":"Fetched","entry":[
            {"id":"new-song","title":"New song","duration":10},
            {"id":"new-song","title":"New song","duration":10}]}}}
            """.utf8)
        let fetched = try await provider.page(.playlist("fetched"))
        precondition(fetched.items.map(\.id) == ["new-song", "new-song"])
        _ = try await provider.page(.playlist("fetched"))
        precondition(FixtureURLProtocol.requests == 2)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.page(.albums)
        }
        do {
            _ = try await canceled.value
            preconditionFailure("Canceled query returned content")
        } catch is CancellationError {}
        var identityReads = 0
        let changedAccount = CarPlayLibraryProvider(
            db: db,
            credentials: {
                identityReads += 1
                return ServerCredentials(
                    serverUrl: identityReads == 1 ? "https://first.invalid" : "https://second.invalid")
            }, cacheDirectories: [cache], http: http)
        do {
            _ = try await changedAccount.page(.albums)
            preconditionFailure("Stale account query returned content")
        } catch is CancellationError {}

        for (index, fileName, bytes, metadata) in [
            (0, "complete.mp3", 5, true), (1, "partial.tmp", 5, false),
            (2, "empty.mp3", 0, true), (3, "../outside.mp3", 5, true),
        ] {
            let id = String(format: "song-%02d", index)
            let file = cache.appendingPathComponent(fileName)
            try Data(repeating: 0, count: bytes).write(to: file)
            if metadata {
                let data = try JSONEncoder().encode(
                    NativeCachedAudioFileMetadata(
                        songId: id, fileName: fileName, contentType: "audio/mpeg", lastModifiedAt: 0))
                try data.write(to: cache.appendingPathComponent("\(AudioCacheUtils.cacheId(for: id)).json"))
            }
            try CacheMetaRepository(db: db).upsert(
                CacheMetaRecord(
                    key: "audio:\(id)", id: id, type: "audio", source: "explicit", triggersJson: nil,
                    coverSize: nil, sizeBytes: bytes, cachedAt: 0, lastAccessedAt: 0, removedFromServer: nil))
        }
        let downloaded = try await provider.page(.downloaded)
        precondition(downloaded.items.map(\.id) == ["song-00"])
        try Data([0]).write(to: cache.appendingPathComponent("complete.mp3"))
        let truncated = try await provider.page(.downloaded)
        precondition(truncated.items.isEmpty)
        try FileManager.default.removeItem(at: cache.appendingPathComponent("complete.mp3"))
        let deleted = try await provider.page(.downloaded)
        precondition(deleted.items.isEmpty)

        let engine = NativeQueueEngine()
        engine.setContextQueue(songs: duplicates, currentIndex: 1, autoplay: false, startTime: nil)
        engine.addToUserQueue(songs: duplicates, position: "last")
        engine.playUserQueueAtIndex(2)
        precondition(engine.isInUserQueue && engine.userQueue.count == 1)
        precondition(engine.playedUserQueueHistory.count == 2 && engine.currentIndex == 1)
        precondition(engine.currentSong?.id == "song-02")
        engine.skipToPrevious(currentTime: 0)
        precondition(engine.currentSong?.id == "song-01")

        var successes = 0
        var failures = 0
        let request = NativePlaybackRequest(
            options: ["position": 3.5, "enabled": true],
            success: { _ in successes += 1 }, failure: { _, _, _ in failures += 1 })
        precondition(request.getDouble("position") == 3.5 && request.getBool("enabled") == true)
        request.resolve()
        request.reject("late failure")
        request.resolve()
        precondition(successes == 1 && failures == 0)
        print(
            "CarPlay native library: paging, context, duplicates, favorites, history, offline integrity, authentication, network errors and request completion passed"
        )
    }
}
