import Foundation
import OSLog

struct CachedTrackInfo: Codable, Sendable, Equatable {
    let relativePath: String
    let modificationDate: Date
    let fileSize: Int64
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int?
    let discNumber: Int?
    let duration: TimeInterval
    let artworkID: String?

    init(
        relativePath: String,
        modificationDate: Date,
        fileSize: Int64,
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval,
        artworkID: String? = nil
    ) {
        self.relativePath = relativePath
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration.isFinite && duration >= 0 ? duration : 0
        self.artworkID = artworkID
    }
}

@MainActor
protocol MetadataCacheProtocol: AnyObject {
    func cachedInfo(
        relativePath: String,
        modificationDate: Date,
        fileSize: Int64
    ) -> CachedTrackInfo?
    func store(_ info: CachedTrackInfo)
    func store(contentsOf infos: [CachedTrackInfo])
    func remove(relativePath: String)
    func prune(keeping validPaths: Set<String>)
    func clear()
    func snapshot() -> [String: CachedTrackInfo]
    func waitUntilLoaded() async
    func flush() async
}

@MainActor
final class MetadataCache: MetadataCacheProtocol {
    private var entries: [String: CachedTrackInfo] = [:]
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private let cacheURL: URL
    private let writer = CacheFileWriter()
    private let log = Logger(subsystem: "com.example.musicplayer", category: "cache")

    init(directory: URL? = nil, loadOnInit: Bool = true) {
        let baseDirectory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        self.cacheURL = baseDirectory.appendingPathComponent("metadata-cache-v5.plist")

        if loadOnInit {
            loadGeneration &+= 1
            let generation = loadGeneration
            loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.load(generation: generation)
            }
        }
    }

    func waitUntilLoaded() async {
        if let loadTask {
            await loadTask.value
        }
    }

    func cachedInfo(
        relativePath: String,
        modificationDate: Date,
        fileSize: Int64
    ) -> CachedTrackInfo? {
        guard let entry = entries[relativePath],
              entry.modificationDate == modificationDate,
              entry.fileSize == fileSize else {
            return nil
        }
        return entry
    }

    func store(_ info: CachedTrackInfo) {
        entries[info.relativePath] = info
        isDirty = true
        scheduleSave()
    }

    func store(contentsOf infos: [CachedTrackInfo]) {
        guard !infos.isEmpty else { return }
        for info in infos {
            entries[info.relativePath] = info
        }
        isDirty = true
        scheduleSave()
    }

    func remove(relativePath: String) {
        guard entries.removeValue(forKey: relativePath) != nil else { return }
        isDirty = true
        scheduleSave()
    }

    func prune(keeping validPaths: Set<String>) {
        let stale = entries.keys.filter { !validPaths.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale {
            entries.removeValue(forKey: key)
        }
        isDirty = true
        scheduleSave()
    }

    func clear() {
        loadGeneration &+= 1
        entries.removeAll()
        isDirty = true
        scheduleSave()
    }

    func snapshot() -> [String: CachedTrackInfo] {
        entries
    }

    func flush() async {
        await waitUntilLoaded()
        saveTask?.cancel()
        saveTask = nil
        await saveNow(force: true)
    }

    private func load(generation: Int) async {
        let url = cacheURL
        let decoded = await Task.detached(priority: .utility) { () -> [String: CachedTrackInfo]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListDecoder().decode(
                [String: CachedTrackInfo].self,
                from: data
            )
        }.value

        guard loadGeneration == generation else { return }
        guard let decoded else { return }
        var merged = decoded
        for (key, value) in entries {
            merged[key] = value
        }
        entries = merged
        log.info("Loaded \(merged.count, privacy: .public) cache entries")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.saveNow()
        }
    }

    private func saveNow(force: Bool = false) async {
        guard force || isDirty else { return }
        let snapshot = entries
        isDirty = false

        let success = await writer.write(snapshot, to: cacheURL)
        if !success {
            isDirty = true
            log.error("Cache save error")
        }
    }
}

private actor CacheFileWriter {
    func write(_ entries: [String: CachedTrackInfo], to url: URL) -> Bool {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
