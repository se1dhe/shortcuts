import Testing
import Foundation
@testable import Shortcast

@Suite("ThematicConcept & Analysis Result Tests")
struct ThematicConceptTests {

    private func decoded(_ json: String) throws -> ThematicAnalysisResult {
        try JSONDecoder().decode(ThematicAnalysisResult.self, from: Data(json.utf8))
    }

    @Test("a hand built concept carries no provenance until someone records it")
    func testConceptDefaultsToUnknownSource() {
        let concept = ThematicConcept(
            word: "ИЛЛЮЗИЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля. Просто тебе так кажется."
        )

        #expect(concept.word == "ИЛЛЮЗИЯ")
        #expect(concept.isPrimaryChoice == false)
        #expect(concept.aiReasoning == nil)
        #expect(concept.accentColorHex == "#F5D020")
        #expect(concept.source == .unknown)
        #expect(concept.source.isTrustworthy == false)
    }

    @Test("only llm and manual provenance is trustworthy")
    func testSourceTrustworthiness() {
        #expect(ThematicSource.llm.isTrustworthy == true)
        #expect(ThematicSource.manual.isTrustworthy == true)
        #expect(ThematicSource.unknown.isTrustworthy == false)
        #expect(ThematicSource.llm.rawValue == "llm")
        #expect(ThematicSource.manual.rawValue == "manual")
        #expect(ThematicSource.unknown.rawValue == "unknown")
    }

    @Test("an analysis result passes its llm provenance to a primary concept built without one")
    func testAnalysisInitBackfillsLLMSourceOntoPrimaryConcept() {
        let primary = ThematicConcept(
            word: "ИЛЛЮЗИЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля. Просто тебе так кажется."
        )
        #expect(primary.source == .unknown)

        let analysis = ThematicAnalysisResult(
            primaryConcept: primary,
            aiReasoning: "Вся драма строится на иллюзии контроля.",
            alternativeConcepts: [],
            source: .llm
        )

        #expect(analysis.source == .llm)
        #expect(analysis.primaryConcept.source == .llm)
        #expect(analysis.primaryConcept.source.isTrustworthy == true)
        #expect(analysis.primaryConcept.isPrimaryChoice == true)
        #expect(analysis.primaryConcept.aiReasoning == "Вся драма строится на иллюзии контроля.")
    }

    @Test("a concept that already records its own provenance keeps it")
    func testAnalysisInitDoesNotOverrideExplicitConceptSource() {
        let curated = ThematicConcept(
            word: "ИЛЛЮЗИЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля. Просто тебе так кажется.",
            source: .manual
        )

        let analysis = ThematicAnalysisResult(
            primaryConcept: curated,
            aiReasoning: "Тему выбрал автор, не модель.",
            alternativeConcepts: [ThematicConcept(
                word: "ПРИВЫЧКА",
                tagline: "Повторение заменяет решение.",
                philosophicalPremise: "Тебя делает то, что ты повторяешь.",
                suggestedTitle: "Твой самый опасный выбор — тот, который ты не делал."
            )],
            source: .llm
        )

        #expect(analysis.primaryConcept.source == .manual)
        #expect(analysis.source == .llm)
        // Alternatives keep whatever they came with: `.unknown` is not silently upgraded.
        #expect(analysis.alternativeConcepts.first?.source == .unknown)
    }

    @Test("llm provenance survives a full encode/decode round trip")
    func testLLMProvenanceSurvivesRoundTrip() throws {
        let analysis = ThematicAnalysisResult(
            primaryConcept: ThematicConcept(
                word: "ИЛЛЮЗИЯ",
                tagline: "Ты держишь руль, которого никогда не касался.",
                philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
                suggestedTitle: "Ты не у руля. Просто тебе так кажется.",
                accentColorHex: "#1C7FD8",
                source: .llm
            ),
            aiReasoning: "Каждый акт возвращает героя к иллюзии контроля.",
            alternativeConcepts: [ThematicConcept(
                word: "ПАМЯТЬ",
                tagline: "Ты помнишь только то, что выгодно тебе.",
                philosophicalPremise: "Прошлое — черновик, который ты переписываешь.",
                suggestedTitle: "Твоя память врёт тебе в пользу.",
                accentColorHex: "#2BB673",
                source: .llm
            )],
            source: .llm
        )

        let data = try JSONEncoder().encode(analysis)
        let restored = try JSONDecoder().decode(ThematicAnalysisResult.self, from: data)

        #expect(restored == analysis)
        #expect(restored.source == .llm)
        #expect(restored.primaryConcept.source == .llm)
        #expect(restored.alternativeConcepts.first?.source == .llm)
        #expect(restored.primaryConcept.isPrimaryChoice == true)
        #expect(restored.allConcepts.count == 2)

        let asObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(asObject["source"] as? String == "llm")
        let primaryDict = try #require(asObject["primaryConcept"] as? [String: Any])
        #expect(primaryDict["source"] as? String == "llm")
    }

