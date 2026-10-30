import Foundation
import Observation

@Observable
@MainActor
final class LocalizationManager {
    private(set) var language: AppLanguage
    @ObservationIgnored private var bundle: Bundle = .main

    init() {
        let saved = UserDefaults.standard.string(forKey: "AppLanguage") ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: saved) ?? .system
        reloadBundle()
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != language else { return }
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "AppLanguage")
        reloadBundle()
    }

    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    var currentLocale: Locale {
        switch language {
        case .system:  return Locale.current
        case .russian: return Locale(identifier: "ru")
        case .english: return Locale(identifier: "en")
        }
    }

    private func reloadBundle() {
        let codes: [String]
        switch language {
        case .system:  codes = Locale.preferredLanguages
        case .russian: codes = ["ru"]
        case .english: codes = ["en"]
        }
        for fullCode in codes {
            for candidate in [fullCode, String(fullCode.prefix(2))] {
                if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
                   let b = Bundle(path: path) {
                    bundle = b
                    return
                }
            }
        }
        bundle = .main
    }
}