import Testing
@testable import Shortcast

@Suite("ThematicAnalysisResult Fallback Marker")
struct ThematicFallbackMarkerTests {

    private func concept(_ word: String) -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "t",
            philosophicalPremise: "p",
            suggestedTitle: "s",
            accentColorHex: "#FFFFFF",
            isPrimaryChoice: true)
    }

    @Test("generic «Характер» with no alternatives is a fallback")
    func detectsGenericFallback() {
        let result = ThematicAnalysisResult(
            primaryConcept: concept("Характер"),
            aiReasoning: "Модель недоступна — предложен универсальный концепт.")
        #expect(result.isGenericFallback == true)
    }

    @Test("case-insensitive match on the fallback word")
    func detectsFallbackCaseInsensitive() {
        let result = ThematicAnalysisResult(
            primaryConcept: concept("характер"),
            aiReasoning: "Модель недоступна.")
        #expect(result.isGenericFallback == true)
    }

    @Test("a real AI result with alternatives is never a fallback")
    func realResultIsNotFallback() {
        let result = ThematicAnalysisResult(
            primaryConcept: concept("Иллюзия"),
            aiReasoning: "Настоящий разбор сценария.",
            alternativeConcepts: [concept("Контроль")])
        #expect(result.isGenericFallback == false)
    }

    @Test("«Характер» as a genuine theme with alternatives is not a fallback")
    func characterWithAlternativesIsNotFallback() {
        let result = ThematicAnalysisResult(
            primaryConcept: concept("Характер"),
            aiReasoning: "Настоящий разбор.",
            alternativeConcepts: [concept("Свобода")])
        #expect(result.isGenericFallback == false)
    }
}
