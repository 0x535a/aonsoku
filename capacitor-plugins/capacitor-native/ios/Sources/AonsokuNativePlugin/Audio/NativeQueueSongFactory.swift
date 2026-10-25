import Foundation

extension SongRecord {
    func toQueueSong() -> QueueSong {
        QueueSong(from: [
            "id": id,
            "title": title,
            "artist": artist ?? "",
            "artistId": artistId as Any,
            "album": album ?? "",
            "albumId": albumId as Any,
            "duration": Double(duration),
            "coverArtId": (coverArt ?? albumId) as Any,
            "streamUrl": nativeStreamUrl,
        ])
    }

    var nativeStreamUrl: String {
        var components = URLComponents()
        components.scheme = "aonsoku-media"
        components.host = "stream"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.string ?? "aonsoku-media://stream?id=\(id)"
    }
}

struct NativeCachedAudioFileMetadata: Codable {
    var songId: String
    var fileName: String
    var contentType: String?
    var lastModifiedAt: Double
}
