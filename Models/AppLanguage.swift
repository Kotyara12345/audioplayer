import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, russian, english
    var id: String { rawValue }

    var bundleCode: String? {
        switch self {
        case .system:  return nil
        case .russian: return "ru"
        case .english: return "en"
        }
    }

    @MainActor
    func displayName(loc: LocalizationManager) -> String {
        switch self {
        case .system:  return loc.localized("settings.language.system")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}