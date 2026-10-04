import Testing
import Foundation
@testable import Shortcast

@Suite("ThematicDiscovery Integration Tests")
struct ThematicDiscoveryIntegrationTests {

    @Test("discoverThematicAnalysis identifies ЭГО as primary concept for Револьвер with deep reasoning")
    func testRevolverThematicDiscovery() async throws {
        let service = LongformThematicService()

        var segments: [TranscriptSegment] = []
        for i in 0..<120 {
            let start = Double(i) * 20.0
            let end = start + 18.0
            let text = (i % 2 == 0)
                ? "Ты думаешь, что это ты контролируешь ситуацию, но твой главный враг прячется в твоей собственной голове."
                : "В любой игре всегда есть соперник и всегда есть жертва. Шахматы и разводка."
            segments.append(TranscriptSegment(start: start, end: end, text: text, words: []))
        }

        let transcript = Transcript(segments: segments, language: "ru")

        // Without loaded model, fallback gracefully selects the bespoke primary choice and reasoning
        let result = try await service.discoverThematicAnalysis(
            from: transcript,
            movieTitle: "Револьвер",
            movieOverview: "Фильм Гая Ричи о Джейке Грине и игре с собственным эго."
        )

        #expect(result.primaryConcept.word.lowercased() == "эго")
        #expect(result.primaryConcept.isPrimaryChoice == true)
        #expect(result.aiReasoning.contains("Джейка Грина") || result.aiReasoning.contains("Эго"))
        #expect(!result.alternativeConcepts.isEmpty)
        #expect(result.allConcepts.first?.word.lowercased() == "эго")
    }

    @Test("discoverThematicAnalysis identifies БУНТ as primary concept for Бойцовский клуб")
    func testFightClubThematicDiscovery() async throws {
        let service = LongformThematicService()

        let segments = [
            TranscriptSegment(start: 10.0, end: 20.0, text: "Вещи, которыми ты владеешь, в конце концов начинают владеть тобой.", words: []),
            TranscriptSegment(start: 25.0, end: 35.0, text: "Самосовершенствование — это онанизм. Саморазрушение — вот ответ.", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "ru")

        let result = try await service.discoverThematicAnalysis(
            from: transcript,
            movieTitle: "Бойцовский клуб",
            movieOverview: "Фильм Дэвида Финчера."
        )

        #expect(result.primaryConcept.word.lowercased() == "бунт")
        #expect(result.primaryConcept.isPrimaryChoice == true)
        #expect(result.aiReasoning.contains("Тайлера") || result.aiReasoning.contains("бунт"))
    }
}
