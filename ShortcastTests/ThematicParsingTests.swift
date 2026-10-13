import Testing
import Foundation
@testable import Shortcast

@Suite("ThematicParsing Tests")
struct ThematicParsingTests {

    @Test("parseThematicAnalysis parses structured JSON with primary concept, reasoning and alternatives")
    func testParseStructuredAnalysis() {
        let json = """
        ```json
        {
          "primaryConcept": {
            "word": "Эго",
            "tagline": "Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей голове.",
            "philosophicalPremise": "Единственный способ победить внутреннего врага — перестать кормить собственную гордость.",
            "suggestedTitle": "Этот фильм уничтожит твою гордость. Философия Револьвера",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "В диалогах Джейка Грина ключевой конфликт строится вокруг борьбы с внутренним голосом («твой лучший разводчик — это твой голос в голове»). Это смысловое ядро фильма.",
          "alternativeConcepts": [
            {
              "word": "Обман",
              "tagline": "Единственный способ стать умнее — играть с более умным противником.",
              "philosophicalPremise": "Первое правило шахмат: защищай свои интересы.",
              "suggestedTitle": "Ты проиграешь, если не поймешь эту разводку.",
              "accentColorHex": "#F5D020"
            },
            {
              "word": "Страх",
              "tagline": "Страх потери контроля разрушает человека быстрее любой пули.",
              "philosophicalPremise": "Пока ты боишься потерять то, чем дорожишь — тобой управляет кто-то другой.",
              "suggestedTitle": "Твой главный страх управляет каждым твоим решением.",
              "accentColorHex": "#E50914"
            }
          ]
        }
        ```
        """

        let result = LongformThematicService.parseThematicAnalysis(from: json)
        #expect(result != nil)
        #expect(result?.primaryConcept.word == "Эго")
        #expect(result?.primaryConcept.isPrimaryChoice == true)
        #expect(result?.aiReasoning.contains("Джейка Грина") == true)
        #expect(result?.alternativeConcepts.count == 2)
        #expect(result?.allConcepts.count == 3)
        #expect(result?.allConcepts.first?.word == "Эго")
    }

    @Test("parseThematicAnalysis gracefully converts legacy array format to structured result")
    func testParseLegacyArrayFallback() {
        let json = """
        [
          {
            "word": "Характер",
            "tagline": "Способность стоять до конца.",
            "philosophicalPremise": "Истинная сила проявляется в испытаниях.",
            "suggestedTitle": "В этом мире нельзя быть слабым.",
            "accentColorHex": "#F5D020"
          },
          {
            "word": "Терпение",
            "tagline": "Выдержка определяет победителя.",
            "philosophicalPremise": "Большинство сдается за шаг до победы.",
            "suggestedTitle": "Ты никогда не узнаешь, насколько был близок!",
            "accentColorHex": "#F5D020"
          }
        ]
        """

        let result = LongformThematicService.parseThematicAnalysis(from: json)
        #expect(result != nil)
        #expect(result?.primaryConcept.word == "Характер")
        #expect(result?.primaryConcept.isPrimaryChoice == true)
        #expect(result?.alternativeConcepts.count == 1)
        #expect(result?.alternativeConcepts.first?.word == "Терпение")
        #expect(result?.allConcepts.count == 2)
    }

    @Test("stratifiedThematicSample covers the whole transcript with compressed timecoded lines")
    func testStratifiedSampleCoversAllActs() {
        var segments: [TranscriptSegment] = []
        for i in 0..<200 {
            let start = Double(i) * 30.0
            let end = start + 25.0
            segments.append(
                TranscriptSegment(
                    start: start,
                    end: end,
                    text: "Реплика номер \(i) в ключевом диалоге сцены",
                    words: []
                )
            )
        }

        let transcript = Transcript(
            segments: segments,
            language: "ru"
        )

        let sample = LongformThematicService.stratifiedThematicSample(from: transcript)
        // First scene (00:00) and last scene (~99:30) must both be present —
        // i.e. the sample spans the entire film, not just a prefix.
        #expect(sample.contains("[00:00]"))
        #expect(sample.contains("Реплика номер 0 "))
        #expect(sample.contains("Реплика номер 199 "))
        #expect(sample.count > 1000)
    }

    @Test("parseThematicAnalysis parses response with conversational prefix, snake_case keys and root concept")
    func testParseConversationalAndSnakeCaseKeys() {
        let text = """
        Вот глубокий анализ сценария фильма «Семь жизней»:
        {
          "word": "Искупление",
          "tagline": "Семь жизней в обмен на одну фатальную ошибку.",
          "philosophical_premise": "Человек не может простить себя сам — только через полное самопожертвование.",
          "suggested_title": "Почему Тим Томас отдал всё? Тайна Семи жизней",
          "ai_reasoning": "Центральный конфликт фильма — это невыносимое чувство вины и жажда искупления."
        }
        Надеюсь, этот анализ поможет сделать мощное эссе!
        """

        let result = LongformThematicService.parseThematicAnalysis(from: text)
        #expect(result != nil)
        #expect(result?.primaryConcept.word == "Искупление")
        #expect(result?.primaryConcept.isPrimaryChoice == true)
        #expect(result?.primaryConcept.suggestedTitle.contains("Семи жизней") == true)
    }

    @Test("parseThematicAnalysis recovers via regex when JSON has unescaped quotes in reasoning")
    func testParseRegexFallbackOnBrokenQuotes() {
        let broken = """
        {
          "primaryConcept": {
            "word": "Жертва",
            "tagline": "Настоящая цена прощения."
          },
          "aiReasoning": "Герой говорит: "Я сделаю это для них" и жертвует собой ради спасения других."
        }
        """

        let result = LongformThematicService.parseThematicAnalysis(from: broken)
        #expect(result != nil)
        #expect(result?.primaryConcept.word == "Жертва")
        #expect(result?.primaryConcept.isPrimaryChoice == true)
    }
}
