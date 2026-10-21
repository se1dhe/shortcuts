import Testing
import Foundation
@testable import Shortcast

/// Тесты для задач 1, 2, 7, 8: спеллчекер, фильтрация некириллических символов,
/// позитивные инструкции в промпте, поддержка String timecodes.
@Suite("ThematicServiceFixes Tests")
struct ThematicServiceFixesTests {

    // MARK: - Задача 2: Фильтрация некириллических символов

    @Test("фильтрация арабских символов из текста")
    func filterRemovesArabicCharacters() {
        let input = "تعريف реплікантів"
        let filtered = LongformThematicService.filterNonCyrillic(input)
        #expect(filtered == " реплікантів")
    }

    @Test("фильтрация латинских символов — слово отбрасывается полностью")
    func filterRemovesLatinWordCompletely() {
        let input = "creation"
        let filtered = LongformThematicService.filterNonCyrillic(input)
        #expect(filtered.isEmpty)
    }

    @Test("чистый кириллический текст не меняется")
    func filterPreservesCleanCyrillicText() {
        let input = "СТВОРІННЯ"
        let filtered = LongformThematicService.filterNonCyrillic(input)
        #expect(filtered == "СТВОРІННЯ")
    }

    @Test("фильтрация сохраняет цифры и знаки препинания")
    func filterPreservesDigitsAndPunctuation() {
        let input = "Текст 123 с комами, і крапкою."
        let filtered = LongformThematicService.filterNonCyrillic(input)
        #expect(filtered == input)
    }

    @Test("фильтрация смешанного текста: латинские вкрапления в кириллице")
    func filterRemovesLatinFromMixedText() {
        let input = "СТВОРІННЯ ego ОБМАН"
        let filtered = LongformThematicService.filterNonCyrillic(input)
        #expect(filtered == "СТВОРІННЯ  ОБМАН")
    }

    // MARK: - Задача 2: Фильтрация в parseThematicAnalysis

    @Test("parseThematicAnalysis фильтрует некириллические символы в word концепта")
    func parseFiltersNonCyrillicInConceptWord() {
        let json = """
        {
          "primaryConcept": {
            "word": "creation",
            "tagline": "Теглайн",
            "suggestedTitle": "Назва",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "Розбір"
        }
        """
        // Слово "creation" полностью латинское — после фильтрации станет пустым,
        // а пустой word приводит к nil из parseConcept → весь результат nil.
        let result = LongformThematicService.parseThematicAnalysis(from: json)
        #expect(result == nil)
    }

