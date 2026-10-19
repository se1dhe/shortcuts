import Testing
import Foundation
import AVFoundation
@testable import Shortcast

@Suite("SentenceBoundary & Narrative Continuity Tests")
struct SentenceBoundaryTests {

    @Test("SentenceBoundaryDetector does not cut off speech mid-sentence")
    func testBoundaryRefinement() {
        let segments = [
            TranscriptSegment(
                start: 10.0,
                end: 13.5,
                text: "Я думал, что мы успеем,",
                words: []
            ),
            TranscriptSegment(
                start: 13.6,
                end: 18.0,
                text: "но поезд уже ушел.",
                words: []
            ),
            TranscriptSegment(
                start: 18.2,
                end: 22.0,
                text: "И теперь нам некуда идти...",
                words: []
            )
        ]

        // Initial cut cuts off at 16.0s (in the middle of segment 2: "но поезд уже [cut]")
        let initialRange = 10.0..<16.0
        let refined = LongformNarrativeDirector.refineSceneBoundary(
            in: segments,
            around: initialRange,
            maxAllowedDuration: 30.0
        )

        // Must expand to at least 18.0 + 0.45 = 18.45s so segment 2 finishes on punctuation "."
        #expect(refined.upperBound >= 18.4)
        // Must maintain leading safety margin before 10.0s (max 0, 10.0 - 0.20 = 9.8)
        #expect(refined.lowerBound <= 9.85)
    }

    @Test("Outro scene includes sufficient tail padding for fade to black strictly after speech")
    func testFinalSceneFadeOutPadding() {
        let lastSegment = TranscriptSegment(
            start: 120.0,
            end: 125.0,
            text: "Это был наш единственный шанс.",
            words: []
        )

        let initialRange = 115.0..<125.0
        let refined = LongformNarrativeDirector.refineSceneBoundary(
            in: [lastSegment],
            around: initialRange,
            maxAllowedDuration: 40.0
        )

        // Tail boundary must extend beyond the end of speech by tailPadding (0.45s)
        #expect(refined.upperBound >= 125.4)
    }

    @Test("Act 1 selects calm prologue monologue over later shouting scene and applies head room pre-roll")
    func testAct1PrologueCalmMonologueSelection() async throws {
        let transcript = Transcript(
            segments: [
                // Calm early exposition monologue in prologue (01:20)
                TranscriptSegment(start: 80.0, end: 95.0, text: "За последние семь лет я твердо усвоил одну вещь: в любой игре всегда есть соперник.", words: []),
                TranscriptSegment(start: 96.0, end: 110.0, text: "Вся хитрость - вовремя осознать, что ты стал вторым, и сделаться первым.", words: []),
                TranscriptSegment(start: 112.0, end: 125.0, text: "Правило простое: защищай свои инвестиции и думай наперед.", words: []),
                
                // Aggressive shouting scene later in the movie (18:30)
                TranscriptSegment(start: 1110.0, end: 1115.0, text: "О чем вы, я не понимаю! У тебя пять секунд! Отвечай быстро!", words: []),
                TranscriptSegment(start: 1116.0, end: 1120.0, text: "Пять! Четыре! Я убью тебя прямо здесь!", words: []),

                // Downfall, struggle, catharsis segments
                TranscriptSegment(start: 1600.0, end: 1640.0, text: "Это была роковая ошибка. Я потерял все деньги и контроль.", words: []),
                TranscriptSegment(start: 2400.0, end: 2450.0, text: "Мы должны бороться и выстоять против всех правил.", words: []),
                TranscriptSegment(start: 3200.0, end: 3245.0, text: "Теперь я свободен от иллюзии и понимаю правду.", words: [])
            ],
            language: "ru"
        )

        let concept = ThematicConcept(
            word: "Иллюзия",
            tagline: "Почему твой разум обманывает тебя",
            philosophicalPremise: "Твой главный враг прячется там, где ты меньше всего ждешь",
            suggestedTitle: "Этот фильм уничтожит твою гордость",
            accentColorHex: "#DDA0DD"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: concept,
            movieTitle: "Револьвер",
            targetDuration: 360.0
        )

        let act1 = arc.acts[0]
        #expect(act1.type == LongformActType.hook)
        guard let firstSeg = act1.segments.first else {
            Issue.record("Act 1 has no segments")
            return
        }

        // Must pick the calm monologue in the prologue (~80s), NOT the interrogation (~1110s)
        #expect(firstSeg.start < 300.0)
        // Must apply atmospheric head room pre-roll (start should be ~78s, exactly 2s before 80.0s speech)
        #expect(firstSeg.start <= 78.5)
    }

