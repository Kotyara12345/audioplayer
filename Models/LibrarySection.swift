import Foundation

struct AlbumSection: Identifiable, Sendable {
    let album: String
    let albumArtist: String
    let tracks: [Track]

    var id: String { "\(album)\u{1F}\(albumArtist)" }
    var title: String { album }
    var subtitle: String? { albumArtist.isEmpty ? nil : albumArtist }
}

struct ArtistSection: Identifiable, Sendable {
    let artist: String
    let tracks: [Track]

    var id: String { artist }
    var title: String { artist }
}
