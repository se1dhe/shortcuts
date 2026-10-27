import Testing
import Foundation
@testable import Shortcast

private let validAnalysisJSON = """
{
  "primaryConcept": {
    "word": "Ілюзія",
    "tagline": "Ти тримаєш кермо, якого ніколи не торкався.",
    "philosophicalPremise": "Свобода, яку ти не обирав, все одно тебе обирає.",
    "suggestedTitle": "Ти не за кермом. Просто тобі так здається.",
    "accentColorHex": "#1C7FD8"
  },
  "aiReasoning": "Кожен акт повертає героя до того самого самообману: він приймає спостереження за своє життя за право ним керувати. Саме ця ілюзія, а не зовнішній ворог, приводить його до фінального зриву.",
  "alternativeConcepts": [
    {
      "word": "Звичка",
      "tagline": "Повторення замінює рішення.",
      "philosophicalPremise": "Те, що ти робиш звичкою, робить тебе.",
      "suggestedTitle": "Твій найнебезпечніший вибір — той, який ти не зробив.",
      "accentColorHex": "#E50914"
    },
    {
      "word": "Пам'ять",
      "tagline": "Ти пам'ятаєш тільки те, що вигідно тобі.",
      "philosophicalPremise": "Минуле — чернетка, яку ти переписуєш щодня.",
      "suggestedTitle": "Твоя пам'ять бреше тобі на користь.",
      "accentColorHex": "#2BB673"
    },
    {
      "word": "Сором",
      "tagline": "Чужий погляд поселився у тебе в голові.",
      "philosophicalPremise": "Сором — це податок на чужу думку.",
      "suggestedTitle": "Ти платиш за те, чого ніхто не бачив.",
      "accentColorHex": "#8A4FD1"
    }
  ]
}
"""

private func expectFieldsFromModel(_ result: ThematicAnalysisResult?) throws {
    let analysis = try #require(result)
    #expect(analysis.source == .llm)
    #expect(analysis.primaryConcept.source == .llm)
    #expect(analysis.primaryConcept.isPrimaryChoice == true)
    #expect(analysis.allConcepts.allSatisfy { $0.source == .llm })
    #expect(analysis.primaryConcept.aiReasoning == analysis.aiReasoning)
}

@Suite("ThematicParsing Tests")
struct ThematicParsingTests {

