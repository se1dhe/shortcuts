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

    @Test("stratifiedThematicSample spans all four quarters of the movie transcript")
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

        let sample = LongformThematicService.stratifiedThematicSample(from: transcript, targetSegmentsCount: 80)
        #expect(sample.contains("Акт I"))
        #expect(sample.contains("Акт II"))
        #expect(sample.contains("Акт III"))
        #expect(sample.contains("Акт IV"))
        #expect(sample.count > 1000)
    }
}
