import Foundation
import Testing
import UIKit
@testable import MusicPlayer

private enum TestError: Error {
    case failed
}

@MainActor
private final class FakeAudioPlayer: AudioPlayerProtocol {
    var duration: TimeInterval = 100
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var onPlaybackFinished: (@MainActor @Sendable () -> Void)?

    var prepareSucceeds = true
    var playSucceeds = true

    func prepareToPlay() -> Bool {
        prepareSucceeds
    }

    @discardableResult
    func play() -> Bool {
        isPlaying = playSucceeds
        return playSucceeds
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
    }

    func finish() {
        isPlaying = false
        onPlaybackFinished?()
    }
}

@MainActor
private final class FakeAudioSession: AudioSessionControlling {
    var configureError: Error?
    var activationError: Error?

    func configurePlayback() throws {
        if let configureError {
            throw configureError
        }
    }

    func setActive(_ active: Bool) throws {
        if active, let activationError {
            throw activationError
        }
    }
}

@MainActor
private final class FakePlayerFactory {
    private let failingNames: Set<String>
    private(set) var players: [String: FakeAudioPlayer] = [:]
    var playSucceeds = true

    init(failingNames: Set<String> = []) {
        self.failingNames = failingNames
    }

    func make(_ url: URL) throws -> any AudioPlayerProtocol {
        let name = url.deletingPathExtension().lastPathComponent
        if failingNames.contains(name) {
            throw TestError.failed
        }
        let player = FakeAudioPlayer()
        player.playSucceeds = playSucceeds
        players[name] = player
        return player
    }

    func player(named name: String) -> FakeAudioPlayer? {
        players[name]
    }
}

@Suite("Player queue logic", .serialized)
@MainActor
struct PlayerQueueTests {
    private func makeTrack(_ name: String, cloudOnly: Bool = false) -> Track {
        Track(
            url: URL(fileURLWithPath: "/tmp/\(name).mp3"),
            title: name,
            artist: "",
            album: "",
            albumArtist: "",
            duration: 100,
            artworkID: nil,
            isCloudOnly: cloudOnly
        )
    }

    private func makeEngine(
        failingNames: Set<String> = [],
        configureError: Error? = nil
    ) -> (PlayerEngine, FakePlayerFactory, FakeAudioSession, UserDefaults) {
        let suiteName = "MusicPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let session = FakeAudioSession()
        session.configureError = configureError
        let factory = FakePlayerFactory(failingNames: failingNames)
        let recent = RecentlyPlayedStore(defaults: defaults)
        let engine = PlayerEngine(
            recentStore: recent,
            audioSession: session,
            userDefaults: defaults
        ) { url in
            try factory.make(url)
        }
        return (engine, factory, session, defaults)
    }

    @Test func shuffleKeepsCurrentFirst() {
        let (engine, _, _, _) = makeEngine()
        defer { engine.shutdown() }
        let tracks = (1...5).map { makeTrack("t\($0)") }

        engine.play(tracks: tracks, startAt: 2)
        #expect(engine.currentTrack?.title == "t3")
        #expect(engine.isPlaying)

        engine.toggleShuffle()
        #expect(engine.isShuffled)
        #expect(engine.currentTrack?.title == "t3")
        #expect(engine.currentQueue.first?.title == "t3")

        engine.toggleShuffle()
        #expect(!engine.isShuffled)
        #expect(engine.currentTrack?.title == "t3")
        #expect(engine.currentQueue.map(\.title) == tracks.map(\.title))
    }

    @Test func repeatAllWraps() {
        let (engine, _, _, _) = makeEngine()
        defer { engine.shutdown() }
        let a = makeTrack("a")
        let b = makeTrack("b")

        engine.play(tracks: [a, b], startAt: 1)
        engine.repeatMode = .all
        engine.next()

        #expect(engine.currentTrack?.title == "a")
        #expect(engine.isPlaying)
    }

    @Test func nextAtEndWithoutRepeatPauses() {
        let (engine, _, _, _) = makeEngine()
        defer { engine.shutdown() }
        engine.play(tracks: [makeTrack("only")], startAt: 0)
        engine.repeatMode = .off

        engine.next()

        #expect(engine.isPlaying == false)
        #expect(engine.currentTime == 0)
    }

    @Test func playNextInsertsAfterCurrent() {
        let (engine, _, _, _) = makeEngine()
        defer { engine.shutdown() }
        let a = makeTrack("a")
        let b = makeTrack("b")
        let c = makeTrack("c")

        engine.play(tracks: [a, b], startAt: 0)
        engine.playNext(track: c)
        engine.next()

        #expect(engine.currentTrack?.title == "c")
    }

