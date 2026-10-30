import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(MusicLibraryManager.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(LocalizationManager.self) private var loc
    @Environment(RecentlyPlayedStore.self) private var recent

    @State private var showFolderPicker = false
    @State private var showNowPlaying = false
    @State private var showQueue = false
    @State private var showClearConfirmation = false
    @State private var infoTrack: Track? = nil
    @State private var query = ""

    init() {}

    var body: some View {
        @Bindable var lib = library
        NavigationStack {
            VStack(spacing: 0) {
                playerBar
                Divider()
                Picker("", selection: $lib.viewMode) {
                    Text(loc.localized("view.songs")).tag(ViewMode.songs)
                    Text(loc.localized("view.albums")).tag(ViewMode.albums)
                    Text(loc.localized("view.artists")).tag(ViewMode.artists)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityLabel(loc.localized("view.title"))

                Divider()
                content
            }
            .navigationTitle(Text(loc.localized("app.title")))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(loc.localized("search.prompt"))
            )
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    library.importFolder(url)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if library.isScanning { scanningBar }
            }
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingFullScreen()
                    .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: $showQueue) {
                QueueView()
            }
            .sheet(item: $infoTrack) {
                TrackInfoView(track: $0)
            }
            .confirmationDialog(
                loc.localized("library.clear.title"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(loc.localized("library.clear"), role: .destructive) {
                    player.stop()
                    library.clearLibrary()
                }
                Button(loc.localized("action.cancel"), role: .cancel) {}
            } message: {
                Text(loc.localized("library.clear.message"))
            }
            .alert(
                loc.localized("error.title"),
                isPresented: Binding(
                    get: { library.lastError != nil || player.lastError != nil },
                    set: {
                        if !$0 {
                            library.lastError = nil
                            player.lastError = nil
                        }
                    }
                )
            ) {
                Button(loc.localized("action.ok")) {
                    library.lastError = nil
                    player.lastError = nil
                }
            } message: {
                if let error = library.lastError ?? player.lastError {
                    Text(error.localized(loc))
                }
            }
            .environment(\.locale, loc.currentLocale)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if library.tracks.isEmpty {
            emptyState
        } else if !query.isEmpty && filteredSongs.isEmpty {
            noResultsState
        } else {
            switch library.viewMode {
            case .songs: songsView
            case .albums: albumsView
            case .artists: artistsView
            }
        }
    }

    private var filteredSongs: [Track] {
        guard !query.isEmpty else { return library.tracks }
        let normalizedQuery = query.localizedLowercase
        return library.tracks.filter { matches($0, query: normalizedQuery) }
    }

    private var filteredAlbumSections: [AlbumSection] {
        guard !query.isEmpty else { return library.albumSections }
        let normalizedQuery = query.localizedLowercase
        return library.albumSections.compactMap { section in
            let filtered = section.tracks.filter {
                matches($0, query: normalizedQuery)
            }
            guard !filtered.isEmpty else { return nil }
            return AlbumSection(
                album: section.album,
                albumArtist: section.albumArtist,
                tracks: filtered
            )
        }
    }

    private var filteredArtistSections: [ArtistSection] {
        guard !query.isEmpty else { return library.artistSections }
        let normalizedQuery = query.localizedLowercase
        return library.artistSections.compactMap { section in
            let filtered = section.tracks.filter {
                matches($0, query: normalizedQuery)
            }
            guard !filtered.isEmpty else { return nil }
            return ArtistSection(artist: section.artist, tracks: filtered)
        }
    }

    private func matches(_ track: Track, query: String) -> Bool {
        track.title.localizedLowercase.contains(query)
            || track.artist.localizedLowercase.contains(query)
            || track.album.localizedLowercase.contains(query)
            || track.albumArtist.localizedLowercase.contains(query)
    }

    private var songsView: some View {
        ScrollViewReader { proxy in
            List {
                let recentTracks = recent.tracks(from: filteredSongs)
                if !recentTracks.isEmpty && query.isEmpty {
                    Section(loc.localized("recent.title")) {
                        ForEach(recentTracks.indices, id: \.self) { index in
                            let track = recentTracks[index]
                            trackRow(
                                track,
                                allTracks: recentTracks,
                                index: index
                            )
                            .id("recent-\(track.url.absoluteString)")
                        }
                    }
                }

                Section {
                    ForEach(filteredSongs.indices, id: \.self) { index in
                        let track = filteredSongs[index]
                        trackRow(
                            track,
                            allTracks: filteredSongs,
                            index: index
                        )
                        .id("main-\(track.url.absoluteString)")
                        .listRowBackground(
                            isCurrent(track)
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear
                        )
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: player.currentTrack?.url) { _, newURL in
                guard let newURL else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("main-\(newURL.absoluteString)", anchor: .center)
                }
            }
        }
    }

    private var albumsView: some View {
        List {
            ForEach(filteredAlbumSections) { section in
                Section {
                    ForEach(section.tracks.indices, id: \.self) { index in
                        trackRow(
                            section.tracks[index],
                            allTracks: section.tracks,
                            index: index
                        )
                    }
                } header: {
                    sectionHeader(
                        title: section.album,
                        subtitle: section.subtitle,
                        tracks: section.tracks
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var artistsView: some View {
        List {
            ForEach(filteredArtistSections) { section in
                Section {
                    ForEach(section.tracks.indices, id: \.self) { index in
                        trackRow(
                            section.tracks[index],
                            allTracks: section.tracks,
                            index: index
                        )
                    }
                } header: {
                    sectionHeader(
                        title: section.artist,
                        subtitle: nil,
                        tracks: section.tracks
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func sectionHeader(
        title: String,
        subtitle: String?,
        tracks: [Track]
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                player.play(tracks: tracks, startAt: 0)
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                "\(loc.localized("player.play_all")): \(title)"
            )
        }
        .textCase(nil)
    }

    // MARK: - Row

    @ViewBuilder
    private func trackRow(_ track: Track, allTracks: [Track], index: Int) -> some View {
        let current = isCurrent(track)
        Button {
            if current {
                player.togglePlayPause()
            } else {
                player.play(tracks: allTracks, startAt: index)
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if current {
                        NowPlayingIndicator(isPlaying: player.isPlaying)
                            .transition(.opacity.combined(with: .scale))
                    } else {
                        Color.clear.frame(width: 16, height: 16)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: player.isPlaying)

                ArtworkView(artworkID: track.artworkID, size: 40, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(track.artist.isEmpty
                         ? loc.localized("player.unknown_artist")
                         : track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if track.isCloudOnly {
                    Image(systemName: "icloud.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(loc.localized("track.cloud_only"))
                }

                Text(formatTime(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(track.isHidden ? 0.45 : 1.0)
        .accessibilityLabel(accessibilityLabel(for: track))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if track.isHidden {
                Button {
                    library.unhide(track: track)
                } label: {
                    Label(loc.localized("track.unhide"), systemImage: "eye")
                }
                .tint(.blue)
            } else {
                Button(role: .destructive) {
                    library.hide(track: track)
                } label: {
                    Label(loc.localized("track.hide"), systemImage: "eye.slash")
                }
            }
            Button {
                infoTrack = track
            } label: {
                Label(loc.localized("context.info"), systemImage: "info.circle")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button {
                player.playNext(track: track)
            } label: {
                Label(
                    loc.localized("context.play_next"),
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
            Button {
                player.enqueue(track: track)
            } label: {
                Label(loc.localized("context.add_queue"), systemImage: "text.append")
            }
            Button {
                infoTrack = track
            } label: {
                Label(loc.localized("context.info"), systemImage: "info.circle")
            }
            Divider()
            if track.isHidden {
                Button {
                    library.unhide(track: track)
                } label: {
                    Label(loc.localized("track.unhide"), systemImage: "eye")
                }
            } else {
                Button(role: .destructive) {
                    library.hide(track: track)
                } label: {
                    Label(loc.localized("track.hide"), systemImage: "eye.slash")
                }
            }
        }
    }

    private func accessibilityLabel(for track: Track) -> String {
        let artist = track.artist.isEmpty
            ? loc.localized("player.unknown_artist")
            : track.artist
        var label = "\(track.title), \(artist), \(formatTime(track.duration))"
        if track.isCloudOnly {
            label += ", \(loc.localized("track.cloud_only"))"
        }
        return label
    }

    private func isCurrent(_ track: Track) -> Bool {
        player.currentTrack?.url == track.url
    }

    // MARK: - Player bar

    private var playerBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    showNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(
                            artworkID: player.currentTrack?.artworkID,
                            size: 56,
                            cornerRadius: 8
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentTrack?.title
                                 ?? loc.localized("player.nothing_playing"))
                                .font(.headline)
                                .lineLimit(1)
                            Text(player.currentTrack?.artist ?? " ")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.localized("player.now_playing"))

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .disabled(player.currentTrack == nil)
                .accessibilityLabel(
                    player.isPlaying
                        ? loc.localized("player.pause")
                        : loc.localized("player.play")
                )

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20))
                }
                .accessibilityLabel(loc.localized("queue.title"))
            }

            ProgressBarView()
        }
        .padding()
    }

    // MARK: - Scanning bar

    private var scanningBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phaseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if library.scanTotal > 0 {
                    Text("\(library.scanProcessed) / \(library.scanTotal)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Button {
                    library.cancelScan()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(loc.localized("action.cancel"))
            }
            ProgressView(value: library.scanProgress)
                .tint(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var phaseText: String {
        switch library.scanPhase {
        case .idle: return ""
        case .collecting: return loc.localized("scan.phase.collecting")
        case .reading: return loc.localized("scan.phase.reading")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button {
                    library.refreshLibrary()
                } label: {
                    Label(loc.localized("library.menu.refresh"), systemImage: "arrow.clockwise")
                }

                if library.hiddenCount > 0 {
                    Button {
                        library.showHidden.toggle()
                    } label: {
                        Label(
                            library.showHidden
                                ? loc.localized("library.menu.hide_hidden")
                                : "\(loc.localized("library.menu.show_hidden")) (\(library.hiddenCount))",
                            systemImage: library.showHidden ? "eye.slash" : "eye"
                        )
                    }
                    Button(role: .destructive) {
                        library.restoreAllHidden()
                    } label: {
                        Label(
                            loc.localized("library.menu.restore_all"),
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                }

                Divider()

                Menu {
                    ForEach(SleepTimerOption.allCases) { option in
                        Button {
                            player.sleepTimer = option
                        } label: {
                            if player.sleepTimer == option {
                                Label(option.label(loc), systemImage: "checkmark")
                            } else {
                                Text(option.label(loc))
                            }
                        }
                    }
                } label: {
                    Label(loc.localized("player.sleep_timer"), systemImage: "moon.zzz")
                }

                Menu {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            loc.setLanguage(language)
                        } label: {
                            if loc.language == language {
                                Label(language.displayName(loc: loc), systemImage: "checkmark")
                            } else {
                                Text(language.displayName(loc: loc))
                            }
                        }
                    }
                } label: {
                    Label(loc.localized("settings.language"), systemImage: "globe")
                }

                if library.hasFolder {
                    Divider()
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label(loc.localized("library.clear"), systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(loc.localized("library.menu"))
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showFolderPicker = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel(loc.localized("library.import_folder"))
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(loc.localized("library.empty.title"))
                .font(.title3)

            Text(emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if library.hiddenCount > 0 && library.tracks.isEmpty {
                Button {
                    library.showHidden = true
                } label: {
                    Label(
                        loc.localized("library.menu.show_hidden"),
                        systemImage: "eye"
                    )
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    showFolderPicker = true
                } label: {
                    Label(
                        loc.localized("library.import_folder"),
                        systemImage: "folder.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }

    private var emptyMessage: String {
        if library.hiddenCount > 0 {
            return loc.localized("library.empty.hidden")
        }
        if library.hasFolder {
            return loc.localized("library.empty.folder")
        }
        return loc.localized("library.empty.message")
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(loc.localized("search.no_results"))
                .foregroundStyle(.secondary)
            Button(loc.localized("action.clear_search")) {
                query = ""
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