    @Test("parseThematicAnalysis фильтрует арабские символы в reason")
    func parseFiltersArabicInReason() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Его",
            "tagline": "Теглайн",
            "suggestedTitle": "Назва",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "تعريف реплікантів"
        }
        """
        let result = LongformThematicService.parseThematicAnalysis(from: json)
        let analysis = try #require(result)
        #expect(analysis.aiReasoning == " реплікантів")
    }

    // MARK: - Задача 7: Промпт без негативных конструкций

    @Test("системный промпт не содержит негативных примеров с не")
    func promptDoesNotContainNegativeExamples() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Test")
        #expect(!prompt.contains("не \"спасити\""))
        #expect(!prompt.contains("не \"спідний\""))
        #expect(!prompt.contains("не \"спасти\""))
    }

    @Test("системный промпт содержит позитивные инструкции")
    func promptContainsPositiveInstructions() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Test")
        #expect(prompt.contains("ВИКЛЮЧНО правильні українські літературні слова"))
        #expect(prompt.contains("ВРЯТУВАТИ"))
        #expect(prompt.contains("ЗБАВИТИ"))
        #expect(prompt.contains("НИЖНІЙ"))
        #expect(prompt.contains("ЕПОХА"))
    }

    // MARK: - Задача 8: Поддержка String timecodes

    @Test("String timecode парсится корректно")
    func stringTimecodeParsesCorrectly() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Его",
            "tagline": "Теглайн",
            "suggestedTitle": "Назва",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "Розбір",
          "selectedMoments": [
            {
              "startTime": "754.5",
              "endTime": "810.3",
              "reason": "Перший момент",
              "dramaticWeight": 0.85
            }
          ]
        }
        """
        let result = LongformThematicService.parseThematicAnalysis(from: json)
        let analysis = try #require(result)
        #expect(analysis.selectedMoments.count == 1)
        #expect(abs(analysis.selectedMoments[0].startTime - 754.5) < 0.01)
        #expect(abs(analysis.selectedMoments[0].endTime - 810.3) < 0.01)
    }

    @Test("Int timecode парсится корректно")
    func intTimecodeParsesCorrectly() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Его",
            "tagline": "Теглайн",
            "suggestedTitle": "Назва",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "Розбір",
          "selectedMoments": [
            {
              "startTime": 754,
              "endTime": 810,
              "reason": "Момент з цілим часом",
              "dramaticWeight": 0.9
            }
          ]
        }
        """
        let result = LongformThematicService.parseThematicAnalysis(from: json)
        let analysis = try #require(result)
        #expect(analysis.selectedMoments.count == 1)
        #expect(abs(analysis.selectedMoments[0].startTime - 754.0) < 0.01)
        #expect(abs(analysis.selectedMoments[0].endTime - 810.0) < 0.01)
    }

    @Test("Double timecode парсится корректно (исходный формат)")
    func doubleTimecodeParsesCorrectly() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Его",
            "tagline": "Теглайн",
            "suggestedTitle": "Назва",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "Розбір",
          "selectedMoments": [
            {
              "startTime": 754.5,
              "endTime": 810.3,
              "reason": "Драматичний момент",
              "dramaticWeight": 0.95
            }
          ]
        }
        """
        let result = LongformThematicService.parseThematicAnalysis(from: json)
        let analysis = try #require(result)
        #expect(analysis.selectedMoments.count == 1)
        #expect(abs(analysis.selectedMoments[0].startTime - 754.5) < 0.01)
        #expect(abs(analysis.selectedMoments[0].endTime - 810.3) < 0.01)
    }

    @Test("смешанные форматы timecodes: String и числовые в одном массиве")
    func mixedTimecodeFormatsParseCorrectly() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Его",
            "tagline": "Теглайн",
            "suggestedTitle": "Назва",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "Розбір",
          "selectedMoments": [
            {
              "startTime": "100.5",
              "endTime": "200.0",
              "reason": "Стрінговий",
              "dramaticWeight": 0.7
            },
            {
              "startTime": 500,
              "endTime": 600,
              "reason": "Цілочисельний",
              "dramaticWeight": 0.8
            },
            {
              "startTime": 900.5,
              "endTime": 1000.0,
              "reason": "Дробовий",
              "dramaticWeight": 0.9
            }
          ]
        }
        """
        let result = LongformThematicService.parseThematicAnalysis(from: json)
        let analysis = try #require(result)
        #expect(analysis.selectedMoments.count == 3)
        #expect(abs(analysis.selectedMoments[0].startTime - 100.5) < 0.01)
        #expect(abs(analysis.selectedMoments[1].startTime - 500.0) < 0.01)
        #expect(abs(analysis.selectedMoments[2].startTime - 900.5) < 0.01)
    }

    // MARK: - Задача 1: Спеллчекер (фильтрация на уровне концепта)

    @Test("фільтрація: СПРАЖНІСТЬ не містить некириличних символів і не змінюється")
    func correctCyrillicWordIsPreserved() {
        let input = "СПРАЖНІСТЬ"
        let filtered = LongformThematicService.filterNonCyrillic(input)
        #expect(filtered == "СПРАЖНІСТЬ")
    }

    @Test("фильтрация концепта: латинское слово становится пустым")
    func filterConceptCleansWordFromLatin() {
        let concept = ThematicConcept(
            word: "EGO",
            tagline: "Теглайн",
            philosophicalPremise: "Предмета",
            suggestedTitle: "Назва",
            accentColorHex: "#F5D020",
            source: .llm
        )
        let filtered = LongformThematicService.filterNonCyrillic(concept.word)
        #expect(filtered.isEmpty)
    }
}
