import Foundation

final class FolderObserver: NSObject, NSFilePresenter, @unchecked Sendable {
    var presentedItemURL: URL?
    var presentedItemOperationQueue: OperationQueue = .main
    private let onChange: @MainActor @Sendable (URL?) -> Void

    init(url: URL, onChange: @escaping @MainActor @Sendable (URL?) -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func presentedItemDidChange() {
        notify()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        notify(movedURL: newURL)
    }

    func presentedSubitemDidChange(at url: URL) {
        notify()
    }

    func presentedSubitemDidAppear(at url: URL) {
        notify()
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        notify()
    }

    func presentedSubitemDidDelete(at url: URL) {
        notify()
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }

    private func notify(movedURL: URL? = nil) {
        Task { @MainActor [onChange] in
            onChange(movedURL)
        }
    }
}