    @Test("a manually written theme round trips as manual")
    func testManualProvenanceRoundTrips() throws {
        let concept = ThematicConcept(
            word: "ДОЛГ",
            tagline: "Выбор, который ты не делал, но от которого не отвертишься.",
            philosophicalPremise: "Свобода без ответственности — это просто малодушие.",
            suggestedTitle: "Ты думаешь, что выбрал. Тебя выбрали.",
            isPrimaryChoice: true,
            source: .manual
        )

        let data = try JSONEncoder().encode(concept)
        let restored = try JSONDecoder().decode(ThematicConcept.self, from: data)

        #expect(restored == concept)
        #expect(restored.source == .manual)
        #expect(restored.source.isTrustworthy == true)
    }

    @Test("themes saved before the source field existed decode as unknown and untrustworthy")
    func testLegacyDecodingWithoutSourceKey() throws {
        let legacyConcept = """
        {
          "word": "ДОЛГ",
          "tagline": "Выбор, который ты не делал, но от которого не отвертишься.",
          "philosophicalPremise": "Свобода без ответственности — это просто малодушие.",
          "suggestedTitle": "Ты думаешь, что выбрал. Тебя выбрали."
        }
        """
        let concept = try JSONDecoder().decode(ThematicConcept.self, from: Data(legacyConcept.utf8))
        #expect(concept.source == .unknown)
        #expect(concept.source.isTrustworthy == false)
        #expect(concept.isPrimaryChoice == false)
        #expect(concept.aiReasoning == nil)
        #expect(concept.accentColorHex == "#F5D020")

        let legacyAnalysis = """
        {
          "primaryConcept": \(legacyConcept),
          "aiReasoning": "Модель так и не была спрошена, но тема уже лежала в коде."
        }
        """
        let analysis = try decoded(legacyAnalysis)
        #expect(analysis.source == .unknown)
        #expect(analysis.source.isTrustworthy == false)
        #expect(analysis.primaryConcept.source == .unknown)
        #expect(analysis.alternativeConcepts.isEmpty)
    }

    @Test("decoding does not push result provenance into a concept that never recorded one")
    func testResultSourceIsNotBackfilledWhenDecoding() throws {
        // The backfill lives in the memberwise init only. An on-disk file that claims
        // `"source": "llm"` at the result but not on the concept decodes as written —
        // the concept stays `.unknown` and stays untrustworthy.
        let json = """
        {
          "primaryConcept": {
            "word": "ДОЛГ",
            "tagline": "Выбор, который ты не делал, но от которого не отвертишься.",
            "philosophicalPremise": "Свобода без ответственности — это просто малодушие.",
            "suggestedTitle": "Ты думаешь, что выбрал. Тебя выбрали."
          },
          "aiReasoning": "Разбор, приписанный модели задним числом.",
          "alternativeConcepts": [],
          "source": "llm"
        }
        """
        let analysis = try decoded(json)
        #expect(analysis.source == .llm)
        #expect(analysis.primaryConcept.source == .unknown)
        #expect(analysis.primaryConcept.source.isTrustworthy == false)
    }

    @Test("a result round trips through the theme file exactly as produced by the model")
    func testParsedAnalysisRoundTripsToDiskAndBack() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Иллюзия",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется.",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же самообману.",
          "alternativeConcepts": [
            {
              "word": "Привычка",
              "tagline": "Повторение заменяет решение.",
              "philosophicalPremise": "То, что ты делаешь по привычке, делает тебя.",
              "suggestedTitle": "Твой самый опасный выбор — тот, который ты не делал.",
              "accentColorHex": "#E50914"
            }
          ]
        }
        """
        let parsed = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        let restored = try JSONDecoder().decode(
            ThematicAnalysisResult.self, from: try JSONEncoder().encode(parsed))

        #expect(restored == parsed)
        #expect(restored.source == .llm)
        #expect(restored.primaryConcept.word == "Иллюзия")
        #expect(restored.alternativeConcepts.first?.accentColorHex == "#E50914")
    }
}
