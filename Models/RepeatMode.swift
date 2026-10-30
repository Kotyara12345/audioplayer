import Foundation

enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one
    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
    var isActive: Bool { self != .off }
}