    @Test func failedTrackIsSkipped() {
        let (engine, _, _, _) = makeEngine(failingNames: ["b"])
        defer { engine.shutdown() }
        let tracks = [makeTrack("a"), makeTrack("b"), makeTrack("c")]

        engine.play(tracks: tracks, startAt: 1)

        #expect(engine.currentTrack?.title == "c")
        #expect(engine.isPlaying)
        #expect(engine.currentQueueIndex == 2)
        #expect(engine.lastError == nil)
    }

    @Test func cloudOnlyTrackIsNotPlayed() {
        let (engine, factory, _, _) = makeEngine()
        defer { engine.shutdown() }
        let track = makeTrack("cloud", cloudOnly: true)

        engine.play(track: track)

        #expect(engine.isPlaying == false)
        #expect(engine.lastError == .cloudFileNotDownloaded(filename: "cloud"))
        #expect(factory.players.isEmpty)
    }

    @Test func audioSessionFailureStopsPlayback() {
        let (engine, factory, session, _) = makeEngine()
        defer { engine.shutdown() }
        session.activationError = TestError.failed
        factory.playSucceeds = false

        engine.play(track: makeTrack("a"))

        #expect(engine.isPlaying == false)
        #expect(engine.lastError == .audioSessionFailed)
    }

    @Test func audioSessionFailureStillPlaysWithDefaultCategory() {
        let (engine, _, session, _) = makeEngine()
        defer { engine.shutdown() }
        session.activationError = TestError.failed

        engine.play(track: makeTrack("a"))

        #expect(engine.isPlaying)
        #expect(engine.lastError == nil)
    }

    @Test func audioSessionIsConfiguredOnPlaybackNotAtLaunch() {
        let (engine, factory, _, _) = makeEngine(configureError: TestError.failed)
        defer { engine.shutdown() }
        #expect(engine.lastError == nil)
        factory.playSucceeds = false

        engine.play(track: makeTrack("a"))
        #expect(engine.lastError == .audioSessionFailed)
    }

    @Test func audioSessionFailureDoesNotLoadEveryTrack() {
        let (engine, factory, session, _) = makeEngine()
        defer { engine.shutdown() }
        session.activationError = TestError.failed
        factory.playSucceeds = false

        engine.play(tracks: (1...5).map { makeTrack("t\($0)") }, startAt: 0)

        #expect(engine.isPlaying == false)
        #expect(engine.lastError == .audioSessionFailed)
        #expect(factory.players.count == 1)
        #expect(engine.currentTrack?.title == "t1")
    }

    @Test func enqueueAndClearUpcoming() {
        let (engine, _, _, _) = makeEngine()
        defer { engine.shutdown() }
        let a = makeTrack("a")
        let b = makeTrack("b")
        let c = makeTrack("c")

        engine.play(tracks: [a, b], startAt: 0)
        engine.enqueue(track: c)
        #expect(engine.currentQueue.map(\.title) == ["a", "b", "c"])

        engine.clearUpcoming()
        #expect(engine.currentQueue.map(\.title) == ["a"])
        #expect(engine.currentIndex == 0)
        #expect(engine.currentTrack?.title == "a")
    }

    @Test func previousRestartsThenGoesBack() {
        let (engine, factory, _, _) = makeEngine()
        defer { engine.shutdown() }
        let a = makeTrack("a")
        let b = makeTrack("b")

        engine.play(tracks: [a, b], startAt: 1)
        #expect(factory.player(named: "b") != nil)

        factory.player(named: "b")?.currentTime = 5
        engine.previous()
        #expect(engine.currentTrack?.title == "b")
        #expect(engine.currentTime == 0)

        engine.previous()
        #expect(engine.currentTrack?.title == "a")
    }

    @Test func playbackFinishAdvancesQueue() {
        let (engine, factory, _, _) = makeEngine()
        defer { engine.shutdown() }
        let a = makeTrack("a")
        let b = makeTrack("b")

        engine.play(tracks: [a, b], startAt: 0)
        factory.player(named: "a")?.finish()

        #expect(engine.currentTrack?.title == "b")
        #expect(engine.isPlaying)
    }

    @Test func repeatOneReplaysSameTrack() {
        let (engine, factory, _, _) = makeEngine()
        defer { engine.shutdown() }
        let a = makeTrack("a")

        engine.repeatMode = .one
        engine.play(track: a)
        factory.player(named: "a")?.finish()

        #expect(engine.currentTrack?.title == "a")
        #expect(engine.isPlaying)
    }

    @Test func seekIgnoresNonFiniteTime() {
        let (engine, _, _, _) = makeEngine()
        defer { engine.shutdown() }
        engine.play(track: makeTrack("a"))
        engine.seek(to: 25)

        #expect(engine.currentTime == 25)
        engine.seek(to: .nan)
        #expect(engine.currentTime == 25)
        engine.seek(to: .infinity)
        #expect(engine.currentTime == 25)
    }

