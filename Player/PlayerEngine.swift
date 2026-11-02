import AVFoundation
import MediaPlayer
import Observation
import OSLog
import UIKit

@MainActor
protocol AudioSessionControlling: AnyObject {
    func configurePlayback() throws
    func setActive(_ active: Bool) throws
}

@MainActor
final class AudioSessionController: AudioSessionControlling {
    func configurePlayback() throws {
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
    }

    func setActive(_ active: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(active)
    }
}

@MainActor
protocol AudioPlayerProtocol: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var onPlaybackFinished: (@MainActor @Sendable () -> Void)? { get set }

    func prepareToPlay() -> Bool
    @discardableResult func play() -> Bool
    func pause()
    func stop()
}

@MainActor
final class AVAudioPlayerAdapter: NSObject, AudioPlayerProtocol {
    private let player: AVAudioPlayer
    var onPlaybackFinished: (@MainActor @Sendable () -> Void)?

    init(url: URL) throws {
        self.player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    var duration: TimeInterval {
        player.duration.isFinite && player.duration >= 0 ? player.duration : 0
    }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set {
            guard player.duration.isFinite, player.duration > 0 else {
                player.currentTime = max(0, newValue)
                return
            }
            player.currentTime = min(max(0, newValue), player.duration)
        }
    }

    var isPlaying: Bool { player.isPlaying }

    func prepareToPlay() -> Bool {
        player.prepareToPlay()
    }

    @discardableResult
    func play() -> Bool {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }
}

// Kept in an extension so the delegate conformance remains source-compatible
// with SDKs that mark `AVAudioPlayerDelegate` as `@MainActor`.
extension AVAudioPlayerAdapter: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.onPlaybackFinished?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.onPlaybackFinished?()
        }
    }
}

@Observable
@MainActor
final class PlayerEngine: NSObject {
    typealias PlayerFactory = @MainActor (URL) throws -> any AudioPlayerProtocol

    @ObservationIgnored private var audioPlayer: (any AudioPlayerProtocol)?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var progressTick = 0
    @ObservationIgnored private var isAudioSessionConfigured = false

    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var currentTrack: Track?
    var lastError: AppError?
    private(set) var queue: [Track] = []
    private(set) var currentIndex = -1

    var repeatMode: RepeatMode = .off { didSet { persistSettings() } }
    var isShuffled = false { didSet { persistSettings() } }
    var sleepTimer: SleepTimerOption = .off { didSet { applySleepTimer() } }

    private let recentStore: RecentlyPlayedStore
    private let audioSession: any AudioSessionControlling
    private let defaults: UserDefaults
    private let playerFactory: PlayerFactory
    private let log = Logger(subsystem: "com.example.musicplayer", category: "player")

    private enum PlayerError: Error {
        case prepareFailed
    }

    init(
        recentStore: RecentlyPlayedStore,
        audioSession: any AudioSessionControlling = AudioSessionController(),
        userDefaults: UserDefaults = .standard,
        playerFactory: @escaping PlayerFactory = { url in
            try AVAudioPlayerAdapter(url: url)
        }
    ) {
        self.recentStore = recentStore
        self.audioSession = audioSession
        self.defaults = userDefaults
        self.playerFactory = playerFactory
        super.init()
        loadSettings()
        setupRemoteCommands()
        setupNotifications()
    }

    var currentQueue: [Track] { queue }
    var currentQueueIndex: Int { currentIndex }

    var upcomingTracks: [Track] {
        guard currentIndex >= 0, currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    var hasNext: Bool { queue.indices.contains(currentIndex + 1) }
    var hasPrevious: Bool { queue.indices.contains(currentIndex - 1) }

    // MARK: - Settings

    private func loadSettings() {
        if let raw = defaults.string(forKey: "PlayerRepeatMode"),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        isShuffled = defaults.bool(forKey: "PlayerShuffle")
    }

    private func persistSettings() {
        defaults.set(repeatMode.rawValue, forKey: "PlayerRepeatMode")
        defaults.set(isShuffled, forKey: "PlayerShuffle")
    }

    // MARK: - Audio session

    /// Configures the category on first use, then activates the session.
    /// Category setup can fail transiently while the app is launching, so it is
    /// retried on every playback attempt instead of being reported once at launch.
    @discardableResult
    private func activateAudioSession() -> Bool {
        do {
            if !isAudioSessionConfigured {
                try audioSession.configurePlayback()
                isAudioSessionConfigured = true
            }
            try audioSession.setActive(true)
            return true
        } catch {
            log.error(
                "Audio session error: \(error.localizedDescription, privacy: .public)"
            )
            lastError = .audioSessionFailed
            return false
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleMediaReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        else { return }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0

        Task { @MainActor [weak self] in
            guard let self,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
                return
            }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.isPlaying
                self.pause()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                if self.wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                    self.play()
                }
                self.wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification
            .userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
            return
        }

        Task { @MainActor [weak self] in
            guard AVAudioSession.RouteChangeReason(rawValue: rawReason)
                == .oldDeviceUnavailable else {
                return
            }
            self?.pause()
        }
    }

