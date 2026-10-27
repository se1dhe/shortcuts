import Testing
import Foundation
@testable import Shortcast

/// Два дефекта лонгформ-пайплайна:
/// 1. Эвристика без отсечки титров (0.95 длительности) — последний крой залезает в бегущие титры.
/// 2. Whisper large-v3 галлюцинации выжигаются на экран как субтитры.
struct LongformCreditsAndHallucinationTests {

    // MARK: - Тест 1: buildArcHeuristic исключает сегменты после 0.95 длительности

    @Test func buildArcHeuristicExcludesSegmentsAfterCreditsCutoff() async throws {
        let totalDuration: Double = 10_000.0
        let creditsCutoff = totalDuration * 0.95 // 9500

        // Равномерно распределённые сегменты по всему фильму + два в зоне титров
        var segments: [TranscriptSegment] = []
        // Начало фильма (0–2000с): материал для акта I
        for i in 0..<20 {
            let start = Double(i) * 100.0 + 50.0
            segments.append(TranscriptSegment(
                start: start, end: start + 25.0,
                text: "Терпіння — це зброя, що завжди перемагає в кінці"
            ))
        }
        // Середина фильма (2000–7000с): материал для актов II и III
        for i in 0..<50 {
            let start = 2000.0 + Double(i) * 100.0
            segments.append(TranscriptSegment(
                start: start, end: start + 25.0,
                text: "Він обрав путь боротьби, іншої не було ніколи"
            ))
        }
        // Финал фильма (7000–9400с): материал для акта IV до титров
        for i in 0..<20 {
            let start = 7000.0 + Double(i) * 100.0
            segments.append(TranscriptSegment(
                start: start, end: start + 25.0,
                text: "Тепер він розуміє все, правда відкрилася повністю"
            ))
        }
        // Зона титров (>= 9500с): эти сегменты ДОЛЖНЫ быть отфильтрованы
        segments.append(TranscriptSegment(
            start: 9500.0, end: 9520.0,
            text: "Sous-titres par LaVacheSquid"
        ))
        segments.append(TranscriptSegment(
            start: 9608.0, end: 9625.0,
            text: "Tekstet av Nicolai Winther"
        ))

        let transcript = Transcript(segments: segments, language: "uk")
        let concept = ThematicConcept(
            word: "терпіння",
            tagline: "Терпіння — це зброя",
            philosophicalPremise: "Терпіння перемагає все",
            suggestedTitle: "Терпіння",
            accentColorHex: "#F5D020"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArcHeuristic(
            from: transcript,
            concept: concept,
            movieTitle: "Test Film",
            targetDuration: 520.0
        )

        // Ни один сегмент итоговой арки не начинается в зоне титров
        for segment in arc.segments {
            #expect(segment.start < creditsCutoff,
                    "Сегмент начинается в титрах: start=\(segment.start) >= cutoff=\(creditsCutoff)")
        }
    }

    // MARK: - Тест 2: isHallucinationLine распознаёт канонические галлюцинации

    @Test func isHallucinationLineDetectsKnownPatterns() {
        // Французская галлюцинация подписчиков
        #expect(LongformSubtitleRenderer.isHallucinationLine("Sous-titres par LaVacheSquid"))
        // Норвежская галлюцинация подписчиков
        #expect(LongformSubtitleRenderer.isHallucinationLine("Tekstet av Nicolai Winther"))
        // Шведская галлюцинация подписчиков
        #expect(LongformSubtitleRenderer.isHallucinationLine("Undertexter av Nicolai Winther"))
        // Музыкальные символы без текста
        #expect(LongformSubtitleRenderer.isHallucinationLine("♪♪"))
        #expect(LongformSubtitleRenderer.isHallucinationLine("♪"))
        // Звуковые описания и повторы декодера
        #expect(LongformSubtitleRenderer.isHallucinationLine("GONG"))
        #expect(LongformSubtitleRenderer.isHallucinationLine("*Screams*"))
        #expect(LongformSubtitleRenderer.isHallucinationLine("Gagaga, gagaga, gagagagaga..."))
        #expect(LongformSubtitleRenderer.isHallucinationLine("ДОБРА ПІЧА"))
        // Одиночное "you" — артефакт декодера
        #expect(LongformSubtitleRenderer.isHallucinationLine("you"))
        #expect(LongformSubtitleRenderer.isHallucinationLine("You"))
        // Пустая строка — тоже галлюцинация (нечего показывать)
        #expect(LongformSubtitleRenderer.isHallucinationLine(""))
        #expect(LongformSubtitleRenderer.isHallucinationLine("   "))
    }

    // MARK: - Тест 3: isHallucinationLine пропускает настоящие реплики

    @Test func isHallucinationLinePassesLegitimateUkrainianDialogue() {
        #expect(!LongformSubtitleRenderer.isHallucinationLine("Я не хочу тебе брехати"))
        #expect(!LongformSubtitleRenderer.isHallucinationLine("Ти знаєш, де правда?"))
        #expect(!LongformSubtitleRenderer.isHallucinationLine("Все буде добре, повір мені"))
        #expect(!LongformSubtitleRenderer.isHallucinationLine("Чому ти завжди мовчиш?"))
        #expect(!LongformSubtitleRenderer.isHallucinationLine("Я обрав цей шлях сам"))
        // Строка, содержащая "you" как часть слова, — не галлюцинация
        #expect(!LongformSubtitleRenderer.isHallucinationLine("Молодий хлопець you know"))
    }
}