    @Test("SentenceBoundaryDetector pre-roll does not overlap preceding sentences")
    func testPreRollDoesNotOverlapPrecedingSentence() {
        let segments = [
            TranscriptSegment(start: 10.0, end: 14.0, text: "Первая фраза закончилась.", words: []),
            TranscriptSegment(start: 15.0, end: 20.0, text: "Вторая фраза начинается здесь.", words: [])
        ]

        let detector = SentenceBoundaryDetector(headPadding: 2.0)
        // Snap to start of second sentence (starts at 15.0)
        // Desired with 2.0s headPadding would be 13.0s, but first sentence ends at 14.0s!
        // Must safely clamp to >= 14.15s to not cut into sentence 1.
        let snapped = detector.snapToSentenceStart(timestamp: 16.0, in: segments)
        #expect(snapped >= 14.1)
        #expect(snapped < 15.0)
    }

    @Test("ThoughtCompletionScorer strictly penalizes panic shouting and open conjunctions, rewarding complete philosophical resolution")
    func testThoughtCompletionScoring() {
        // Open conjunction
        let openConj = ThoughtCompletionScorer.evaluateConcludingPhrase("Его лучшая разводка заключалась в том, что...")
        #expect(!openConj.isCompleteThought)
        #expect(openConj.scoreModifier <= -100_000.0)

        // Panic shout
        let panicShout = ThoughtCompletionScorer.evaluateConcludingPhrase("Дела плохие! Барабаны бьют!")
        #expect(!panicShout.isCompleteThought)
        #expect(panicShout.scoreModifier <= -100_000.0)

        // Question
        let question = ThoughtCompletionScorer.evaluateConcludingPhrase("И что они бьют?")
        #expect(!question.isCompleteThought)
        #expect(question.scoreModifier <= -100_000.0)

        // Closed philosophical resolution
        let resolution = ThoughtCompletionScorer.evaluateConcludingPhrase("Он заставил тебя поверить, что он — это ты.")
        #expect(resolution.isCompleteThought)
        #expect(resolution.scoreModifier >= 400.0)
    }

