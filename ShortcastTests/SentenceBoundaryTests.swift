import Testing
import Foundation
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
        // Must include at least 4.5s post-roll after 3540s speech (end >= 3544.5)
        #expect(finalSeg.end >= 3544.0)
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
        #expect(act4Seg.end >= 6663.2 + 4.5)
    }
}