    @Test func successfulResumeClearsPlaybackError() {
        let (engine, _, session, _) = makeEngine()
        defer { engine.shutdown() }
        engine.play(track: makeTrack("a"))
        engine.pause()

        session.activationError = TestError.failed
        engine.play()
        #expect(engine.lastError == .audioSessionFailed)

        session.activationError = nil
        engine.play()
        #expect(engine.isPlaying)
        #expect(engine.lastError == nil)
    }

    @Test func failedPlaybackDoesNotRecordRecentTrack() {
        let suiteName = "MusicPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = FakeAudioSession()
        let factory = FakePlayerFactory()
        let recent = RecentlyPlayedStore(defaults: defaults)
        let engine = PlayerEngine(
            recentStore: recent,
            audioSession: session,
            userDefaults: defaults
        ) { url in
            try factory.make(url)
        }
        defer { engine.shutdown() }

        let a = makeTrack("a")
        engine.play(track: a)
        #expect(recent.recentURLs == [a.url])

        engine.stop()
        session.activationError = TestError.failed
        engine.play(track: makeTrack("b"))

        #expect(engine.lastError == .audioSessionFailed)
        #expect(recent.recentURLs == [a.url])
    }
}

@Suite("Metadata cache", .serialized)
@MainActor
struct MetadataCacheTests {
    @Test func invalidatesOnMtimeChange() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataCache(directory: directory, loadOnInit: false)

        cache.store(
            CachedTrackInfo(
                relativePath: "a.mp3",
                modificationDate: Date(timeIntervalSince1970: 100),
                fileSize: 1000,
                title: "A",
                artist: "B",
                album: "C",
                albumArtist: "D",
                duration: 10,
                artworkID: "art"
            )
        )

        #expect(cache.cachedInfo(
            relativePath: "a.mp3",
            modificationDate: Date(timeIntervalSince1970: 100),
            fileSize: 1000
        )?.title == "A")
        #expect(cache.cachedInfo(
            relativePath: "a.mp3",
            modificationDate: Date(timeIntervalSince1970: 200),
            fileSize: 1000
        ) == nil)
    }

    @Test func pruneRemovesStaleEntries() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataCache(directory: directory, loadOnInit: false)

        for name in ["a.mp3", "b.mp3"] {
            cache.store(
                CachedTrackInfo(
                    relativePath: name,
                    modificationDate: .now,
                    fileSize: 1,
                    title: name,
                    artist: "",
                    album: "",
                    albumArtist: "",
                    duration: 1
                )
            )
        }

        cache.prune(keeping: ["a.mp3"])
        #expect(cache.snapshot()["a.mp3"] != nil)
        #expect(cache.snapshot()["b.mp3"] == nil)
    }

    @Test func persistsAcrossInstances() async {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = MetadataCache(directory: directory, loadOnInit: false)
        cache.store(
            CachedTrackInfo(
                relativePath: "a.mp3",
                modificationDate: Date(timeIntervalSince1970: 100),
                fileSize: 42,
                title: "A",
                artist: "B",
                album: "C",
                albumArtist: "D",
                trackNumber: 3,
                discNumber: 1,
                duration: 12,
                artworkID: "art"
            )
        )
        await cache.flush()

        let reloaded = MetadataCache(directory: directory, loadOnInit: true)
        await reloaded.waitUntilLoaded()

        #expect(reloaded.snapshot()["a.mp3"]?.artworkID == "art")
        #expect(reloaded.snapshot()["a.mp3"]?.trackNumber == 3)
    }

    @Test func clearRemovesEntries() async {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataCache(directory: directory, loadOnInit: false)
        cache.store(
            CachedTrackInfo(
                relativePath: "a.mp3",
                modificationDate: .now,
                fileSize: 1,
                title: "A",
                artist: "",
                album: "",
                albumArtist: "",
                duration: 1
            )
        )

        cache.clear()
        #expect(cache.snapshot().isEmpty)
        await cache.flush()
    }
}

@Suite("Artwork store", .serialized)
@MainActor
struct ArtworkStoreTests {
    @Test func storesLoadsAndPrunesArtwork() async {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArtworkStore(directory: directory)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let data = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }

        guard let identifier = await store.store(data) else {
            Issue.record("Artwork store returned nil")
            return
        }

        let existing = await store.existingIDs()
        #expect(existing.contains(identifier))

        let image = await store.image(for: identifier, maxPixel: 8)
        #expect(image != nil)
        #expect((image?.image.size.width ?? 0) > 0)

        await store.prune(keeping: [])
        let remaining = await store.existingIDs()
        #expect(remaining.isEmpty)
    }
}

@Suite("Recently played", .serialized)
@MainActor
struct RecentlyPlayedTests {
    @Test func deduplicatesAndKeepsOrder() {
        let suiteName = "MusicPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentlyPlayedStore(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/a.mp3")
        let b = URL(fileURLWithPath: "/tmp/b.mp3")

        store.record(a)
        store.record(b)
        store.record(a)

        #expect(store.recentURLs == [a, b])
    }
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicPlayerTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}
