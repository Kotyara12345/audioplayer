import Foundation
import Observation

@Observable
@MainActor
final class RecentlyPlayedStore {
    private(set) var recentURLs: [URL] = []

    @ObservationIgnored private let key = "RecentlyPlayedURLs"
    @ObservationIgnored private let limit = 20
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.stringArray(forKey: key) {
            recentURLs = raw.compactMap(URL.init(string:))
        }
    }

    func record(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        recentURLs.insert(url, at: 0)
        if recentURLs.count > limit {
            recentURLs = Array(recentURLs.prefix(limit))
        }
        defaults.set(recentURLs.map(\.absoluteString), forKey: key)
    }

    func tracks(from library: [Track]) -> [Track] {
        var byURL: [URL: Track] = [:]
        byURL.reserveCapacity(library.count)
        for track in library {
            byURL[track.url] = track
        }
        return recentURLs.compactMap { byURL[$0] }
    }
}
