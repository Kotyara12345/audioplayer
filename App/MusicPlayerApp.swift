import SwiftUI

@main
struct MusicPlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var loc: LocalizationManager
    @State private var library: MusicLibraryManager
    @State private var player: PlayerEngine
    @State private var recent: RecentlyPlayedStore

    init() {
        let loc = LocalizationManager()
        let recent = RecentlyPlayedStore()
        let library = MusicLibraryManager(localization: loc)
        library.startRestoringIfNeeded()
        let player = PlayerEngine(recentStore: recent)
        _loc = State(initialValue: loc)
        _recent = State(initialValue: recent)
        _library = State(initialValue: library)
        _player = State(initialValue: player)
        BackgroundScanCoordinator.shared.register(library: library)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(loc)
                .environment(library)
                .environment(player)
                .environment(recent)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        library.refreshOnForeground()
                    case .background:
                        if library.hasFolder {
                            BackgroundScanCoordinator.shared.schedule()
                        }
                        Task { await library.flushCache() }
                    default:
                        break
                    }
                }
        }
    }
}
