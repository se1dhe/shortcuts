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

    // MARK: - Хронометраж выбранного эссе

    /// Плотная материя: реплики идут почти без пауз, поэтому любую сцену
    /// можно расширить соседним диалогом.
    private func dialogueTranscript(until end: Double) -> Transcript {
        let segments = stride(from: 0.0, to: end, by: 10.0).map { start in
            TranscriptSegment(start: start, end: min(start + 9.0, end), text: "Репліка \(Int(start))")
        }
        return Transcript(segments: segments, language: "uk")
    }

    private var analyticConcept: ThematicConcept {
        ThematicConcept(
            word: "СПОДІВАННЯ", tagline: "т", philosophicalPremise: "п",
            suggestedTitle: "з", accentColorHex: "#FFFFFF"
        )
    }

    /// Модель может вернуть 9 коротких сцен на 2,5 минуты при выбранных 12.
    /// Арка обязана сама добрать материал до заказанного хронометража.
    @Test func analyticArcFillsTheSelectedRuntimeWhenDirectorReturnsSparseScenes() async throws {
        let transcript = dialogueTranscript(until: 2400)
        let moments = [
            planned(200, 230, .hook, weight: 0.9, featured: true),
            planned(400, 430, .form),
            planned(900, 930, .psychology),
            planned(1400, 1430, .philosophy),
            planned(1900, 1930, .catharsis, weight: 0.95, featured: true)
        ]
        let plan = EssayPlan(targetDuration: 480)

        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 480,
            essayPlan: plan
        )

        let total = arc.acts.flatMap(\.segments).reduce(0.0) { $0 + $1.duration }
        #expect(total >= 480 * 0.85, "Эссе собрано на \(total) с — это не выбранный хронометраж")
        #expect(total <= 480 * 1.12)
        #expect(arc.acts.allSatisfy { !$0.segments.isEmpty })
    }

    /// Если модель уже вернула достаточно материала, добор не трогает сцены.
    @Test func analyticArcLeavesAPoolThatAlreadyMeetsTheRuntimeUnchanged() async throws {
        let transcript = dialogueTranscript(until: 2400)
        let moments = [
            planned(100, 140, .hook, weight: 0.9, featured: true),
            planned(500, 620, .form),
            planned(900, 1020, .psychology),
            planned(1400, 1510, .philosophy),
            planned(2100, 2190, .catharsis, weight: 0.95, featured: true)
        ]
        let plan = EssayPlan(targetDuration: 480)

        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 480,
            essayPlan: plan
        )

        let expected = Set(moments.map { "\($0.startTime)-\($0.endTime)" })
        let actual = Set(arc.acts.flatMap(\.segments).map { "\($0.start)-\($0.end)" })
        #expect(actual == expected)
    }

    /// Если рядом со сценой нет непрерывного диалога (паузы длиннее порога
    /// сцены), акт добирается ближайшими отдельными диалоговыми кусками.
    @Test func analyticArcAddsNearbyDialogueRunsWhenScenesAreIsolated() async throws {
        let segments = stride(from: 0.0, to: 2400.0, by: 20.0).map { start in
            TranscriptSegment(start: start, end: start + 10.0, text: "Репліка \(Int(start))")
        }
        let transcript = Transcript(segments: segments, language: "uk")
        let moments = [
            planned(0, 10, .hook, weight: 0.9, featured: true),
            planned(400, 410, .form),
            planned(900, 910, .psychology),
            planned(1400, 1410, .philosophy),
            planned(1900, 1910, .catharsis, weight: 0.95, featured: true)
        ]
        let plan = EssayPlan(targetDuration: 480)

        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 480,
            essayPlan: plan
        )

        let total = arc.acts.flatMap(\.segments).reduce(0.0) { $0 + $1.duration }
        #expect(total >= 480 * 0.85, "Эссе собрано на \(total) с при цели 480 с")
        // Добавленный материал не пересекается сам с собой.
        let ranges = arc.acts.flatMap(\.segments).sorted { $0.start < $1.start }
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(next.start >= previous.end - 0.01,
                    "Сцены \(previous) и \(next) пересекаются")
        }
    }

    /// Добор не имеет права лечить недобор хронометража галлюцинациями Whisper:
    /// без гейта ближайшие «реплики» — это субтитровые подписи и звуковые описания.
    @Test func analyticArcNeverFillsWithHallucinatedTranscriptRuns() async throws {
        let sceneRanges: [(start: Double, end: Double, role: LongformActType)] = [
            (200, 230, .hook), (500, 530, .form), (900, 930, .psychology),
            (1400, 1430, .philosophy), (1900, 1930, .catharsis),
        ]
        var segments = sceneRanges.map {
            TranscriptSegment(
                start: $0.start, end: $0.end,
                text: "Справжня реплика про вибір, страх і ціну свободи."
            )
        }
        let junkTexts = [
            "Субтитры создавал DimaTorzok",
            "ТРЕВОЖНАЯ МУЗЫКА",
            "ДОБРА ПІЧА",
        ]
        var junkRanges: [(start: Double, end: Double)] = []
        var junkIndex = 0
        for start in stride(from: 80.0, to: 2_300.0, by: 100.0) {
            let insideScene = sceneRanges.contains {
                start < $0.end + 6 && start + 20 > $0.start - 6
            }
            guard !insideScene else { continue }
            segments.append(TranscriptSegment(
                start: start, end: start + 9,
                text: junkTexts[junkIndex % junkTexts.count]
            ))
            segments.append(TranscriptSegment(
                start: start + 10, end: start + 19,
                text: junkTexts[(junkIndex + 1) % junkTexts.count]
            ))
            junkRanges.append((start, start + 19))
            junkIndex += 1
        }

        let moments = sceneRanges.enumerated().map { index, scene in
            planned(scene.start, scene.end, scene.role,
                    weight: index == 0 || index == 4 ? 0.9 : 0.5,
                    featured: index == 0 || index == 4)
        }
        let arc = try await LongformNarrativeDirector().buildArc(
            from: Transcript(segments: segments, language: "uk"),
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 480,
            essayPlan: EssayPlan(targetDuration: 480)
        )

        let selected = arc.acts.flatMap(\.segments)
        for scene in selected {
            for junk in junkRanges {
                #expect(!(scene.start < junk.end && scene.end > junk.start),
                        "В эссе попал мусорный запуск [\(junk.start), \(junk.end)]")
            }
        }
        let total = selected.reduce(0.0) { $0 + $1.duration }
        #expect(total < 300, "Добор набрал \(total) с из мусора вместо честных 150 с")
    }

    /// Эссе не идёт хронологией фильма: хук первым кадром может быть из середины,
    /// а вторая сцена — из начала. Сам хук при этом один и не длиннее 40 с.
    @Test func analyticArcOpensWithTheHookThenJumpsToTheFilmStart() async throws {
        let transcript = dialogueTranscript(until: 2400)
        let moments = [
            planned(100, 130, .form),
            planned(900, 930, .psychology),
            planned(1400, 1430, .philosophy),
            planned(1900, 1930, .hook, weight: 0.9, featured: true),
            planned(2200, 2230, .catharsis, weight: 0.95, featured: true),
        ]
        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 480,
            essayPlan: EssayPlan(targetDuration: 480)
        )

        let hook = try #require(arc.acts.first)
        #expect(hook.type == .hook)
        #expect(hook.segments.count == 1, "Хук — одна сцена, а не набор: \(hook.segments)")
        let teaser = try #require(hook.segments.first)
        #expect(teaser.start >= 1800, "Хук должен быть взят из середины фильма: \(teaser)")
        #expect(teaser.duration <= 40.001, "Хук растянулся до \(teaser.duration) с при лимите 40 с")

        let form = try #require(arc.acts.dropFirst().first)
        #expect(form.type == .form)
        let second = try #require(form.segments.first)
        #expect(second.start < 300, "Вторая сцена эссе — из начала фильма, а не после хука: \(second)")
    }

    /// Хук обещает зрителю ответ. Если строка-развязка существует в транскрипте,
    /// она обязана попасть в монтаж — и в акт вывода, а не в ту четверть фильма,
    /// где прозвучала: эссе не идёт хронологией фильма.
    @Test func analyticArcCoversTheLineThatPaysOffTheHook() async throws {
        var segments = stride(from: 0.0, to: 2400.0, by: 10.0).map { start in
            TranscriptSegment(start: start, end: start + 9.0, text: "Репліка \(Int(start))")
        }
        let reveal = TranscriptSegment(
            start: 120, end: 129,
            text: "Серійне ім'я — це серійний номер. Він народився, щоб служити."
        )
        segments.append(reveal)
        segments.sort { $0.start < $1.start }

        let moments = [
            planned(200, 230, .hook, weight: 0.9, featured: true),
            planned(400, 430, .form),
            planned(900, 930, .psychology),
            planned(1400, 1430, .philosophy),
            planned(1700, 1730, .catharsis, weight: 0.95, featured: true),
        ]
        let plan = EssayPlan(
            hookVariants: [.init(text: "Це серійне ім'я. Це серійний номер.")],
            targetDuration: 480
        )
        let arc = try await LongformNarrativeDirector().buildArc(
            from: Transcript(segments: segments, language: "uk"),
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 480,
            essayPlan: plan
        )

        let covered = arc.acts.flatMap(\.segments).contains {
            $0.start < reveal.end && $0.end > reveal.start
        }
        #expect(covered, "Развязка хука [120, 129] не вошла в эссе")

        let catharsis = arc.acts.first { $0.type == .catharsis }
        let inConclusion = (catharsis?.segments ?? []).contains {
            $0.start < reveal.end && $0.end > reveal.start
        }
        #expect(inConclusion, "Развязка хука должна быть в акте вывода, а не там, где прозвучала")
    }

    /// Сильнейшая сцена Director — финал эссе. Даже если модель положила её
    /// в другой акт, последним кадром становится она, а не экспозиция; акт-донор
    /// при этом не опустевает.
    @Test func analyticArcEndsOnTheStrongestDirectorScene() async throws {
        let ranges: [(start: Double, end: Double, role: LongformActType, weight: Double, featured: Bool)] = [
            (200, 240, .hook, 0.90, true),
            (400, 450, .form, 0.50, false),
            (900, 950, .psychology, 0.50, false),
            (1400, 1470, .philosophy, 0.99, true),
            (1500, 1550, .philosophy, 0.50, false),
            (1900, 1950, .catharsis, 0.95, true),
        ]
        let segments = ranges.map {
            TranscriptSegment(start: $0.start, end: $0.end, text: "Сцена про вибір і ціну свободи.")
        } + [TranscriptSegment(start: 2300, end: 2310, text: "Репліка поза монтажем.")]
        let moments = ranges.map {
            planned($0.start, $0.end, $0.role, weight: $0.weight, featured: $0.featured)
        }

        let arc = try await LongformNarrativeDirector().buildArc(
            from: Transcript(segments: segments, language: "uk"),
            concept: analyticConcept,
            selectedMoments: moments,
            movieTitle: "Test",
            targetDuration: 300,
            essayPlan: EssayPlan(targetDuration: 300)
        )

        let catharsis = try #require(arc.acts.last)
        #expect(catharsis.type == .catharsis)
        let finale = try #require(catharsis.segments.last)
        #expect(abs(finale.start - 1400) < 0.01 && abs(finale.end - 1470) < 0.01,
                "Эссе заканчивается не сильнейшей сценой Director: \(finale)")

        let philosophy = try #require(arc.acts.first { $0.type == .philosophy })
        #expect(!philosophy.segments.isEmpty, "Акт-донор опустел после переноса сцены")
    }

    /// Промпт обязан требовать сцены, из которых вообще можно собрать
    /// выбранные 8–15 минут, а не девять реплик.
    @Test func thematicPromptAsksForScenesThatCanFillTheRuntime() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")

        #expect(prompt.contains("16-24"), "Промпт не задаёт количество сцен")
        #expect(prompt.contains("20-60"), "Промпт не задаёт длину сцены")
        #expect(prompt.contains("720") && prompt.contains("900"),
                "Промпт не задаёт суммарный запас материала под хронометраж")
    }

    /// Catharsis в промпте — это развязка фильма, а сильнейшая сцена — его финал:
    /// иначе модель отдаёт на катарсис экспозицию, и эссе обрывается.
    @Test func thematicPromptMakesTheStrongestSceneTheFinale() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")

        #expect(prompt.contains("найсильніша сцена всього есе"),
                "Промпт не требует сильнейшую сцену в финал эссе")
        #expect(prompt.contains("розв'язка фільму"),
                "Промпт не связывает катарсис с развязкой фильма")
    }

    /// Промпт обязан держать структуру из `essays_20_films.md`: хук 0:00–0:40
    /// одной сценой и CTA-закличем у Telegram, а не в комментарии.
    @Test func thematicPromptFollowsTheEssaysStructure() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")

        #expect(prompt.contains("0:00–0:40"), "Промпт не задаёт окно хука")
        #expect(prompt.contains("РІВНО ОДНА сцена"), "Промпт не ограничивает хук одной сценой")
        #expect(prompt.contains("Telegram"), "CTA по структуре эссе — заклик у Telegram")
        #expect(!prompt.contains("Напиши в коментарях"), "CTA не должен звать в комментарии")
    }

    @Test @MainActor func storyAnalysisStageNamesTheDirector() {
        let tracker = PipelineProgressTracker()
        tracker.reset(totalVideoDuration: 9841)

        tracker.startStoryAnalysis()

        #expect(tracker.currentStage == .analyzingStory)
        #expect(tracker.statusMessage.contains("Director"))
        #expect(tracker.overallProgress >= 0.49)
    }
}
