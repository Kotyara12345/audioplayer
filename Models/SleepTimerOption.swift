import Foundation

enum SleepTimerOption: TimeInterval, CaseIterable, Identifiable, Sendable {
    case off = 0
    case min15 = 900
    case min30 = 1800
    case min60 = 3600
    case endOfTrack = -1

    var id: TimeInterval { rawValue }

    @MainActor
    func label(_ loc: LocalizationManager) -> String {
        switch self {
        case .off: return loc.localized("sleep.off")
        case .min15: return loc.localized("sleep.15")
        case .min30: return loc.localized("sleep.30")
        case .min60: return loc.localized("sleep.60")
        case .endOfTrack: return loc.localized("sleep.end_of_track")
        }
    }
}