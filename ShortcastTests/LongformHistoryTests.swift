import Foundation
import Testing
@testable import Shortcast

@Suite("Essay discovery history")
struct LongformHistoryTests {
    @Test func offeredThemesSurviveRestartWithoutMarkingRendered() throws {
        let suite = "shortcast-history-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = LongformHistoryService(userDefaults: defaults)
        let concept = ThematicConcept(word: " МАСКА ", tagline: "Роль героя", philosophicalPremise: "Ціна ролі", suggestedTitle: "Маска", source: .llm)
        history.recordOffered(movieTitle: " Американський психопат ", concepts: [concept])
        let reopened = LongformHistoryService(userDefaults: defaults)
        #expect(reopened.excludedThemes(movieTitle: "АМЕРИКАНСЬКИЙ ПСИХОПАТ") == ["маска"])
        #expect(!reopened.isConceptGenerated(movieTitle: "Американський психопат", conceptWord: "МАСКА"))
        #expect(reopened.excludedThemes(movieTitle: "Драйв").isEmpty)
        #expect(reopened.discoveryGuidance(movieTitle: "Американський психопат").contains("маска"))
    }

    @Test func channelHistoryAdvisesWithoutBanningAnotherFilmsTheme() throws {
        let suite = "shortcast-history-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = LongformHistoryService(userDefaults: defaults)
        history.markConceptGenerated(movieTitle: "Фільм 1", conceptWord: "ВЛАДА")
        history.markConceptGenerated(movieTitle: "Фільм 2", conceptWord: "Влада")
        #expect(history.excludedThemes(movieTitle: "Фільм 3").isEmpty)
        #expect(history.discoveryGuidance(movieTitle: "Фільм 3").contains("влада (фільмів: 2)"))
        #expect(history.discoveryGuidance(movieTitle: "Фільм 3").contains("не заборона"))
        let concept = ThematicConcept(word: "МАСКА", tagline: "Роль", philosophicalPremise: "Конфлікт", suggestedTitle: "Маска", source: .llm)
        history.recordOffered(movieTitle: "Фільм 1", concepts: [concept])
        history.recordOffered(movieTitle: "Фільм 2", concepts: [concept])
        #expect(history.discoveryGuidance(movieTitle: "Фільм 3").contains("маска (фільмів: 2)"))
    }
}
