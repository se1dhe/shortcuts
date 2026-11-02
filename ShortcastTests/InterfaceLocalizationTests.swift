import Foundation
import Observation
import Testing
@testable import Shortcast

@Suite("Interface localization")
struct InterfaceLocalizationTests {
    @Test func preferredLanguageUsesSupportedRegionalVariants() {
        #expect(AppInterfaceLanguage.preferred(in: ["pl-PL", "uk-UA"]) == .ukrainian)
        #expect(AppInterfaceLanguage.preferred(in: ["en_GB"]) == .english)
        #expect(AppInterfaceLanguage.preferred(in: ["ru-RU"]) == .russian)
        #expect(AppInterfaceLanguage.preferred(in: ["de-DE"]) == .english)
    }

    @Test @MainActor func languagePersistsAndInvalidatesComputedLabels() throws {
        let name = "shortcast-localization-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let selection = InterfaceLocalization(defaults: defaults, preferredLanguages: ["uk-UA"])
        #expect(selection.language == .ukrainian)
        selection.language = .english
        #expect(InterfaceLocalization(defaults: defaults).language == .english)
        #expect(defaults.string(forKey: "shortcast.languageOverride") == nil)
    }

    @Test func catalogContainsRealTranslations() {
        #expect(L10n.localized("Настройки студии", language: .english) == "Studio settings")
        #expect(L10n.localized("Настройки студии", language: .ukrainian) == "Налаштування студії")
        #expect(L10n.localized("Настройки студии", language: .russian) == "Настройки студии")
    }

    @Test func interpolationDoesNotInterpretUserDataAsFormatting() {
        let title = "100% %@ %2$@"
        let output = L10n.localized("АКТ %1$@: %2$@", language: .english, arguments: ["2", title])
        #expect(output == "ACT 2: \(title)")
        #expect(L10n.localized("Сцена %1$@ · %2$@", language: .ukrainian, arguments: ["3", "00:12"]) == "Сцена 3 · 00:12")
    }

    @Test func unknownContentIsPreserved() {
        let dialogue = "Ми приймаємо реальність світу, у якому живемо."
        #expect(L10n.localized(dialogue, language: .english) == dialogue)
        #expect(L10n.localized("🦉 @cinema", language: .russian) == "🦉 @cinema")
    }
}
