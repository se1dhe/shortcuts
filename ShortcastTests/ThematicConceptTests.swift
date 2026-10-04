import Testing
import Foundation
@testable import Shortcast

@Suite("ThematicConcept & Analysis Result Tests")
struct ThematicConceptTests {

    @Test("ThematicConcept initializes with default primary and reasoning values")
    func testConceptDefaults() {
        let concept = ThematicConcept(
            word: "ЭГО",
            tagline: "Твой главный враг прячется в твоей голове.",
            philosophicalPremise: "Победа над собой — единственный истинный триумф.",
            suggestedTitle: "Этот фильм уничтожит твою гордость."
        )

        #expect(concept.word == "ЭГО")
        #expect(concept.isPrimaryChoice == false)
        #expect(concept.aiReasoning == nil)
        #expect(concept.accentColorHex == "#F5D020")
    }

    @Test("ThematicAnalysisResult serializes and deserializes accurately with primary choice")
    func testAnalysisSerialization() throws {
        let primary = ThematicConcept(
            word: "ЭГО",
            tagline: "Твой главный враг прячется в твоей собственной голове.",
            philosophicalPremise: "Единственный способ освободиться — признать, что враг внутри тебя.",
            suggestedTitle: "Этот фильм уничтожит твою гордость.",
            accentColorHex: "#F5D020",
            isPrimaryChoice: true,
            aiReasoning: "Ключевой конфликт фильма строится вокруг иллюзии контроля."
        )

        let alt1 = ThematicConcept(
            word: "ОБМАН",
            tagline: "Единственный способ стать умнее — играть с более умным противником.",
            philosophicalPremise: "Первое правило шахмат: защищай свои интересы.",
            suggestedTitle: "Ты проиграешь, если не поймешь эту игру.",
            accentColorHex: "#F5D020"
        )

        let analysis = ThematicAnalysisResult(
            primaryConcept: primary,
            aiReasoning: "В диалогах Джейка Грина вся драма строится вокруг голоса в голове.",
            alternativeConcepts: [alt1]
        )

        #expect(analysis.primaryConcept.isPrimaryChoice == true)
        #expect(analysis.allConcepts.count == 2)
        #expect(analysis.allConcepts.first?.word == "ЭГО")

        let encoder = JSONEncoder()
        let data = try encoder.encode(analysis)

        let decoder = JSONDecoder()
        let restored = try decoder.decode(ThematicAnalysisResult.self, from: data)

        #expect(restored.primaryConcept.word == "ЭГО")
        #expect(restored.primaryConcept.isPrimaryChoice == true)
        #expect(restored.aiReasoning.contains("Джейка Грина"))
        #expect(restored.alternativeConcepts.count == 1)
        #expect(restored.alternativeConcepts.first?.word == "ОБМАН")
        #expect(restored.allConcepts.count == 2)
    }
}
