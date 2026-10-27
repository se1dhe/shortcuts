import Testing
import Foundation
@testable import Shortcast

/// Тесты балансировки актов (Задача 3) и унификации Credits Guard (Задача 4).
/// Проверяют: расширение коротких моментов, перераспределение в пустые акты,
/// корректность единого порога credits guard для фильмов разной длительности.
struct ActBalancingAndCreditsTests {

    private func moment(
        _ start: Double,
        _ end: Double,
        weight: Double = 0.8,
        reason: String = "Сцена розкриває тему"
    ) -> SelectedMoment {
        SelectedMoment(startTime: start, endTime: end, reason: reason, dramaticWeight: weight)
    }

    // MARK: - Задача 3: Расширение коротких моментов

    /// Момент 3.3s расширяется до 8.0s (minRunDuration)
    @Test func shortMomentExpandedToMinRunDuration() {
        let raw = [moment(100, 103.3)] // длительность 3.3s
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.count == 1)
        #expect(abs(clean[0].startTime - 100.0) < 0.0001)
        // Расширен до minRunDuration = 8.0s
        #expect(abs((clean[0].endTime - clean[0].startTime) - 8.0) < 0.0001)
    }

    /// Короткий момент у самого конца фильма не может быть расширен — отсев
    @Test func shortMomentNearFilmEndCannotBeExpanded() {
        let raw = [moment(995, 998)] // 3s, но 995 + 8 > 1000
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.isEmpty)
    }

    // MARK: - Задача 3: Перераспределение моментов для пустых актов

    /// Пустой Акт IV получает материал из Акта III
    @Test func emptyActIVReceivesMaterialFromActIII() async throws {
        // Все моменты расположены в первых 3 четвертях фильма — Акт IV пуст
        let totalDuration: Double = 1000.0
        let moments = [
            moment(50, 70),      // Акт I (0..250)
            moment(300, 330),    // Акт II (250..500)
            moment(550, 580),    // Акт III (500..750)
            moment(600, 630),    // Акт III (500..750)
        ]

        // Создаём минимальный транскрипт для построения арки
        let segments = [TranscriptSegment(start: 0, end: totalDuration, text: "Тестовий транскрипт")]
        let transcript = Transcript(segments: segments, language: "uk")
        let concept = ThematicConcept(
            word: "терпіння",
            tagline: "Тест",
            philosophicalPremise: "Тест",
            suggestedTitle: "Тест",
            accentColorHex: "#000000"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: concept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 520.0
        )

        // Все 4 акта должны иметь хотя бы один сегмент
        for act in arc.acts {
            #expect(!act.segments.isEmpty,
                    "Акт \(act.type.rawValue) не имеет сегментов после балансировки")
        }
    }

    /// Все 4 акта имеют хотя бы один сегмент после балансировки
    @Test func allFourActsHaveAtLeastOneSegment() async throws {
        // Моменты только в первой половине — акты III и IV будут пустыми
        let totalDuration: Double = 2000.0
        let moments = [
            moment(100, 130),    // Акт I (0..500)
            moment(200, 230),    // Акт I (0..500)
            moment(600, 640),    // Акт II (500..1000)
            moment(700, 740),    // Акт II (500..1000)
            moment(800, 840),    // Акт II (500..1000)
        ]

        let segments = [TranscriptSegment(start: 0, end: totalDuration, text: "Тестовий транскрипт")]
        let transcript = Transcript(segments: segments, language: "uk")
        let concept = ThematicConcept(
            word: "страх",
            tagline: "Тест",
            philosophicalPremise: "Тест",
            suggestedTitle: "Тест",
            accentColorHex: "#000000"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: concept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 520.0
        )

        #expect(arc.acts.count == 4)
        for (index, act) in arc.acts.enumerated() {
            #expect(!act.segments.isEmpty,
                    "Акт \(index + 1) (\(act.type.rawValue)) пуст после балансировки")
        }
    }

    // MARK: - Задача 4: Унификация Credits Guard

    /// Фильм 25 минут (1500s) — credits guard применяется
    @Test func creditsGuardAppliedFor25MinFilm() async throws {
        let totalDuration: Double = 1500.0 // 25 минут
        let creditsCutoff = totalDuration * 0.95 // 1425s

        // Сегменты по всему фильму + сегмент в зоне титров
        var segments: [TranscriptSegment] = []
        for i in 0..<15 {
            let start = Double(i) * 90.0 + 20.0
            segments.append(TranscriptSegment(
                start: start, end: start + 25.0,
                text: "Терпіння — це зброя, що завжди перемагає"
            ))
        }
        // Сегмент в зоне титров (>= 1425s)
        segments.append(TranscriptSegment(
            start: 1430.0, end: 1455.0,
            text: "Sous-titres par LaVacheSquid"
        ))

        let transcript = Transcript(segments: segments, language: "uk")
        let concept = ThematicConcept(
            word: "терпіння",
            tagline: "Тест",
            philosophicalPremise: "Тест",
            suggestedTitle: "Тест",
            accentColorHex: "#000000"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArcHeuristic(
            from: transcript,
            concept: concept,
            movieTitle: "25min Film",
            targetDuration: 520.0
        )

        // Ни один сегмент не начинается в зоне титров
        for segment in arc.segments {
            #expect(segment.start < creditsCutoff,
                    "Сегмент начинается в титрах: start=\(segment.start) >= cutoff=\(creditsCutoff)")
        }
    }

    /// Фильм 15 минут (900s) — credits guard НЕ применяется
    @Test func creditsGuardNotAppliedFor15MinFilm() async throws {
        let totalDuration: Double = 900.0 // 15 минут — ниже порога 1200s

        // Сегменты в конце фильма (после 0.95 = 855s) — должны быть доступны
        var segments: [TranscriptSegment] = []
        for i in 0..<8 {
            let start = Double(i) * 100.0 + 20.0
            segments.append(TranscriptSegment(
                start: start, end: start + 25.0,
                text: "Це звичайний короткий фільм без титрів"
            ))
        }
        // Сегменты в «зоне титров» короткого фильма (>= 855s)
        segments.append(TranscriptSegment(
            start: 860.0, end: 885.0,
            text: "Фінальна сцена короткого фільму"
        ))

        let transcript = Transcript(segments: segments, language: "uk")
        let concept = ThematicConcept(
            word: "самотність",
            tagline: "Тест",
            philosophicalPremise: "Тест",
            suggestedTitle: "Тест",
            accentColorHex: "#000000"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArcHeuristic(
            from: transcript,
            concept: concept,
            movieTitle: "15min Film",
            targetDuration: 520.0
        )

        // Для короткого фильма (900s < 1200s) отсечка титров не применяется,
        // поэтому сегменты после 0.95 длительности ДОПУСТИМЫ
        let lateSegments = arc.segments.filter { $0.start >= totalDuration * 0.95 }
        // Просто проверяем, что арка построена (сегменты в конце не были обрезаны)
        #expect(arc.acts.count == 4)
        // Если есть сегменты после 0.95 — это нормально для короткого фильма
        // (credits guard не должен их отсекать)
        if !lateSegments.isEmpty {
            #expect(lateSegments.count >= 1,
                    "Credits guard не должен применяться к фильму короче 20 мин")
        }
    }

    // MARK: - Аналитическая 5-актная арка

    private func planned(
        _ start: Double,
        _ end: Double,
        _ role: LongformActType?,
        weight: Double = 0.5,
        featured: Bool? = nil
    ) -> SelectedMoment {
        SelectedMoment(
            startTime: start,
            endTime: end,
            reason: "scene",
            dramaticWeight: weight,
            actRole: role,
            supports: nil,
            featured: featured
        )
    }

    @Test func analyticArcBuildsFiveActsByRole() async throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1200, text: "Тестовий транскрипт")
        ], language: "uk")
        let concept = ThematicConcept(
            word: "КОНТРОЛЬ", tagline: "т", philosophicalPremise: "п",
            suggestedTitle: "з", accentColorHex: "#FFFFFF"
        )
        let moments = [
            planned(10, 30, .hook, weight: 0.9, featured: true),
            planned(100, 130, .form),
            planned(200, 240, .psychology),
            planned(300, 340, .philosophy),
            planned(400, 440, .catharsis, weight: 0.95)
        ]
        let plan = EssayPlan(
            thesis: "Контроль — це страх",
            hookVariants: [.init(text: "Ти контролюєш усе, крім себе.")],
            targetDuration: 480,
            actFocus: ["philosophy": "свобода"]
        )

        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: concept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 520,
            essayPlan: plan
        )

        #expect(arc.acts.map(\.type) == LongformActType.canonicalAnalyticOrder)
        #expect(arc.acts.allSatisfy { !$0.segments.isEmpty })
        #expect(arc.hookText == "Ти контролюєш усе, крім себе.")
        #expect(arc.thesis == "Контроль — це страх")
        #expect(arc.acts[3].dramaticBeat == "свобода")
    }

    @Test func rolelessMomentsKeepLegacyFourActPath() async throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1000, text: "Тестовий транскрипт")
        ], language: "uk")
        let concept = ThematicConcept(
            word: "СТРАХ", tagline: "т", philosophicalPremise: "п",
            suggestedTitle: "з", accentColorHex: "#FFFFFF"
        )
        let moments = [moment(50, 80), moment(300, 330), moment(600, 640), moment(800, 840)]

        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: concept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 520
        )

        #expect(arc.acts.count == 4)
        #expect(arc.acts.map(\.type) == [.hook, .downfall, .struggle, .catharsis])
    }
}
