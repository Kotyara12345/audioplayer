import Foundation

enum AppError: Error, Equatable, Identifiable, Sendable {
    case folderAccessDenied
    case playbackFailed(filename: String)
    case cloudFileNotDownloaded(filename: String)
    case metadataReadFailed(filename: String)
    case cacheSaveFailed
    case invalidFolder
    case audioSessionFailed

    var id: String {
        switch self {
        case .folderAccessDenied: return "folderAccessDenied"
        case .playbackFailed(let filename): return "playback-\(filename)"
        case .cloudFileNotDownloaded(let filename): return "cloud-\(filename)"
        case .metadataReadFailed(let filename): return "metadata-\(filename)"
        case .cacheSaveFailed: return "cacheSaveFailed"
        case .invalidFolder: return "invalidFolder"
        case .audioSessionFailed: return "audioSessionFailed"
        }
    }

    @MainActor
    func localized(_ loc: LocalizationManager) -> String {
        switch self {
        case .folderAccessDenied:
            return loc.localized("error.folder_access")
        case .playbackFailed(let filename):
            return "\(loc.localized("error.playback")): \(filename)"
        case .cloudFileNotDownloaded(let filename):
            return "\(loc.localized("error.cloud_file")): \(filename)"
        case .metadataReadFailed(let filename):
            return "\(loc.localized("error.metadata")): \(filename)"
        case .cacheSaveFailed:
            return loc.localized("error.cache_save")
        case .invalidFolder:
            return loc.localized("error.invalid_folder")
        case .audioSessionFailed:
            return loc.localized("error.audio_session")
        }
    }
}
