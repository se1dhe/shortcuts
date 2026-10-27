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

    @Test("reply cut off at the token cap keeps the theme and every finished scene")
    func testTruncatedMomentsAreSalvaged() throws {
        // Director упирается в maxTokens=8192 и обрывает JSON на середине третьей
        // сцены. Тема, план и две завершённые сцены обязаны дожить до экрана,
        // иначе 20 минут генерации выкидываются целиком.
        let truncated = """
        {
          "reasoning": "Фільм досліджує межу між існуванням та ідентичністю.",
          "primaryConcept": {
            "word": "Ідентичність",
            "tagline": "Ти не народжений — тебе зібрали з чужих спогадів.",
            "philosophicalPremise": "Пам'ять — єдиний доказ того, що ти існуєш.",
            "suggestedTitle": "Ти не знаєш, чиє життя ти проживаєш.",
            "accentColorHex": "#E8C46A"
          },
          "essayPlan": {
            "thesis": "Ідентичність — це вибір, а не запис у базі.",
            "hookVariants": ["Ти впевнений, що твої спогади — твої?"],
            "ctaVariants": ["Повний розбір — у Telegram."],
            "actFocus": {
              "form": "Повтори видають, що герой збирає себе з чужих шматків.",
              "psychology": "Страх виявитися копією керує кожним рішенням.",
              "philosophy": "Цінність життя не залежить від способу народження.",
              "catharsis": "Глядач обирає, ким бути, а не ким його зробили."
            }
          },
          "selectedMoments": [
            {
              "startTime": 8421.0,
              "endTime": 8466.0,
              "reason": "Герой уперше ставить під сумнів власні спогади.",
              "dramaticWeight": 0.9,
              "actRole": "psychology",
              "supports": "Сумнів у пам'яті руйнує опору героя.",
              "featured": true
            },
            {
              "startTime": 8618.0,
              "endTime": 8709.0,
              "reason": "Розв'язка: герой обирає власне життя.",
              "dramaticWeight": 0.97,
              "actRole": "catharsis",
              "supports": "Вибір перемагає призначення.",
              "featured": true
            },
            {
              "startTime": 8851.0,
              "endTime": 8989.0,
              "reason": "Остання розмова обірвана на середині
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: truncated))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "Ідентичність")
        let moments = analysis.selectedMoments
        #expect(moments.count >= 2)
        #expect(moments[0].startTime == 8421.0)
        #expect(moments[0].actRole == .psychology)
        #expect(moments[1].startTime == 8618.0)
        #expect(moments[1].actRole == .catharsis)
        #expect(moments.allSatisfy { $0.endTime > $0.startTime })
    }

    @Test("reply cut before the trailing reasoning still yields the theme and scenes")
    func testTruncatedWithoutReasoningKeepsTheme() throws {
        // Реальный обрыв Gemma 12B по новому порядку ключей: reasoning последний,
        // поэтому в ответе его нет вовсе. Обоснование берём из philosophicalPremise
        // самой модели — иначе прогон снова уходил бы в ноль.
        let truncated = """
        {
          "primaryConcept": {
            "word": "СВОБОДА",
            "tagline": "Справжня свобода починається там, де ти перестаєш бути інструментом чужих бажань.",
            "philosophicalPremise": "Свобода — це не відсутність меж, а право їх обирати.",
            "suggestedTitle": "Ти вважаєш себе вільним. Цей фільм доводить зворотне.",
            "accentColorHex": "#E8C46A"
          },
          "essayPlan": {
            "thesis": "Свобода починається з права відмовитися.",
            "hookVariants": ["Ти впевнений, що твої бажання — твої?"]
          },
          "selectedMoments": [
            {
              "startTime": 1839.3,
              "endTime": 1850.8,
              "reason": "Герой уперше відмовляється від наказу.",
              "dramaticWeight": 0.85,
              "actRole": "psychology",
              "supports": "Відмова повертає йому суб'єктність.",
              "featured": true
            },
            {
              "startTime": 2436.6,
              "endTime": 2504.3,
              "reason": "Розв'язка: герой обирає власне життя.",
              "dramaticWeight": 0.95,
              "actRole": "catharsis",
              "supports": "Вибір перемагає призначення.",
              "featured": true
            },
            {
              "startTime": 2532.0
        """

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: truncated))
        try expectFieldsFromModel(analysis)
        #expect(analysis.primaryConcept.word == "СВОБОДА")
        #expect(analysis.aiReasoning == "Свобода — це не відсутність меж, а право їх обирати.")
        #expect(analysis.selectedMoments.count == 2)
        #expect(analysis.selectedMoments.last?.actRole == .catharsis)
    }

    @Test("the real Gemma 12B reply that broke the run now parses")
    func testRealTruncatedDirectorReplyParses() throws {
        // Дословный ответ Director на Blade Runner 2049 (28 КБ, обрыв на 8192
        // токенах). Он и был провалом: тема СВОБОДА есть, сцены есть, reasoning
        // дописать не успел.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-truncated-gemma12b.txt")
        let raw = try String(contentsOf: url, encoding: .utf8)

        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: raw))
        #expect(analysis.source == .llm)
        #expect(analysis.primaryConcept.word == "СВОБОДА")
        #expect(!analysis.selectedMoments.isEmpty)
        #expect(!analysis.aiReasoning.isEmpty)
        #expect(analysis.aiReasoning == analysis.primaryConcept.philosophicalPremise)
    }

    @Test("a complete object without reasoning stays nil even when it has scenes")
    func testCompleteObjectWithoutReasoningStaysNil() {
        // Обрезка не должна «спасать» полный, но семантически неполный ответ.
        let complete = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ти тримаєш кермо, якого ніколи не торкався.",
            "philosophicalPremise": "Свобода, яку ти не обирав.",
            "suggestedTitle": "Ти не за кермом."
          },
          "selectedMoments": [
            {"startTime": 10.0, "endTime": 40.0, "reason": "Сцена.", "dramaticWeight": 0.8, "actRole": "hook"}
          ]
        }
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: complete) == nil)
    }

    @Test("prompt puts the theme first and caps prose so the reply fits 8192 tokens")
    func testPromptKeepsTheReplyInsideTheTokenCap() throws {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")
        let theme = try #require(prompt.range(of: "\"primaryConcept\""))
        let reasoning = try #require(prompt.range(of: "\"reasoning\""))
        #expect(theme.lowerBound < reasoning.lowerBound, "тема обязана идти до reasoning")
        #expect(prompt.contains("600 символів"))
        #expect(prompt.contains("до 20 слів"))
        // Модель схильна перелічувати сцени підряд і не доходити до фіналу.
        #expect(prompt.contains("максимум 24"))
        #expect(prompt.contains("включно з фіналом"))
    }

    @Test("truncation before primaryConcept is an honest nil, not an invented theme")
    func testTruncatedBeforeThemeReturnsNil() {
        let cutBeforeTheme = """
        {
          "reasoning": "Фільм досліджує межу між біологічним існуванням та ідентичністю. Головний конфлікт полягає не в тому, чи є герой реплікантом, а в тому, як він усвідо
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: cutBeforeTheme) == nil)
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

    @Test("Whisper junk never reaches the Director's transcript sample")
    func testSampleDropsHallucinationsBeforeTheDirectorSeesThem() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 4.0, text: "Tekstet av Nicolai Winther"),
            TranscriptSegment(start: 10.0, end: 14.0, text: "Так, я тебе слухаю."),
            TranscriptSegment(start: 20.0, end: 24.0, text: "♪♪"),
            TranscriptSegment(start: 30.0, end: 34.0, text: "Субтитры создавал DimaTorzok"),
            TranscriptSegment(start: 40.0, end: 44.0, text: "Хочеш прогулятись?"),
            TranscriptSegment(start: 50.0, end: 54.0, text: "Gå inn i fjellet."),
            TranscriptSegment(start: 60.0, end: 64.0, text: "Дитя, виношене в утробі…"),
        ], language: "uk")

        let sample = LongformThematicService.stratifiedThematicSample(from: transcript)

        #expect(sample.contains("Так, я тебе слухаю."))
        #expect(sample.contains("Хочеш прогулятись?"))
        #expect(sample.contains("Дитя, виношене в утробі…"))
        for junk in ["Tekstet", "♪♪", "Субтитры создавал", "Gå inn"] {
            #expect(!sample.contains(junk), "В промпт Director'а попал мусор: \(junk)")
        }
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
