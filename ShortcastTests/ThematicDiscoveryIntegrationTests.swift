import Testing
import Foundation
@testable import Shortcast

@Suite("ThematicDiscovery Integration Tests")
struct ThematicDiscoveryIntegrationTests {

    /// Bespoke-темы под конкретные тайтлы удалены (LLM — единственный источник
    /// смысловых ядер). Без загруженной Director-модели сервис обязан деградировать
    /// к одному универсальному концепту, одинаковому для любого фильма.
    @Test("discoverThematicAnalysis degrades to the single generic concept without a loaded model, regardless of title")
    func testFallbackWithoutModelIsGenericAndTitleIndependent() async throws {
        let service = LongformThematicService()

        let segments = [
            TranscriptSegment(start: 10.0, end: 20.0, text: "Вещи, которыми ты владеешь, в конце концов начинают владеть тобой.", words: []),
            TranscriptSegment(start: 25.0, end: 35.0, text: "Самосовершенствование — это онанизм. Саморазрушение — вот ответ.", words: []),
            TranscriptSegment(start: 40.0, end: 58.0, text: "Ты думаешь, что это ты контролируешь ситуацию, но твой главный враг прячется в твоей собственной голове.", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "ru")

        for movieTitle in ["Револьвер", "Бойцовский клуб"] {
            let result = try await service.discoverThematicAnalysis(
                from: transcript,
                movieTitle: movieTitle,
                movieOverview: nil
            )

            #expect(result.primaryConcept.isPrimaryChoice == true)
            #expect(!result.primaryConcept.word.isEmpty)
            #expect(!result.primaryConcept.tagline.isEmpty)
            #expect(result.primaryConcept.word.lowercased() == "характер")
            #expect(result.alternativeConcepts.isEmpty)
            #expect(result.allConcepts.first?.word.lowercased() == "характер")
            #expect(result.aiReasoning.contains("недоступна"))
        }
    }
}
