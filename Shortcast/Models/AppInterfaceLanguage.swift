import Foundation
import Observation

enum AppInterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case ukrainian = "uk"
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .ukrainian: "Українська"
        case .english: "English"
        case .russian: "Русский"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }

    static func preferred(in languages: [String]) -> Self {
        for language in languages {
            let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if let supported = Self(rawValue: code) { return supported }
        }
        return .english
    }
}

/// UI-only language selection. Never feeds transcription, prompts or rendered content.
@MainActor
@Observable
final class InterfaceLocalization {
    static let shared = InterfaceLocalization()
    nonisolated static let preferenceKey = "shortcast.interfaceLanguage"
    var language: AppInterfaceLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.preferenceKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        language = defaults.string(forKey: Self.preferenceKey)
            .flatMap(AppInterfaceLanguage.init(rawValue:))
            ?? AppInterfaceLanguage.preferred(in: preferredLanguages)
    }
}

enum L10n {
    /// Reading the observable language here makes SwiftUI refresh computed labels, too.
    @MainActor
    static func tr(_ key: String, _ arguments: String...) -> String {
        localized(key, language: InterfaceLocalization.shared.language, arguments: arguments)
    }

    /// Non-UI error descriptions can be evaluated away from the main actor.
    static func stored(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: InterfaceLocalization.preferenceKey)
            .flatMap(AppInterfaceLanguage.init(rawValue:))
            ?? AppInterfaceLanguage.preferred(in: Locale.preferredLanguages)
        return localized(key, language: language)
    }

    static func localized(_ key: String, language: AppInterfaceLanguage, arguments: [String] = [], bundle: Bundle = .main) -> String {
        let localizedBundle = bundle.path(forResource: language.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? bundle
        let template = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return template }
        // Replace placeholders in the template only: user text may contain % signs
        // or placeholder-like characters and must never become a format string.
        guard let pattern = try? NSRegularExpression(pattern: #"%(\d+)\$@"#) else { return template }
        let source = template as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1))).map { $0 - 1 } ?? -1
            result += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }
}
