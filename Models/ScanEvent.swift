import Foundation

enum ScanPhase: Sendable, Equatable {
    case idle
    case collecting
    case reading
}

struct ScanBatch: Sendable {
    let tracks: [Track]
    let cacheEntries: [CachedTrackInfo]
}

struct ScanResult: Sendable {
    let tracks: [Track]
    let cacheEntries: [CachedTrackInfo]
    let validPaths: Set<String>
    let artworkIDs: Set<String>
}

enum ScanEvent: Sendable {
    case phase(ScanPhase)
    case progress(processed: Int, total: Int)
    case batch(ScanBatch)
    case finished(ScanResult)
    case failed(AppError)
    case cancelled
}
