import AVFoundation
import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class MusicLibraryManager {
    var tracks: [Track] = []
    var isScanning = false
    var lastError: AppError?
    var hiddenCount = 0
    var showHidden = false { didSet { applyFilter() } }
    var viewMode: ViewMode = .songs

    var scanPhase: ScanPhase = .idle
    var scanProgress: Double = 0
    var scanProcessed = 0
    var scanTotal = 0

    @ObservationIgnored private var allTracks: [Track] = []
    @ObservationIgnored private var allTrackIndices: [URL: Int] = [:]
    @ObservationIgnored private var visibleTrackIndices: [URL: Int] = [:]
    private var folderURL: URL?
    @ObservationIgnored private var isAccessingSecurityScope = false
    @ObservationIgnored private var folderObserver: FolderObserver?
    @ObservationIgnored private var folderObservationGeneration = 0
    @ObservationIgnored private var observerDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var didStartRestore = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanSnapshot: [Track]?
    @ObservationIgnored private var producerTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var lastScanFinishedAt: Date?

    @ObservationIgnored private let cache: MetadataCacheProtocol
    @ObservationIgnored private let artworkStore: ArtworkStore
    @ObservationIgnored private let localization: LocalizationManager
    @ObservationIgnored private let bookmarkKey = "MusicFolderBookmark"
    @ObservationIgnored private let excludedKey = "ExcludedTrackPaths"
    @ObservationIgnored private var excludedPaths: Set<String> = []
    @ObservationIgnored private let minimumForegroundRefreshInterval: TimeInterval = 60

    private let log = Logger(subsystem: "com.example.musicplayer", category: "library")

    init(
        localization: LocalizationManager,
        cache: MetadataCacheProtocol = MetadataCache(),
        artworkStore: ArtworkStore = .shared
    ) {
        self.localization = localization
        self.cache = cache
        self.artworkStore = artworkStore
        self.excludedPaths = Set(
            UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
        )
    }

    var hasFolder: Bool {
        folderURL != nil
    }

    func startRestoringIfNeeded() {
        guard !didStartRestore else { return }
        didStartRestore = true
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreFolder()
        }
    }

    // MARK: - Import / clear

    func importFolder(_ url: URL) {
        restoreTask?.cancel()
        restoreTask = nil
        observerDebounceTask?.cancel()
        observerDebounceTask = nil

        let standardizedURL = url.standardizedFileURL
        let isSameFolder = folderURL?.standardizedFileURL.path == standardizedURL.path

        let accessStarted = standardizedURL.startAccessingSecurityScopedResource()
        // A URL inside the app container needs no security scope and may return
        // false even though the folder is readable.
        guard accessStarted || FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
            lastError = .folderAccessDenied
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if accessStarted {
                standardizedURL.stopAccessingSecurityScopedResource()
            }
            lastError = .invalidFolder
            return
        }

        lastError = nil
        pendingRefresh = false
        stopObserving()
        releaseFolderAccess()
        folderURL = standardizedURL
        isAccessingSecurityScope = accessStarted

        if !isSameFolder {
            excludedPaths.removeAll()
            saveExcluded()
            cache.clear()
            resetTrackState()
        }

        saveBookmark(standardizedURL)
        startObserving(folderURL: standardizedURL)
        startBackgroundScan(at: standardizedURL)
    }

    func clearLibrary() {
        restoreTask?.cancel()
        restoreTask = nil
        cancelScan()
        observerDebounceTask?.cancel()
        observerDebounceTask = nil
        stopObserving()
        releaseFolderAccess()
        folderURL = nil

        resetTrackState()
        hiddenCount = 0
        showHidden = false
        isScanning = false
        scanPhase = .idle
        scanProgress = 0
        scanProcessed = 0
        scanTotal = 0
        lastScanFinishedAt = nil
        pendingRefresh = false
        lastError = nil

        excludedPaths.removeAll()
        saveExcluded()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        cache.clear()

        let clearGeneration = scanGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.folderURL == nil,
                  self.scanGeneration == clearGeneration else {
                return
            }
            await self.cache.flush()
            guard self.folderURL == nil,
                  self.scanGeneration == clearGeneration else {
                return
            }
            await self.artworkStore.removeAll()
        }
    }

    func flushCache() async {
        await cache.flush()
    }

    func refreshOnForeground() {
        guard folderURL != nil, !isScanning else { return }
        if let lastScanFinishedAt,
           Date().timeIntervalSince(lastScanFinishedAt) < minimumForegroundRefreshInterval {
            return
        }
        refreshLibrary()
    }

    func refreshLibrary() {
        guard let folderURL, !isScanning else {
            if isScanning {
                pendingRefresh = true
            }
            return
        }
        startBackgroundScan(at: folderURL)
    }

    func scanInBackground() async {
        guard !Task.isCancelled else { return }
        startRestoringIfNeeded()
        if let restoreTask {
            await restoreTask.value
            self.restoreTask = nil
        }
        guard !Task.isCancelled else {
            // Restoration may have started a scan before the task expired.
            cancelScan()
            return
        }
        guard let folderURL else { return }
        if !isScanning {
            startBackgroundScan(at: folderURL)
        }
        while !Task.isCancelled, let scanTask {
            await scanTask.value
            if !isScanning {
                break
            }
        }
        if Task.isCancelled {
            cancelScan()
        }
    }

    func cancelScan() {
        restoreScanSnapshot()
        scanGeneration &+= 1
        producerTask?.cancel()
        producerTask = nil
        scanTask?.cancel()
        scanTask = nil
        pendingRefresh = false
        isScanning = false
        scanPhase = .idle
        scanProgress = 0
        scanProcessed = 0
        scanTotal = 0
    }

    // MARK: - Grouping

    var albumSections: [AlbumSection] {
        let unknownAlbum = localization.localized("player.unknown_album")
        let grouped = Dictionary(grouping: tracks) { track in
            AlbumKey(
                album: track.album.isEmpty ? unknownAlbum : track.album,
                artist: track.albumArtist.isEmpty ? track.artist : track.albumArtist
            )
        }
        return grouped.map { key, tracks in
            AlbumSection(
                album: key.album,
                albumArtist: key.artist,
                tracks: tracks.sorted(by: Self.albumTrackOrder)
            )
        }
        .sorted { lhs, rhs in
            let albumComparison = lhs.album.localizedCaseInsensitiveCompare(rhs.album)
            if albumComparison == .orderedSame {
                return lhs.albumArtist.localizedCaseInsensitiveCompare(rhs.albumArtist)
                    == .orderedAscending
            }
            return albumComparison == .orderedAscending
        }
    }

    var artistSections: [ArtistSection] {
        let unknownArtist = localization.localized("player.unknown_artist")
        let grouped = Dictionary(grouping: tracks) { track in
            let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            return artist.isEmpty ? unknownArtist : artist
        }
        return grouped.map { artist, tracks in
            ArtistSection(
                artist: artist,
                tracks: tracks.sorted(by: Self.artistTrackOrder)
            )
        }
        .sorted {
            $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
        }
    }

    // MARK: - Bookmark

    private func saveBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            log.error("Bookmark save error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreFolder() async {
        guard folderURL == nil else { return }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard folderURL == nil, !Task.isCancelled else { return }

            let accessStarted = url.startAccessingSecurityScopedResource()
            guard accessStarted || FileManager.default.isReadableFile(atPath: url.path) else {
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                lastError = .folderAccessDenied
                return
            }
            guard !Task.isCancelled else {
                if accessStarted {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                if accessStarted {
                    url.stopAccessingSecurityScopedResource()
                }
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                lastError = .invalidFolder
                return
            }

            folderURL = url.standardizedFileURL
            isAccessingSecurityScope = accessStarted
            if isStale {
                saveBookmark(url)
            }
            startObserving(folderURL: url)
            startBackgroundScan(at: url)
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            log.error("Bookmark restore error: \(error.localizedDescription, privacy: .public)")
            lastError = .invalidFolder
        }
    }

    private func startObserving(folderURL: URL) {
        stopObserving()
        let generation = folderObservationGeneration
        folderObserver = FolderObserver(url: folderURL) { [weak self] movedURL in
            guard let self, self.folderObservationGeneration == generation else { return }
            if let movedURL {
                self.folderMoved(to: movedURL)
            } else {
                self.scheduleObservedRefresh()
            }
        }
    }

    private func stopObserving() {
        folderObservationGeneration &+= 1
        folderObserver?.stop()
        folderObserver = nil
    }

    /// Balances only successful security-scoped access starts. URLs inside the
    /// app container are readable without acquiring a security scope.
    private func releaseFolderAccess() {
        guard isAccessingSecurityScope, let folderURL else {
            isAccessingSecurityScope = false
            return
        }
        folderURL.stopAccessingSecurityScopedResource()
        isAccessingSecurityScope = false
    }

    private func folderMoved(to newURL: URL) {
        guard let currentURL = folderURL else { return }
        let standardizedURL = newURL.standardizedFileURL
        guard standardizedURL.path != currentURL.standardizedFileURL.path else {
            scheduleObservedRefresh()
            return
        }

        let accessStarted = standardizedURL.startAccessingSecurityScopedResource()
        guard accessStarted || FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
            lastError = .folderAccessDenied
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if accessStarted {
                standardizedURL.stopAccessingSecurityScopedResource()
            }
            lastError = .invalidFolder
            return
        }

        releaseFolderAccess()
        folderURL = standardizedURL
        isAccessingSecurityScope = accessStarted
        saveBookmark(standardizedURL)
        observerDebounceTask?.cancel()
        observerDebounceTask = nil
        startBackgroundScan(at: standardizedURL)
    }

    private func scheduleObservedRefresh() {
        observerDebounceTask?.cancel()
        observerDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if self.isScanning {
                self.pendingRefresh = true
            } else {
                self.refreshLibrary()
            }
        }
    }

    // MARK: - Scan

    private func startBackgroundScan(at url: URL) {
        cancelScan()
        scanSnapshot = allTracks
        scanGeneration &+= 1
        let generation = scanGeneration
        let standardizedURL = url.standardizedFileURL

        lastError = nil
        lastScanFinishedAt = nil
        pendingRefresh = false
        isScanning = true
        scanPhase = .collecting
        scanProgress = 0
        scanProcessed = 0
        scanTotal = 0

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runScan(at: standardizedURL, generation: generation)
        }
    }

    private func runScan(at url: URL, generation: Int) async {
        await cache.waitUntilLoaded()
        guard generation == scanGeneration, !Task.isCancelled else { return }

        let folderPath = url.standardizedFileURL.path
        let cacheSnapshot = cache.snapshot()
        let existingArtworkIDs = await artworkStore.existingIDs()
        guard generation == scanGeneration, !Task.isCancelled else { return }

        let store = artworkStore
        let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let producer = Task.detached(priority: .utility) {
            await Self.runScanPipeline(
                folderURL: url,
                folderPath: folderPath,
                cacheSnapshot: cacheSnapshot,
                existingArtworkIDs: existingArtworkIDs,
                artworkStore: store,
                continuation: continuation
            )
        }
        producerTask = producer

        var didFail = false
        for await event in stream {
            guard generation == scanGeneration, !Task.isCancelled else { break }
            switch event {
            case .phase(let phase):
                scanPhase = phase
            case .progress(let processed, let total):
                scanProcessed = processed
                scanTotal = total
                scanProgress = computeProgress(processed: processed, total: total)
            case .batch(let batch):
                cache.store(contentsOf: batch.cacheEntries)
                mergeBatch(batch.tracks)
            case .finished(let result):
                cache.store(contentsOf: result.cacheEntries)
                cache.prune(keeping: result.validPaths)
                finalize(result: result)
                scanSnapshot = nil
                let store = artworkStore
                let currentGeneration = generation
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == currentGeneration else { return }
                    await store.prune(keeping: result.artworkIDs)
                }
            case .failed(let error):
                lastError = error
                didFail = true
            case .cancelled:
                break
            }
        }

        await producer.value

        guard generation == scanGeneration, !Task.isCancelled else { return }
        isScanning = false
        scanPhase = .idle
        producerTask = nil

        if didFail {
            restoreScanSnapshot()
            scanProgress = 0
            pendingRefresh = false
        } else {
            scanProgress = 1
            lastScanFinishedAt = Date()
            if pendingRefresh {
                pendingRefresh = false
                refreshLibrary()
            }
        }
    }

    private func computeProgress(processed: Int, total: Int) -> Double {
        guard total > 0 else { return 0.1 }
        let base = min(max(Double(processed) / Double(total), 0), 1)
        return 0.1 + 0.85 * base
    }

    private func mergeBatch(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }

        for incoming in newTracks {
            var track = incoming
            track.isHidden = excludedPaths.contains(relativePath(for: track.url))

            if let index = allTrackIndices[track.url] {
                let wasHidden = allTracks[index].isHidden
                allTracks[index] = track
                if wasHidden != track.isHidden {
                    hiddenCount += track.isHidden ? 1 : -1
                }
                if let visibleIndex = visibleTrackIndices[track.url] {
                    tracks[visibleIndex] = track
                }
            } else {
                allTrackIndices[track.url] = allTracks.count
                allTracks.append(track)
                if track.isHidden {
                    hiddenCount += 1
                }
                if !track.isHidden || showHidden {
                    visibleTrackIndices[track.url] = tracks.count
                    tracks.append(track)
                }
            }
        }
    }

    private func finalize(result: ScanResult) {
        allTracks = result.tracks.map { track in
            var track = track
            track.isHidden = excludedPaths.contains(relativePath(for: track.url))
            return track
        }
        allTracks.sort {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        rebuildAllIndices()
        applyFilter()
    }

    private func restoreScanSnapshot() {
        guard let snapshot = scanSnapshot else { return }
        scanSnapshot = nil
        allTracks = snapshot
        rebuildAllIndices()
        applyFilter()
    }

    private func applyFilter() {
        tracks = showHidden ? allTracks : allTracks.filter { !$0.isHidden }
        rebuildVisibleIndices()
        hiddenCount = allTracks.lazy.filter(\.isHidden).count
    }

    private func rebuildAllIndices() {
        allTrackIndices.removeAll(keepingCapacity: true)
        allTrackIndices.reserveCapacity(allTracks.count)
        for (index, track) in allTracks.enumerated() {
            allTrackIndices[track.url] = index
        }
    }

    private func rebuildVisibleIndices() {
        visibleTrackIndices.removeAll(keepingCapacity: true)
        visibleTrackIndices.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            visibleTrackIndices[track.url] = index
        }
    }

    private func resetTrackState() {
        scanSnapshot = nil
        allTracks = []
        tracks = []
        allTrackIndices = [:]
        visibleTrackIndices = [:]
        hiddenCount = 0
    }

    // MARK: - Pipeline

    nonisolated private static func runScanPipeline(
        folderURL: URL,
        folderPath: String,
        cacheSnapshot: [String: CachedTrackInfo],
        existingArtworkIDs: Set<String>,
        artworkStore: ArtworkStore,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        if Task.isCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        guard let audioURLs = collectAudioFiles(in: folderURL) else {
            if Task.isCancelled {
                continuation.yield(.cancelled)
            } else {
                continuation.yield(.failed(.invalidFolder))
            }
            continuation.finish()
            return
        }
        if Task.isCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }
        continuation.yield(.phase(.reading))

        guard !audioURLs.isEmpty else {
            continuation.yield(.finished(ScanResult(
                tracks: [],
                cacheEntries: [],
                validPaths: [],
                artworkIDs: []
            )))
            continuation.finish()
            return
        }

        var resultTracks: [Track] = []
        var cacheEntries: [CachedTrackInfo] = []
        var validPaths: Set<String> = []
        var artworkIDs: Set<String> = []
        var batchTracks: [Track] = []
        var batchEntries: [CachedTrackInfo] = []
        var processed = 0
        let total = audioURLs.count
        let batchSize = 25
        let progressStep = 10

        func flushBatch() {
            guard !batchTracks.isEmpty || !batchEntries.isEmpty else { return }
            continuation.yield(.batch(ScanBatch(
                tracks: batchTracks,
                cacheEntries: batchEntries
            )))
            batchTracks.removeAll(keepingCapacity: true)
            batchEntries.removeAll(keepingCapacity: true)
        }

        var wasCancelled = false
        await withTaskGroup(of: ProcessedFile.self) { group in
            var iterator = audioURLs.makeIterator()
            for _ in 0..<min(4, audioURLs.count) {
                guard let url = iterator.next() else { break }
                group.addTask {
                    await processFile(
                        url,
                        basePath: folderPath,
                        cacheSnapshot: cacheSnapshot,
                        existingArtworkIDs: existingArtworkIDs,
                        artworkStore: artworkStore
                    )
                }
            }

            for await file in group {
                if Task.isCancelled {
                    wasCancelled = true
                    group.cancelAll()
                    break
                }
                if let track = file.track {
                    resultTracks.append(track)
                    batchTracks.append(track)
                    validPaths.insert(file.relativePath)
                    if let artworkID = track.artworkID {
                        artworkIDs.insert(artworkID)
                    }
                }
                if let cacheEntry = file.cacheEntry {
                    cacheEntries.append(cacheEntry)
                    batchEntries.append(cacheEntry)
                }

                processed += 1
                if processed % progressStep == 0 || processed == total {
                    continuation.yield(.progress(processed: processed, total: total))
                }
                if batchTracks.count >= batchSize || batchEntries.count >= batchSize {
                    flushBatch()
                }

                if let next = iterator.next() {
                    group.addTask {
                        await processFile(
                            next,
                            basePath: folderPath,
                            cacheSnapshot: cacheSnapshot,
                            existingArtworkIDs: existingArtworkIDs,
                            artworkStore: artworkStore
                        )
                    }
                }
            }
        }

        if wasCancelled || Task.isCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        flushBatch()
        continuation.yield(.finished(ScanResult(
            tracks: resultTracks,
            cacheEntries: cacheEntries,
            validPaths: validPaths,
            artworkIDs: artworkIDs
        )))
        continuation.finish()
    }

    nonisolated private static func processFile(
        _ fileURL: URL,
        basePath: String,
        cacheSnapshot: [String: CachedTrackInfo],
        existingArtworkIDs: Set<String>,
        artworkStore: ArtworkStore
    ) async -> ProcessedFile {
        let relativePath = relativePath(fileURL, basePath: basePath)
        guard let attributes = fileAttributes(for: fileURL) else {
            return ProcessedFile(
                track: nil,
                cacheEntry: nil,
                relativePath: relativePath
            )
        }

        if let cached = cacheSnapshot[relativePath],
           cached.modificationDate == attributes.modificationDate,
           cached.fileSize == attributes.fileSize {
            let cachedArtworkID = cached.artworkID
            let artworkExists = cachedArtworkID.map(existingArtworkIDs.contains) ?? true
            if artworkExists || attributes.isCloudOnly {
                let artworkID = artworkExists ? cachedArtworkID : nil
                return ProcessedFile(
                    track: Track(
                        url: fileURL,
                        title: cached.title,
                        artist: cached.artist,
                        album: cached.album,
                        albumArtist: cached.albumArtist,
                        trackNumber: cached.trackNumber,
                        discNumber: cached.discNumber,
                        duration: cached.duration,
                        artworkID: artworkID,
                        isCloudOnly: attributes.isCloudOnly
                    ),
                    cacheEntry: nil,
                    relativePath: relativePath
                )
            }
        }

        if attributes.isCloudOnly {
            return ProcessedFile(
                track: Track(
                    url: fileURL,
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    artist: "",
                    album: "",
                    albumArtist: "",
                    duration: 0,
                    artworkID: nil,
                    isCloudOnly: true
                ),
                cacheEntry: nil,
                relativePath: relativePath
            )
        }

        let metadata = await loadTrackMetadata(for: fileURL)
        var artworkID: String?
        if let artworkData = metadata.artworkData,
           let prepared = ArtworkCompressor.prepareForStorage(artworkData) {
            artworkID = await artworkStore.store(prepared)
        }

        let track = Track(
            url: fileURL,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            albumArtist: metadata.albumArtist,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            artworkID: artworkID,
            isCloudOnly: false
        )

        let cacheEntry: CachedTrackInfo?
        if metadata.didReadMetadata {
            cacheEntry = CachedTrackInfo(
                relativePath: relativePath,
                modificationDate: attributes.modificationDate,
                fileSize: attributes.fileSize,
                title: track.title,
                artist: track.artist,
                album: track.album,
                albumArtist: track.albumArtist,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber,
                duration: track.duration,
                artworkID: track.artworkID
            )
        } else {
            cacheEntry = nil
        }

        return ProcessedFile(
            track: track,
            cacheEntry: cacheEntry,
            relativePath: relativePath
        )
    }

    nonisolated private static func collectAudioFiles(in directory: URL) -> [URL]? {
        var files: [URL] = []
        let extensions: Set<String> = [
            "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif",
            "flac", "alac", "caf"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let file as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            if extensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        return files
    }

    nonisolated private static func fileAttributes(for url: URL) -> FileAttributes? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate,
        let fileSize = values.fileSize else {
            return nil
        }

        let isCloudOnly: Bool
        if values.isUbiquitousItem == true {
            let status = values.ubiquitousItemDownloadingStatus
            isCloudOnly = status != .current && status != .downloaded
        } else {
            isCloudOnly = false
        }

        return FileAttributes(
            modificationDate: modificationDate,
            fileSize: Int64(fileSize),
            isCloudOnly: isCloudOnly
        )
    }

    nonisolated private static func loadTrackMetadata(for url: URL) async -> LoadedMetadata {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var albumArtist = ""
        var trackNumber: Int?
        var discNumber: Int?
        var duration: TimeInterval = 0
        var artworkData: Data?
        var didReadMetadata = false

        do {
            let metadata = try await asset.load(.commonMetadata)
            for item in metadata {
                if item.commonKey == .commonKeyTitle {
                    title = (try? await item.load(.stringValue)) ?? title
                } else if item.commonKey == .commonKeyArtist {
                    artist = (try? await item.load(.stringValue)) ?? artist
                } else if item.commonKey == .commonKeyAlbumName {
                    album = (try? await item.load(.stringValue)) ?? album
                } else if item.commonKey == .commonKeyArtwork {
                    artworkData = try? await item.load(.dataValue)
                }

                let key = ((item.key as? String) ?? "").lowercased()
                let identifier = (item.identifier?.rawValue ?? "").lowercased()

                if key == "aart"
                    || key == "tpe2"
                    || identifier.contains("albumartist") {
                    albumArtist = (try? await item.load(.stringValue)) ?? albumArtist
                }
                if key == "trkn"
                    || key == "trck"
                    || identifier.contains("tracknumber")
                    || identifier.contains("trck") {
                    trackNumber = await parseNumber(from: item)
                }
                if key == "disk"
                    || key == "tpos"
                    || identifier.contains("discnumber")
                    || identifier.contains("partofset")
                    || identifier.contains("tpos") {
                    discNumber = await parseNumber(from: item)
                }
            }

            if let cmDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(cmDuration)
                duration = seconds.isFinite && seconds >= 0 ? seconds : 0
            }
            didReadMetadata = true
        } catch {
            Logger(subsystem: "com.example.musicplayer", category: "metadata")
                .error(
                    "Metadata error for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
        }

        return LoadedMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            artworkData: artworkData,
            didReadMetadata: didReadMetadata
        )
    }

    nonisolated private static func parseNumber(from item: AVMetadataItem) async -> Int? {
        if let string = try? await item.load(.stringValue) {
            let prefix = string.split(separator: "/").first.map(String.init) ?? string
            if let value = Int(prefix.trimmingCharacters(in: .whitespaces)), value > 0 {
                return value
            }
        }
        if let data = try? await item.load(.dataValue), data.count >= 4 {
            let bytes = [UInt8](data)
            let value = Int(bytes[2]) << 8 | Int(bytes[3])
            if value > 0 { return value }
        }
        return nil
    }

    nonisolated private static func relativePath(_ url: URL, basePath: String) -> String {
        let standardizedBase = URL(fileURLWithPath: basePath, isDirectory: true)
            .standardizedFileURL
            .path
        let standardizedPath = url.standardizedFileURL.path
        let prefix = standardizedBase.hasSuffix("/") ? standardizedBase : standardizedBase + "/"

        if standardizedPath.hasPrefix(prefix) {
            return String(standardizedPath.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    // MARK: - Sorting

    nonisolated private static func albumTrackOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsDisc = lhs.discNumber ?? 0
        let rhsDisc = rhs.discNumber ?? 0
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

        let lhsTrack = lhs.trackNumber ?? Int.max
        let rhsTrack = rhs.trackNumber ?? Int.max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    nonisolated private static func artistTrackOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let albumComparison = lhs.album.localizedCaseInsensitiveCompare(rhs.album)
        if albumComparison != .orderedSame {
            return albumComparison == .orderedAscending
        }
        return albumTrackOrder(lhs, rhs)
    }

    // MARK: - Filter / hide

    private func relativePath(for url: URL) -> String {
        guard let folderURL else { return url.lastPathComponent }
        return Self.relativePath(url, basePath: folderURL.standardizedFileURL.path)
    }

    func hide(track: Track) {
        excludedPaths.insert(relativePath(for: track.url))
        saveExcluded()
        if let index = allTracks.firstIndex(where: { $0.url == track.url }) {
            allTracks[index].isHidden = true
        }
        applyFilter()
    }

    func unhide(track: Track) {
        excludedPaths.remove(relativePath(for: track.url))
        saveExcluded()
        if let index = allTracks.firstIndex(where: { $0.url == track.url }) {
            allTracks[index].isHidden = false
        }
        applyFilter()
    }

    func restoreAllHidden() {
        excludedPaths.removeAll()
        saveExcluded()
        for index in allTracks.indices {
            allTracks[index].isHidden = false
        }
        applyFilter()
    }

    private func saveExcluded() {
        UserDefaults.standard.set(excludedPaths.sorted(), forKey: excludedKey)
    }
}

private struct AlbumKey: Hashable, Sendable {
    let album: String
    let artist: String
}

private struct FileAttributes: Sendable {
    let modificationDate: Date
    let fileSize: Int64
    let isCloudOnly: Bool
}

private struct ProcessedFile: Sendable {
    let track: Track?
    let cacheEntry: CachedTrackInfo?
    let relativePath: String
}

private struct LoadedMetadata: Sendable {
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int?
    let discNumber: Int?
    let duration: TimeInterval
    let artworkData: Data?
    let didReadMetadata: Bool
}
