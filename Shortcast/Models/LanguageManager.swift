import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case en = "en"
    case ru = "ru"
    case uk = "uk"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .en: "🇬🇧"
        case .ru: "🇷🇺"
        case .uk: "🇺🇦"
        }
    }

    var label: String {
        switch self {
        case .en: "English"
        case .ru: "Русский"
        case .uk: "Українська"
        }
    }
}

@MainActor
@Observable
final class LanguageManager {
    var selectedLanguage: AppLanguage {
        didSet {
            defaults.set(selectedLanguage.rawValue, forKey: "shortcast.language")
            defaults.set([selectedLanguage.rawValue], forKey: "AppleLanguages")
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: "shortcast.language"),
           let lang = AppLanguage(rawValue: stored) {
            self.selectedLanguage = lang
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            let code = String(preferred.prefix(2))
            self.selectedLanguage = AppLanguage(rawValue: code) ?? .en
        }
        defaults.set([selectedLanguage.rawValue], forKey: "AppleLanguages")
    }
}