    @Test("Act 4 selects complete philosophical catharsis over preceding shouting scene and applies 4.5s post-roll")
    func testAct4CatharsisSelection() async throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 80.0, end: 120.0, text: "За последние семь лет я усвоил одно правило: в любой игре есть соперник.", words: []),
                TranscriptSegment(start: 1600.0, end: 1640.0, text: "Это была роковая ошибка. Я потерял все деньги и контроль.", words: []),
                TranscriptSegment(start: 2400.0, end: 2450.0, text: "Мы должны бороться и выстоять против всех правил.", words: []),
                // Shouting scene before finale (3100s)
                TranscriptSegment(start: 3100.0, end: 3130.0, text: "Бойся меня! Дела плохие! Заткнись и отвечай быстро!", words: []),
                // True philosophical catharsis monologue at the very end (3500s)
                TranscriptSegment(start: 3500.0, end: 3540.0, text: "Его лучшая разводка заключалась в том, что он заставил тебя поверить, что он — это ты.", words: [])
            ],
            language: "ru"
        )

        let concept = ThematicConcept(
            word: "Иллюзия",
            tagline: "Почему твой разум обманывает тебя",
            philosophicalPremise: "Твой главный враг прячется там, где ты меньше всего ждешь",
            suggestedTitle: "Этот фильм уничтожит твою гордость",
            accentColorHex: "#DDA0DD"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: concept,
            movieTitle: "Револьвер",
            targetDuration: 360.0
        )

        let act4 = arc.acts[3]
        #expect(act4.type == LongformActType.catharsis)
        guard let finalSeg = act4.segments.last else {
            Issue.record("Act 4 has no segments")
            return
        }

        // Must pick the philosophical resolution monologue (~3500s), NOT the shouting scene (~3100s)
        #expect(finalSeg.start >= 3400.0)
        // Must end cleanly at the conclusion of speech (~3540s), without capturing subsequent scenes
        #expect(finalSeg.end >= 3540.0 && finalSeg.end < 3543.0)
    }

    @Test("Revolver case: Act 1 rejects interrogation shouting and starts with calm defeat monologue, Act 4 selects concise catharsis over Bojsya menya")
    func testRevolverInterrogationVsCalmMonologueAndConciseCatharsis() async throws {
        let transcript = Transcript(
            segments: [
                // 1. Interrogation scene before monologue (1118s - 1133s)
                TranscriptSegment(start: 1118.0, end: 1119.5, text: "Отвечай! О чем вы, я не понимаю!", words: []),
                TranscriptSegment(start: 1122.4, end: 1125.2, text: "У тебя пять секунд. Пять.", words: []),
                TranscriptSegment(start: 1128.3, end: 1133.0, text: "Четыре. Прошу, не нужно. Нет!", words: []),
                
                // 2. Calm defeat monologue (1136.5s - 1165s) -> 3.5s pause after interrogation
                TranscriptSegment(start: 1136.5, end: 1143.5, text: "Какой победитель думает о поражении? Но когда сталкиваешься с тем, с чем столкнулся я,", words: []),
                TranscriptSegment(start: 1144.7, end: 1151.3, text: "новая беспощадная реальность заставляет понять простой факт, который все мы стараемся игнорировать.", words: []),
                TranscriptSegment(start: 1153.0, end: 1164.8, text: "Победить невозможно. Единственная гарантия в этой игре — гарантия проигрыша.", words: []),

                // 3. Middle acts
                TranscriptSegment(start: 2400.0, end: 2460.0, text: "Мы должны бороться и выстоять против всех правил.", words: []),
                TranscriptSegment(start: 3800.0, end: 3860.0, text: "Каждый шаг вперед приближает неизбежный слом.", words: []),

                // 4. Shouting scene near end (5485s - 5498s)
                TranscriptSegment(start: 5485.0, end: 5490.0, text: "Это он играл с нами! И с вами тоже!", words: []),
                TranscriptSegment(start: 5491.0, end: 5498.2, text: "Бойся меня! Бойся меня! Заткнись!", words: []),

                // 5. True concise catharsis monologue (6656s - 6663s, 6.6s long)
                TranscriptSegment(start: 6656.6, end: 6660.9, text: "Его лучшая разводка заключалась в том, что он заставил тебя поверить,", words: []),
                TranscriptSegment(start: 6661.6, end: 6663.2, text: "что он — это ты.", words: [])
            ],
            language: "ru"
        )

        let concept = ThematicConcept(
            word: "Иллюзия",
            tagline: "Твой главный враг — это ложь, которую ты сам себе рассказываешь",
            philosophicalPremise: "Иллюзия контроля над хаосом — смертельная ловушка",
            suggestedTitle: "Ты сам себя обманываешь. Философия ловушки из «Револьвера»",
            accentColorHex: "#F5D020"
        )

        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: concept,
            movieTitle: "Револьвер",
            targetDuration: 360.0
        )

        // Act 1 check: must NOT start with "Отвечай" or "У тебя пять секунд"
        let act1 = arc.acts[0]
        guard let act1Seg = act1.segments.first else {
            Issue.record("Act 1 has no segments")
            return
        }
        #expect(act1Seg.start >= 1130.0) // Must start on calm monologue (1136.5s with headPadding ~1133.5s), NOT at 1118s!

        // Act 4 check: must NOT be "Бойся меня!" (~5490s), MUST be "разводка... что он — это ты" (~6656s)
        let act4 = arc.acts[3]
        guard let act4Seg = act4.segments.last else {
            Issue.record("Act 4 has no segments")
            return
        }
        #expect(act4Seg.start >= 6600.0)
        #expect(act4Seg.end >= 6663.2 && act4Seg.end < 6665.0)
    }

    // MARK: - Синтетические фильмы для политики хронометража (герметично: без модели, ffmpeg и реального файла)

    /// Текст запуска речи одинаков во всех запусках, чтобы скоры были равны
    /// и акт наполнялся политикой дозаполнения, а не жадностью до формулировки.
    private static let syntheticLineBase = "Первый принцип здесь работает без исключений"

    /// Связный запуск речи: строки по `lineSeconds` с паузой 0.4с внутри и разрывом в десятки секунд снаружи
    private func syntheticRun(start: Double, lines: Int, lineSeconds: Double = 10.0) -> [TranscriptSegment] {
        (0..<lines).map { line in
            let segStart = start + Double(line) * lineSeconds
            return TranscriptSegment(
                start: segStart,
                end: segStart + lineSeconds - 0.4,
                text: "\(Self.syntheticLineBase) \(line + 1).",
                words: []
            )
        }
    }

    private func syntheticFilm(runStarts: [Double], lines: Int, lineSeconds: Double = 10.0) -> Transcript {
        Transcript(
            segments: runStarts.flatMap { syntheticRun(start: $0, lines: lines, lineSeconds: lineSeconds) },
            language: "ru"
        )
    }

    /// Тема без единого слова, пересекающегося с синтетическими репликами: иначе скор темы
    /// совпал бы с совпадением по случайности и тест ничего не проверял бы
    private func syntheticConcept(word: String = "Ожидание") -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "Карта не есть территория",
            philosophicalPremise: "Взгляд всегда формирует предмет",
            suggestedTitle: "Слепая линия горизонта",
            accentColorHex: "#F5D020"
        )
    }

    @Test("Fill loop brings every act of a feature-length film to at least 90% of its budget")
    func testAllFourActsFillToBudgetOnFeatureLengthFilm() async throws {
        // Полнометражный синтетический фильм ~7950с: 2 запуска под хук, 5 под падение,
        // 4 под борьбу и 3 под катарсис, разнесённые по всей длине картины
        let transcript = syntheticFilm(
            runStarts: [600, 800, 1700, 1800, 1900, 2000, 2100, 4400, 4500, 4600, 4700, 7700, 7800, 7900],
            lines: 5
        )
        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: syntheticConcept(),
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let report = try #require(arc.durationReport)
        // Цель выводится из длины фильма: 6% от 7949.6с
        #expect(report.effectiveTarget > 470.0 && report.effectiveTarget < 480.0)

        for (act, actType) in zip(arc.acts, LongformActType.allCases) {
            #expect(act.type == actType)
            #expect(!act.segments.isEmpty, "Акт «\(actType.rawValue)» остался пустым")
            let budget = report.effectiveTarget * actType.targetDurationRatio
            #expect(act.duration >= budget * 0.90, "Акт «\(actType.rawValue)»: \(act.duration)с при бюджете \(budget)с")
        }
        #expect(report.fillRatio >= 0.90)
        #expect(report.tailUnused == false)
        #expect(report.gatesUnchanged == true)
        #expect(arc.segments.allSatisfy { $0.duration >= LongformNarrativeDirector.minRunDuration })
        // Ни одного дубля: запуски внутри акта разделены, а не повторяют один и тот же интервал
        #expect(Set(arc.segments.map { "\($0.start)" }).count == arc.segments.count)
    }

    @Test("Act 4 can draw from the final third of the film instead of skipping the tail")
    func testAct4DrawsMaterialFromFinalThird() async throws {
        let transcript = syntheticFilm(runStarts: [600, 2200, 4400, 7700], lines: 3)
        let filmDuration = try #require(transcript.segments.last?.end)
        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: syntheticConcept(),
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let report = try #require(arc.durationReport)

        #expect(arc.acts[3].segments.contains { $0.start >= filmDuration * (2.0 / 3.0) })
        #expect(report.tailUnused == false)
        #expect(report.perActDurations[3] > 0.0)
        // Акты I–III не лезут в зарезервированный финал фильма
        let reservedTailStart = filmDuration * 0.80
        #expect(!arc.acts[0...2].contains { act in act.segments.contains { segment in segment.start >= reservedTailStart } })
    }

    @Test("Thin material reports the arithmetic ceiling and keeps every gate intact")
    func testThinMaterialReportsCeilingWithoutLooseningGates() async throws {
        // Тонкий материал: по одному связному запуску на акт, все вместе гораздо меньше 520с
        let transcript = syntheticFilm(runStarts: [600, 2200, 4400, 7700], lines: 3)
        let director = LongformNarrativeDirector()
        let arc = try await director.buildArc(
            from: transcript,
            concept: syntheticConcept(),
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let report = try #require(arc.durationReport)

        #expect(report.admissibleCeiling < report.effectiveTarget)
        #expect(report.fillRatio < 0.80)
        #expect(report.gatesUnchanged == true)
        // Потолок честный: собрать больше допускаемого материала нельзя
        #expect(report.achieved <= report.admissibleCeiling + 1.0)
        #expect(report.runsPerAct == [1, 1, 1, 1])
        for act in arc.acts {
            #expect(!act.segments.isEmpty)
            for segment in act.segments {
                #expect(segment.duration >= LongformNarrativeDirector.minRunDuration)
            }
        }
    }

    @Test("Effective target is derived from runtime and clamped at both ends")
    func testEffectiveTargetDerivesFromRuntimeAndClamps() async throws {
        let director = LongformNarrativeDirector()
        let cases: [(film: Double, expected: Double)] = [
            (3_600.0, 300.0),   // 6% = 216с -> нижний кламп 300с
            (9_828.0, 520.0),   // 6% = 590с -> верхний кламп запроса 520с
            (1_200.0, 300.0)    // 6% = 72с  -> нижний кламп 300с
        ]
        for item in cases {
            let transcript = Transcript(
                segments: [
                    TranscriptSegment(start: 600.0, end: 640.0, text: "\(Self.syntheticLineBase) 1.", words: []),
                    TranscriptSegment(start: 900.0, end: 940.0, text: "\(Self.syntheticLineBase) 2.", words: []),
                    TranscriptSegment(start: item.film - 60.0, end: item.film - 30.0, text: "\(Self.syntheticLineBase) 3.", words: []),
                    TranscriptSegment(start: item.film - 29.6, end: item.film, text: "\(Self.syntheticLineBase) 4.", words: [])
                ],
                language: "ru"
            )
            let arc = try await director.buildArc(
                from: transcript,
                concept: syntheticConcept(),
                movieTitle: "Синтетический полный метр",
                targetDuration: 520.0
            )
            let report = try #require(arc.durationReport)
            #expect(report.filmDuration == item.film)
            #expect(report.ask == 520.0)
            #expect(report.effectiveTarget == item.expected)
        }
    }

    @Test("Incomplete but admissible catharsis run is taken only when no complete run exists")
    func testIncompleteRunTakenOnlyWhenNoCompleteRunExists() async throws {
        let director = LongformNarrativeDirector()
        let earlier = syntheticRun(start: 300, lines: 4)
            + syntheticRun(start: 1200, lines: 4)
            + syntheticRun(start: 2200, lines: 4)
        // Оборванная мысль: придаточное висит, точка мысли не закрыта
        let openEnded = [
            TranscriptSegment(start: 3300.0, end: 3309.6, text: "Его лучшая разводка заключалась в том,", words: []),
            TranscriptSegment(start: 3310.0, end: 3319.6, text: "что он заставил тебя поверить,", words: []),
            TranscriptSegment(start: 3320.0, end: 3330.0, text: "и ты поверил во всё, что...", words: [])
        ]
        // Закрытая философская формулировка тем же актом
        let closed = [
            TranscriptSegment(start: 3800.0, end: 3809.6, text: "Он заставил тебя поверить,", words: []),
            TranscriptSegment(start: 3810.0, end: 3820.0, text: "что он — это ты.", words: [])
        ]

        // A: есть завершенная мысль — она и берётся, оборванную не вытягивает
        let arcWithClosed = try await director.buildArc(
            from: Transcript(segments: earlier + openEnded + closed, language: "ru"),
            concept: syntheticConcept(word: "Иллюзия"),
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let closedSeg = try #require(arcWithClosed.acts[3].segments.first)
        #expect(closedSeg.start >= 3795.0 && closedSeg.start < 3800.0)
        #expect(closedSeg.end >= 3820.0 && closedSeg.end < 3822.0)

        // B: завершенной мысли нет вовсе — допустимый оборванный крой всё равно берётся,
        // а не вытесняется молчаливой заглушкой поверх речи
        let arcOpenOnly = try await director.buildArc(
            from: Transcript(segments: earlier + openEnded, language: "ru"),
            concept: syntheticConcept(word: "Иллюзия"),
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let openSeg = try #require(arcOpenOnly.acts[3].segments.first)
        #expect(openSeg.start >= 3295.0 && openSeg.start < 3300.0)
        #expect(openSeg.end >= 3330.0)
        #expect(openSeg.duration >= LongformNarrativeDirector.minRunDuration)
    }

    @Test("Theme stemming matches inflected forms of the concept word in any film")
    func testThemeStemmingMatchesInflectedForms() async throws {
        let director = LongformNarrativeDirector()
        let concept = syntheticConcept(word: "Субъективность")
        let keywords = director.extractThematicKeywords(for: concept)

        // Ядро выводится из самого слова, поэтому падежные формы совпадают с темой
        #expect(keywords.contains("субъектив"))
        #expect(keywords.contains { $0.count >= 6 && "оценка субъективна по самой сути".contains($0) })

        // Тот же фильм, но тема живёт только в косвенных формах: позже стоящий
        // тематический запуск обязан быть выбран вместо раннего внетематического
        let offTheme = [
            TranscriptSegment(start: 7700.0, end: 7709.6, text: "Общий план виден только со стороны.", words: []),
            TranscriptSegment(start: 7710.0, end: 7719.6, text: "Ракурс меняет всю картину целиком.", words: []),
            TranscriptSegment(start: 7720.0, end: 7729.6, text: "Итог зависит от точки отсчёта.", words: [])
        ]
        let onTheme = [
            TranscriptSegment(start: 7900.0, end: 7909.6, text: "Итог субъективен лишь отчасти.", words: []),
            TranscriptSegment(start: 7910.0, end: 7919.6, text: "Оценка субъективна по самой сути.", words: []),
            TranscriptSegment(start: 7920.0, end: 7929.6, text: "Итог зависит от точки отсчёта.", words: [])
        ]
        let segments = syntheticRun(start: 600, lines: 3)
            + syntheticRun(start: 2200, lines: 3)
            + syntheticRun(start: 4400, lines: 3)
            + offTheme
            + onTheme

        let arc = try await director.buildArc(
            from: Transcript(segments: segments, language: "ru"),
            concept: concept,
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let catharsis = try #require(arc.acts[3].segments.first)
        #expect(catharsis.start >= 7895.0 && catharsis.start < 7900.0)
    }

    @Test("Act descriptors are derived from the theme only: no per-film tables remain")
    func testNoPerFilmActDescriptorTablesRemain() async throws {
        let director = LongformNarrativeDirector()
        let forbidden = ["револьвер", "revolver", "шахмат", "разводк", "сопрано", "ниточк", "казин", "азарт"]
        for word in ["Иллюзия", "Жадность", "Одиночество", "Субъективность", "Дисциплина"] {
            let descriptors = director.adaptiveActDescriptors(for: syntheticConcept(word: word))
            #expect(descriptors.count == 4)
            for descriptor in descriptors {
                let haystack = (descriptor.title + " " + descriptor.beat).lowercased()
                for needle in forbidden {
                    #expect(!haystack.contains(needle), "Фильмоспецифичный дескриптор: \(descriptor.title)")
                }
            }
            // Generic beats, identical for every theme except the interpolated word
            #expect(descriptors[1].title == "Испытание сомнением")
            #expect(descriptors[2].title == "Точка слома")
            #expect(descriptors[3].title == "Прозрение")
        }

        let transcript = syntheticFilm(runStarts: [600, 2200, 4400, 7700], lines: 3)
        let revolverArc = try await director.buildArc(
            from: transcript,
            concept: syntheticConcept(word: "Иллюзия"),
            movieTitle: "Револьвер",
            targetDuration: 360.0
        )
        let otherArc = try await director.buildArc(
            from: transcript,
            concept: syntheticConcept(word: "Иллюзия"),
            movieTitle: "Совсем другой фильм",
            targetDuration: 360.0
        )
        #expect(revolverArc.acts.map(\.title) == otherArc.acts.map(\.title))
        #expect(revolverArc.acts.map(\.dramaticBeat) == otherArc.acts.map(\.dramaticBeat))
    }

    @Test("LongformAudioMasteringService safely schedules non-overlapping volume ramps without AVFoundation exception")
    func testLongformAudioMasteringServiceSafeRamps() async throws {
        let composition = AVMutableComposition()
        guard let speechTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 1),
              let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2) else {
            Issue.record("Could not create audio tracks")
            return
        }

        let intervals = [
            TimeSegment(start: 1.0, end: 2.3),
            TimeSegment(start: 2.4, end: 2.8),
            TimeSegment(start: 3.0, end: 10.0),
            TimeSegment(start: 10.3, end: 12.0),
            TimeSegment(start: 12.2, end: 15.0),
            TimeSegment(start: 20.0, end: 25.0)
        ]
        let cuts = [2.5, 2.7, 10.1, 12.1, 18.0]

        let service = LongformAudioMasteringService()
        let mix = service.buildAudioMixParameters(
            composition: composition,
            musicTrack: musicTrack,
            speechTrack: speechTrack,
            speechIntervals: intervals,
            sceneCutPoints: cuts,
            totalDuration: 30.0,
            baseMusicVolume: 0.18,
            duckingEnabled: true,
            dialogueFocusEnabled: true,
            originalMusicDucking: 0.82
        )

        #expect(mix.inputParameters.count == 2)
    }

    /// Opt-in smoke test for a real HEVC source. It is intentionally gated so
    /// CI does not need a feature-length movie, while local investigations can
    /// exercise the same AVFoundation export path that the app uses.
    @Test("Longform pipeline exports a short composition from a real HEVC source when requested")
    func testLongformHEVCExportSmokeTest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SHORTCAST_LONGFORM_SMOKE_TEST"] == "1",
              let sourcePath = environment["SHORTCAST_LONGFORM_SMOKE_SOURCE"],
              !sourcePath.isEmpty
        else {
            return
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            Issue.record("Smoke-test source does not exist: \(sourceURL.path)")
            return
        }

        let musicURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shortcast/Resources/Music/Prrodan_Foggy_Night.m4a")
        guard FileManager.default.fileExists(atPath: musicURL.path) else {
            Issue.record("Bundled smoke-test music does not exist: \(musicURL.path)")
            return
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-longform-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let concept = ThematicConcept(
            word: "ВРЕМЯ",
            tagline: "Короткая проверка экспорта HEVC.",
            philosophicalPremise: "Проверяем совместимость финального кодера.",
            suggestedTitle: "Smoke test",
            accentColorHex: "#F5D020"
        )
        let starts: [Double] = [60, 1_600, 3_400, 5_900]
        let transcriptSegments = starts.map {
            TranscriptSegment(start: $0, end: $0 + 1.2, text: "Проверка экспорта.", words: [])
        }
        let actTypes: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
        let acts = zip(actTypes, starts).map { type, start in
            LongformAct(
                type: type,
                title: type.rawValue,
                dramaticBeat: "Smoke test",
                segments: [TimeSegment(start: start, end: start + 1.2)]
            )
        }
        let arc = LongformNarrativeArc(
            movieTitle: "HEVC smoke test",
            concept: concept,
            acts: acts,
            summary: "Short export smoke test"
        )
        let audioSettings = LongformAudioSettings(
            backgroundMusicURL: musicURL,
            musicVolume: 0.18,
            duckingEnabled: true,
            dialogueFocusEnabled: true,
            originalMusicDucking: 0.82,
            coldOpenEnabled: true,
            antiCopyrightEnabled: false
        )

        let result = try await LongformPipelineCoordinator().buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: "HEVC smoke test",
            transcript: Transcript(segments: transcriptSegments, language: "ru"),
            concept: concept,
            audioSettings: audioSettings,
            existingArc: arc,
            workingDirectory: workingDirectory,
            progressHandler: nil
        )

        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.duration > 10)
    }
}