    @Test("clean JSON object parses with every field taken from the model output")
    func testParsesCleanJSONObjectAsLlmSourcedAnalysis() throws {
        let result = LongformThematicService.parseThematicAnalysis(from: validAnalysisJSON)
        let analysis = try #require(result)
        try expectFieldsFromModel(analysis)

        #expect(analysis.primaryConcept.word == "Ілюзія")
        #expect(analysis.primaryConcept.tagline == "Ти тримаєш кермо, якого ніколи не торкався.")
        #expect(analysis.primaryConcept.philosophicalPremise == "Свобода, яку ти не обирав, все одно тебе обирає.")
        #expect(analysis.primaryConcept.suggestedTitle == "Ти не за кермом. Просто тобі так здається.")
        #expect(analysis.primaryConcept.accentColorHex == "#1C7FD8")
        #expect(analysis.aiReasoning.contains("фінального зриву"))

        let alts = analysis.alternativeConcepts
        #expect(alts.count == 3)
        #expect(alts.map(\.word) == ["Звичка", "Пам'ять", "Сором"])
        #expect(alts.map(\.tagline) == [
            "Повторення замінює рішення.",
            "Ти пам'ятаєш тільки те, що вигідно тобі.",
            "Чужий погляд поселився у тебе в голові."
        ])
        #expect(alts.map(\.philosophicalPremise) == [
            "Те, що ти робиш звичкою, робить тебе.",
            "Минуле — чернетка, яку ти переписуєш щодня.",
            "Сором — це податок на чужу думку."
        ])
        #expect(alts.map(\.suggestedTitle) == [
            "Твій найнебезпечніший вибір — той, який ти не зробив.",
            "Твоя пам'ять бреше тобі на користь.",
            "Ти платиш за те, чого ніхто не бачив."
        ])
        #expect(alts.map(\.accentColorHex) == ["#E50914", "#2BB673", "#8A4FD1"])
        #expect(alts.map(\.philosophicalPremise) != alts.map(\.tagline))
        #expect(alts.allSatisfy { $0.isPrimaryChoice == false })
        #expect(analysis.allConcepts.count == 4)
        #expect(analysis.allConcepts.first?.word == "Ілюзія")
    }

    @Test("JSON fenced in ```json with prose before and after still parses")
    func testParsesFencedJSONWrappedInProse() throws {
        let modelReply = """
        Вот результат:
        ```json
        \(validAnalysisJSON)
        ```
        Надеюсь, этот разбор поможет собрать эссе.
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: modelReply))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "Ілюзія")
        #expect(analysis.primaryConcept.suggestedTitle == "Ти не за кермом. Просто тобі так здається.")
        #expect(analysis.alternativeConcepts.count == 3)
    }

    @Test("thinking blocks and start_of_turn tokens around the JSON are stripped")
    func testParsesJSONBehindThinkingBlocksAndTurnTokens() throws {
        let modelReply = """
        <start_of_turn>user
        Фильм: «Иллюзия». Выбери одну главную тему эссе и верни строгий JSON.
        <end_of_turn>
        <start_of_turn>model
        <thinking>Сначала проверю, какая тема проходит через все четыре акта и финал.</thinking>
        ```json
        \(validAnalysisJSON)
        ```
        <reasoning>Конфликт внутренний, поэтому якорное слово выбрано именно такое.</reasoning>
        <end_of_turn>
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: modelReply))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "Ілюзія")
        #expect(analysis.allConcepts.count == 4)
    }

    @Test("trailing and duplicate commas are repaired before parsing")
    func testRepairsTrailingAndDuplicateCommas() throws {
        let drifted = """
        {
          "primaryConcept": {,
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется.",
            "accentColorHex": "#1C7FD8",,
          },,
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же самообману.",,
          "alternativeConcepts": [
            {
              "word": "Звичка",
              "tagline": "Повторение заменяет решение.",
              "philosophicalPremise": "То, что ты делаешь по привычке, делает тебя.",
              "suggestedTitle": "Твой самый опасный выбор — тот, который ты не делал.",
              "accentColorHex": "#E50914",
            },
            {
              "word": "Пам'ять",
              "tagline": "Ты помнишь только то, что выгодно тебе.",
              "philosophicalPremise": "Прошлое — черновик, который ты переписываешь каждый день.",
              "suggestedTitle": "Твоя память врёт тебе в пользу.",
              "accentColorHex": "#2BB673",
            },,
          ],
        }
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: drifted))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "Ілюзія")
        #expect(analysis.primaryConcept.accentColorHex == "#1C7FD8")
        #expect(analysis.aiReasoning == "Каждый акт возвращает героя к одному и тому же самообману.")
        #expect(analysis.alternativeConcepts.map(\.word) == ["Звичка", "Пам'ять"])
    }

    @Test("a key missing its opening quote is repaired in a top-level array reply")
    func testRepairsUnquotedKeyInTopLevelArrayOutput() throws {
        let drifted = """
        [
          {
            word": "Ілюзія",
            "tagline": "Ти тримаєш кермо, якого ніколи не торкався.",
            "philosophicalPremise": "Свобода, яку ти не обирав, все одно тебе обирає.",
            "suggestedTitle": "Ти не за кермом. Просто тобі так здається.",,
            "accentColorHex": "#1C7FD8",,
          },,
          {
            "word": "Звичка",
            "tagline": "Повторення замінює рішення.",
            "philosophicalPremise": "Те, що ти робиш звичкою, робить тебе.",
            "suggestedTitle": "Твій найнебезпечніший вибір — той, який ти не зробив.",
            "accentColorHex": "#E50914"
          },
        ]
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: drifted))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "Ілюзія")
        #expect(analysis.primaryConcept.suggestedTitle == "Ти не за кермом. Просто тобі так здається.")
        #expect(analysis.alternativeConcepts.map(\.word) == ["Звичка"])
    }

    @Test("an unquoted key inside an object desyncs the brace scanner: honest nil")
    func testUnquotedKeyInsideObjectIsNotRecoverable() {
        // extractJSONObject tracks string state by quote parity; one missing quote
        // flips it for the rest of the document, so the closing brace is never seen
        // and repairDrift never gets to run. nil is the only honest answer here.
        let drifted = """
        {
          "primaryConcept": {
            word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется.",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же самообману."
        }
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: drifted) == nil)
    }

    @Test("output cut off before the closing brace parses to nil")
    func testTruncatedOutputReturnsNil() {
        let cutMidReasoning = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется.",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: cutMidReasoning) == nil)

        let cutMidArray = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "suggestedTitle": "Ты не у руля.",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к самообману.",
          "alternativeConcepts": [
            {"word": "Звичка", "tagline": "Повторение заменяет
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: cutMidArray) == nil)
    }

    @Test("suggestedTitle must come from the model: missing or blank yields nil")
    func testConceptWithoutSuggestedTitleReturnsNil() {
        let missing = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же самообману."
        }
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: missing) == nil)

        let blank = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "   ",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же самообману."
        }
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: blank) == nil)
    }

    @Test("missing aiReasoning yields nil instead of an unexplained theme")
    func testMissingAiReasoningReturnsNil() {
        let withoutReasoning = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется."
          }
        }
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: withoutReasoning) == nil)

        let blankReasoning = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "suggestedTitle": "Ты не у руля."
          },
          "aiReasoning": ""
        }
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: blankReasoning) == nil)
    }

    @Test("legacy top-level array of concepts parses with the first element as primary")
    func testLegacyTopLevelArrayBecomesStructuredAnalysis() throws {
        let legacy = """
        [
          {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется.",
            "accentColorHex": "#1C7FD8"
          },
          {
            "word": "Звичка",
            "tagline": "Повторение заменяет решение.",
            "philosophicalPremise": "То, что ты делаешь по привычке, делает тебя.",
            "suggestedTitle": "Твой самый опасный выбор — тот, который ты не делал."
          },
          {
            "word": "Пам'ять",
            "tagline": "Ты помнишь только то, что выгодно тебе.",
            "philosophicalPremise": "Прошлое — черновик, который ты переписываешь каждый день.",
            "suggestedTitle": "Твоя память врёт тебе в пользу."
          }
        ]
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: legacy))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "Ілюзія")
        #expect(analysis.alternativeConcepts.map(\.word) == ["Звичка", "Пам'ять"])
        #expect(analysis.aiReasoning == "Свобода, которую ты не выбирал, всё равно тебя выбирает.")
        #expect(analysis.allConcepts.count == 3)
    }

    @Test("prose, empty text and a bare array all parse to nil")
    func testProseEmptyAndBareArrayReturnNil() {
        #expect(LongformThematicService.parseThematicAnalysis(
            from: "Я уверен, что главная тема этого фильма — самообман: он звучит в каждой сцене, от экспозиции до финала.") == nil)
        #expect(LongformThematicService.parseThematicAnalysis(from: "") == nil)
        #expect(LongformThematicService.parseThematicAnalysis(from: "[]") == nil)
    }

    @Test("replies separated by under 0.8s merge into one timecoded line")
    func testAdjacentSegmentsMergeIntoOneTimecodedLine() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 4.0, text: "Ты думаешь, что контролируешь ситуацию."),
            TranscriptSegment(start: 4.4, end: 6.0, text: "Но твой главный враг — в твоей голове."),
            TranscriptSegment(start: 6.05, end: 7.0, text: "Шахматы и разводка."),
            TranscriptSegment(start: 65.0, end: 68.0, text: "В любой игре есть соперник и есть жертва.")
        ], language: "ru")

        let expected = """
        [0.0] Ты думаешь, что контролируешь ситуацию. Но твой главный враг — в твоей голове. Шахматы и разводка.
        [65.0] В любой игре есть соперник и есть жертва.
        """
        #expect(LongformThematicService.stratifiedThematicSample(from: transcript) == expected)
    }

    @Test("a pause clearly over the scene gap threshold starts a new line")
    func testGapBeyondSceneThresholdStartsANewLine() {
        // 0.8 is not representable, so no fixture can sit exactly on the
        // boundary (4.8 - 4.0 == 0.7999999999999998 merges). Test both sides.
        let merged = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 4.0, text: "Первая реплика первой сцены"),
            TranscriptSegment(start: 4.7, end: 6.0, text: "вторая в той же сцене")
        ], language: "ru")
        #expect(LongformThematicService.stratifiedThematicSample(from: merged)
            .split(separator: "\n").count == 1)

        let split = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 4.0, text: "Первая реплика"),
            TranscriptSegment(start: 4.9, end: 6.0, text: "уже следующая сцена")
        ], language: "ru")
        let expected = """
        [0.0] Первая реплика
        [4.9] уже следующая сцена
        """
        #expect(LongformThematicService.stratifiedThematicSample(from: split) == expected)
    }

    @Test("blank segments are skipped and do not break scene merging")
    func testBlankSegmentsAreSkipped() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 4.0, text: "Он замолчал, потому что говорить было не о чем."),
            TranscriptSegment(start: 4.1, end: 4.2, text: "   "),
            TranscriptSegment(start: 4.4, end: 6.0, text: "Тишина — тоже ответ."),
            TranscriptSegment(start: 200.0, end: 203.0, text: "\n\t ")
        ], language: "ru")

        #expect(LongformThematicService.stratifiedThematicSample(from: transcript)
            == "[0.0] Он замолчал, потому что говорить было не о чем. Тишина — тоже ответ.")
    }

    @Test("an empty transcript yields an empty sample")
    func testEmptyTranscriptYieldsEmptySample() {
        #expect(LongformThematicService.stratifiedThematicSample(
            from: Transcript(segments: [], language: "ru")) == "")
        #expect(LongformThematicService.stratifiedThematicSample(
            from: Transcript(segments: [TranscriptSegment(start: 10, end: 12, text: "   ")], language: "ru")) == "")
    }

    @Test("a multi-scene transcript yields one non-empty line per scene across the whole film")
    func testSampleCoversEverySceneOfAMultiSceneTranscript() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 5.0, text: "Всё, что ты знаешь о нём, — это история, которую он тебе рассказал."),
            TranscriptSegment(start: 5.3, end: 9.0, text: "Истории пишут выжившие."),
            TranscriptSegment(start: 700.0, end: 705.0, text: "Ты не жертва. Ты просто ещё не понял правил."),
            TranscriptSegment(start: 1400.0, end: 1404.0, text: "Правил нет. Есть только выбор."),
            TranscriptSegment(start: 1404.6, end: 1410.0, text: "И цена этого выбора."),
            TranscriptSegment(start: 3300.0, end: 3306.0, text: "Прости меня. Не за то, что сделал, — а за то, кем я стал.")
        ], language: "ru")

        let sample = LongformThematicService.stratifiedThematicSample(from: transcript)
        #expect(sample.isEmpty == false)
        #expect(sample.split(separator: "\n").map(String.init) == [
            "[0.0] Всё, что ты знаешь о нём, — это история, которую он тебе рассказал. Истории пишут выжившие.",
            "[700.0] Ты не жертва. Ты просто ещё не понял правил.",
            "[1400.0] Правил нет. Есть только выбор. И цена этого выбора.",
            "[3300.0] Прости меня. Не за то, что сделал, — а за то, кем я стал."
        ])
    }

    @Test("the legacy targetSegmentsCount quota does not thin the sample")
    func testTargetSegmentsCountQuotaIsIgnored() {
        var segments: [TranscriptSegment] = []
        for i in 0..<12 {
            segments.append(TranscriptSegment(
                start: Double(i) * 60.0,
                end: Double(i) * 60.0 + 30.0,
                text: "Реплика \(i) из сцены, которая должна попасть в срез"))
        }
        let transcript = Transcript(segments: segments, language: "ru")

        let full = LongformThematicService.stratifiedThematicSample(from: transcript)
        let capped = LongformThematicService.stratifiedThematicSample(from: transcript, targetSegmentsCount: 3)
        #expect(full == capped)
        #expect(full.split(separator: "\n").count == 12)
        #expect(full.contains("[660.0] Реплика 11 "))
    }

    @Test("director essay plan and scene roles parse together")
    func testParsesEssayPlanAndMomentRoles() throws {
        let json = """
        {"reasoning":"р","primaryConcept":{"word":"ЕГО","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з"},
         "essayPlan":{"thesis":"Контроль — це страх","hookVariants":["Ти контролюєш усе, крім себе.","Хто насправді обирає за тебе?"],
           "ctaVariants":["Напиши, від чого ти не відпустив."],
           "actFocus":{"form":"монтаж","psychology":"страх","philosophy":"свобода","catharsis":"вибір"}},
         "selectedMoments":[
           {"startTime":10,"endTime":20,"reason":"відкриття","dramaticWeight":0.9,"actRole":"hook","supports":"теза","featured":true},
           {"startTime":100,"endTime":130,"reason":"розбір","dramaticWeight":0.8,"actRole":"form"},
           {"startTime":300,"endTime":340,"reason":"страх","dramaticWeight":0.7,"actRole":"psychology"}
         ]}
        """
        let result = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        let plan = try #require(result.essayPlan)
        #expect(plan.thesis == "Контроль — це страх")
        #expect(plan.hookVariants.count == 2)
        #expect(plan.chosenHook == "Ти контролюєш усе, крім себе.")
        #expect(plan.chosenCTA == "Напиши, від чого ти не відпустив.")
        #expect(plan.focus(for: .philosophy) == "свобода")
        #expect(result.selectedMoments.map(\.actRole) == [.hook, .form, .psychology])
        #expect(result.selectedMoments[0].featured == true)
        #expect(result.selectedMoments[1].featured == nil)
    }

    @Test("legacy director response still parses without an essay plan")
    func testLegacyResponseStillParsesWithoutEssayPlan() throws {
        let json = """
        {"reasoning":"р","primaryConcept":{"word":"ЕГО","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з"},
         "selectedMoments":[{"startTime":10,"endTime":20,"reason":"r","dramaticWeight":0.5}],
         "alternativeConcepts":[]}
        """
        let result = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        #expect(result.essayPlan == nil)
        #expect(result.selectedMoments.first?.actRole == nil)
    }
}