    @objc nonisolated private func handleMediaReset(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAudioSessionConfigured = false
            self.teardownRemoteCommands()
            self.setupRemoteCommands()

            guard let track = self.currentTrack else { return }
            let shouldPlay = self.isPlaying
            let position = self.currentTime
            if self.loadAndPlay(track: track, recordRecent: false) {
                self.seek(to: position)
                if !shouldPlay {
                    self.pause()
                }
            }
        }
    }

    // MARK: - Queue

    func play(tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        let start = tracks[index]
        originalQueue = tracks

        if isShuffled {
            var others = tracks.filter { $0.url != start.url }
            others.shuffle()
            queue = [start] + others
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }

        playFirstAvailable(
            candidates: Array(queue.indices.dropFirst(currentIndex)),
            recordRecent: true
        )
        updateRemoteCommandAvailability()
    }

    func play(track: Track) {
        originalQueue = [track]
        queue = [track]
        currentIndex = 0
        playFirstAvailable(candidates: [0], recordRecent: true)
        updateRemoteCommandAvailability()
    }

    func playFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        playFirstAvailable(
            candidates: Array(index..<queue.count),
            recordRecent: true
        )
        updateRemoteCommandAvailability()
    }

    @discardableResult
    private func loadAndPlay(track: Track, recordRecent: Bool) -> Bool {
        progressTask?.cancel()
        progressTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        nowPlayingArtwork = nil

        audioPlayer?.onPlaybackFinished = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTrack = track
        currentTime = 0
        duration = track.duration
        playbackGeneration &+= 1
        let generation = playbackGeneration

        guard !track.isCloudOnly, Self.hasLocalContent(at: track.url) else {
            lastError = .cloudFileNotDownloaded(filename: track.title)
            clearNowPlayingInfo()
            return false
        }

        // A session failure is not track-specific: abort before loading a file.
        guard activateAudioSession() else {
            clearNowPlayingInfo()
            return false
        }

        do {
            let player = try playerFactory(track.url)
            player.onPlaybackFinished = { [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.handlePlaybackFinished()
            }
            guard player.prepareToPlay() else { throw PlayerError.prepareFailed }

            audioPlayer = player
            duration = player.duration > 0 ? player.duration : track.duration
            loadNowPlayingArtwork(for: track)
            play()
            if isPlaying {
                if recordRecent {
                    recentStore.record(track.url)
                }
                lastError = nil
            }
            return isPlaying
        } catch {
            log.error(
                "Play error for \(track.title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            audioPlayer = nil
            isPlaying = false
            currentTime = 0
            lastError = .playbackFailed(filename: track.title)
            clearNowPlayingInfo()
            return false
        }
    }

    /// Returns false only for a known iCloud placeholder. If resource values
    /// cannot be read, playback is attempted and reports its own error.
    nonisolated private static func hasLocalContent(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else {
            return true
        }
        let status = values.ubiquitousItemDownloadingStatus
        return status == .current || status == .downloaded
    }

    @discardableResult
    private func playFirstAvailable(candidates: [Int], recordRecent: Bool) -> Bool {
        for index in candidates where queue.indices.contains(index) {
            currentIndex = index
            if loadAndPlay(track: queue[index], recordRecent: recordRecent) {
                updateRemoteCommandAvailability()
                return true
            }
            // When the audio session cannot be activated, every remaining track
            // fails the same way. Loading them all would stall the main thread.
            if lastError == .audioSessionFailed { break }
        }

        audioPlayer?.onPlaybackFinished = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        stopProgress()
        currentTime = 0
        updateRemoteCommandAvailability()
        updateNowPlayingInfo()
        return false
    }

    func play() {
        guard let track = currentTrack else {
            clearNowPlayingInfo()
            return
        }
        guard let player = audioPlayer else {
            _ = loadAndPlay(track: track, recordRecent: false)
            updateRemoteCommandAvailability()
            return
        }
        guard activateAudioSession() else {
            isPlaying = false
            updateNowPlayingInfo()
            return
        }

        if player.duration > 0, player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
        }

        if player.play() {
            isPlaying = true
            lastError = nil
            startProgress()
            updateNowPlayingInfo()
        } else {
            log.error("AVAudioPlayer refused to start \(track.title, privacy: .public)")
            isPlaying = false
            lastError = .playbackFailed(filename: track.title)
            updateNowPlayingInfo()
        }
        updateRemoteCommandAvailability()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopProgress()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        guard let player = audioPlayer else {
            currentTime = max(0, time)
            return
        }
        let clamped = min(max(0, time), max(player.duration, 0))
        player.currentTime = clamped
        currentTime = clamped
        updateNowPlayingInfo()
    }

    func next(userInitiated: Bool = true) {
        guard !queue.isEmpty else { return }

        if currentIndex + 1 < queue.count {
            playFirstAvailable(
                candidates: Array((currentIndex + 1)..<queue.count),
                recordRecent: true
            )
        } else if repeatMode == .all {
            if isShuffled {
                var shuffled = originalQueue
                shuffled.shuffle()
                if shuffled.count > 1,
                   shuffled.first?.url == currentTrack?.url {
                    shuffled.swapAt(0, 1)
                }
                queue = shuffled
                currentIndex = 0
            }
            playFirstAvailable(
                candidates: Array(queue.indices),
                recordRecent: true
            )
        } else if userInitiated {
            pause()
            seek(to: 0)
        }
        updateRemoteCommandAvailability()
    }

    func previous() {
        if let player = audioPlayer, player.currentTime > 3 {
            seek(to: 0)
            return
        }

        if currentIndex > 0 {
            playFirstAvailable(
                candidates: Array(stride(from: currentIndex - 1, through: 0, by: -1)),
                recordRecent: true
            )
        } else if repeatMode == .all, !queue.isEmpty {
            playFirstAvailable(
                candidates: Array(stride(from: queue.count - 1, through: 0, by: -1)),
                recordRecent: true
            )
        } else {
            seek(to: 0)
        }
        updateRemoteCommandAvailability()
    }

    func playNext(track: Track) {
        guard !queue.isEmpty, currentIndex >= 0 else {
            play(track: track)
            return
        }
        queue.insert(track, at: currentIndex + 1)
        if let index = originalQueue.firstIndex(where: { $0.url == track.url }) {
            originalQueue.remove(at: index)
        }
        originalQueue.append(track)
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    func enqueue(track: Track) {
        queue.append(track)
        if !originalQueue.contains(where: { $0.url == track.url }) {
            originalQueue.append(track)
        }
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    func clearUpcoming() {
        guard !queue.isEmpty else { return }
        guard currentIndex >= 0 else {
            queue.removeAll()
            originalQueue.removeAll()
            currentIndex = -1
            updateNowPlayingInfo()
            updateRemoteCommandAvailability()
            return
        }

        let kept = Array(queue.prefix(currentIndex + 1))
        let keptURLs = Set(kept.map(\.url))
        queue = kept
        originalQueue = originalQueue.filter { keptURLs.contains($0.url) }
        currentIndex = min(currentIndex, queue.count - 1)
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        playbackGeneration &+= 1

        audioPlayer?.onPlaybackFinished = nil
        audioPlayer?.stop()
        audioPlayer = nil
        nowPlayingArtwork = nil

        isPlaying = false
        currentTrack = nil
        currentTime = 0
        duration = 0
        queue = []
        originalQueue = []
        currentIndex = -1
        sleepTimer = .off
        clearNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    /// Explicit teardown for tests and previews. The app owns one engine for its lifetime.
    func shutdown() {
        progressTask?.cancel()
        sleepTask?.cancel()
        artworkTask?.cancel()
        progressTask = nil
        sleepTask = nil
        artworkTask = nil
        audioPlayer?.onPlaybackFinished = nil
        audioPlayer?.stop()
        audioPlayer = nil
        teardownRemoteCommands()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Modes

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentTrack, !originalQueue.isEmpty else {
            updateNowPlayingInfo()
            updateRemoteCommandAvailability()
            return
        }

        if isShuffled {
            var others = originalQueue.filter { $0.url != current.url }
            others.shuffle()
            queue = [current] + others
            currentIndex = 0
        } else {
            queue = originalQueue
            currentIndex = queue.firstIndex(where: { $0.url == current.url }) ?? 0
        }
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    // MARK: - Sleep timer

    private func applySleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil

        guard sleepTimer != .off, sleepTimer != .endOfTrack else { return }
        let nanoseconds = UInt64(max(0, sleepTimer.rawValue) * 1_000_000_000)
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepTimer = .off
        }
    }

    // MARK: - Progress

    private func startProgress() {
        stopProgress()
        progressTick = 0
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                guard player.isPlaying else { return }

                self.progressTick &+= 1
                if self.progressTick.isMultiple(of: 10) {
                    self.updateNowPlayingInfo()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopProgress() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func handlePlaybackFinished() {
        isPlaying = false
        stopProgress()

        if sleepTimer == .endOfTrack {
            sleepTimer = .off
            audioPlayer?.currentTime = 0
            currentTime = 0
            updateNowPlayingInfo()
            return
        }

        if repeatMode == .one {
            seek(to: 0)
            play()
            return
        }

        if hasNext || repeatMode == .all {
            next(userInitiated: false)
        } else {
            audioPlayer?.currentTime = 0
            currentTime = 0
            updateNowPlayingInfo()
        }
    }

    // MARK: - Now Playing

    private func loadNowPlayingArtwork(for track: Track) {
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        guard let artworkID = track.artworkID else {
            updateNowPlayingInfo()
            return
        }

        let generation = playbackGeneration
        artworkTask = Task { @MainActor [weak self] in
            let result = await ArtworkStore.shared.image(for: artworkID, maxPixel: 512)
            guard !Task.isCancelled, let self,
                  self.playbackGeneration == generation,
                  self.currentTrack?.artworkID == artworkID,
                  let image = result?.image,
                  let data = image.jpegData(compressionQuality: 0.9) else {
                return
            }

            let size = image.size
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: size) { _ in
                UIImage(data: data) ?? UIImage()
            }
            self.updateNowPlayingInfo()
        }
    }

    private func updateNowPlayingInfo() {
        guard let player = audioPlayer, let track = currentTrack else {
            clearNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if !queue.isEmpty {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = max(0, currentIndex)
        }

        if let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote commands

    private func setupRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        addTarget(center.playCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.play() }
            return .success
        }
        addTarget(center.pauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        addTarget(center.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        addTarget(center.nextTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        addTarget(center.previousTrackCommand) { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        addTarget(center.changePlaybackPositionCommand) { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor [weak self] in self?.seek(to: position) }
            return .success
        }

        addTarget(center.changeShuffleModeCommand) { [weak self] event in
            guard let shuffleEvent = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            let shouldShuffle = shuffleEvent.shuffleType != .off
            Task { @MainActor [weak self] in
                guard let self, self.isShuffled != shouldShuffle else { return }
                self.toggleShuffle()
            }
            return .success
        }

        addTarget(center.changeRepeatModeCommand) { [weak self] event in
            guard let repeatEvent = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            let mode: RepeatMode
            switch repeatEvent.repeatType {
            case .off: mode = .off
            case .one: mode = .one
            case .all: mode = .all
            @unknown default: return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.repeatMode = mode
                self?.updateNowPlayingInfo()
            }
            return .success
        }

        updateRemoteCommandAvailability()
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        _ handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, token))
    }

    private func teardownRemoteCommands() {
        for (command, token) in remoteCommandTargets {
            command.removeTarget(token)
        }
        remoteCommandTargets.removeAll()
    }

    private func updateRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = currentTrack != nil
        center.pauseCommand.isEnabled = currentTrack != nil
        center.togglePlayPauseCommand.isEnabled = currentTrack != nil
        center.nextTrackCommand.isEnabled = hasNext || repeatMode == .all
        center.previousTrackCommand.isEnabled = currentTrack != nil
        center.changePlaybackPositionCommand.isEnabled = currentTrack != nil
        center.changeShuffleModeCommand.isEnabled = currentTrack != nil
        center.changeRepeatModeCommand.isEnabled = currentTrack != nil
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        switch repeatMode {
        case .off: center.changeRepeatModeCommand.currentRepeatType = .off
        case .one: center.changeRepeatModeCommand.currentRepeatType = .one
        case .all: center.changeRepeatModeCommand.currentRepeatType = .all
        }
    }
}
