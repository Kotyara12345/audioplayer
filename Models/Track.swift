import Foundation

struct Track: Identifiable, Hashable, Sendable {
    var id: URL { url }

    let url: URL
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int?
    let discNumber: Int?
    let duration: TimeInterval
    let artworkID: String?
    let isCloudOnly: Bool
    var isHidden: Bool

    init(
        url: URL,
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval,
        artworkID: String? = nil,
        isCloudOnly: Bool = false,
        isHidden: Bool = false
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration.isFinite && duration >= 0 ? duration : 0
        self.artworkID = artworkID
        self.isCloudOnly = isCloudOnly
        self.isHidden = isHidden
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.url == rhs.url
    }
}
