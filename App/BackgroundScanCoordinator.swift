@preconcurrency import BackgroundTasks
import Foundation
import OSLog

@MainActor
final class BackgroundScanCoordinator {
    static let taskIdentifier = "com.example.musicplayer.scan"
    static let shared = BackgroundScanCoordinator()

    private var library: MusicLibraryManager?
    private let log = Logger(subsystem: "com.example.musicplayer", category: "background")

    private init() {}

    func register(library: MusicLibraryManager) {
        self.library = library
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                Task { @MainActor in
                    task.setTaskCompleted(success: false)
                }
                return
            }
            Task { @MainActor in
                self?.handle(task: processingTask)
            }
        }
        if !registered {
            log.error(
                "BGTaskScheduler registration failed for \(Self.taskIdentifier, privacy: .public)"
            )
        }
    }

    func schedule() {
        guard library?.hasFolder == true else { return }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("BGTask schedule error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(task: BGProcessingTask) {
        schedule()
        guard let library else {
            task.setTaskCompleted(success: false)
            return
        }

        let completion = BackgroundTaskCompletion()
        let scan = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await library.scanInBackground()
            guard !Task.isCancelled else { return }
            await library.flushCache()
        }

        task.expirationHandler = {
            Task { @MainActor in
                library.cancelScan()
                scan.cancel()
                completion.complete(task: task, success: false)
            }
        }

        Task { @MainActor in
            await scan.value
            completion.complete(task: task, success: !scan.isCancelled)
        }
    }
}

@MainActor
private final class BackgroundTaskCompletion {
    private var isCompleted = false

    func complete(task: BGTask, success: Bool) {
        guard !isCompleted else { return }
        isCompleted = true
        task.setTaskCompleted(success: success)
    }
}
