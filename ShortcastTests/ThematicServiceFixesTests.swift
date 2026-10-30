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

    // MARK: - Проза: слоты наполняет только текст модели

    private static func productText(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ShortcastTests/
            .deletingLastPathComponent()   // корень репозитория
            .appendingPathComponent("Shortcast", isDirectory: true)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("тезис без текста модели остаётся пустым, а не клоном слогана")
    func missingPremiseStaysEmptyInsteadOfCloningTagline() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Слоган, який бачить екран",
            "suggestedTitle": "Назва для YouTube"
          },
          "aiReasoning": "Розбір від моделі"
        }
        """
        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        let premise = analysis.primaryConcept.philosophicalPremise
        #expect(premise.isEmpty, "в слот тезиса подставили чужий текст: «\(premise)»")
        #expect(premise != analysis.primaryConcept.tagline)
        #expect(analysis.aiReasoning == "Розбір від моделі")
    }

    @Test("пробельный тезис не превращается в слоган")
    func blankPremiseStaysEmptyToo() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Слоган, який бачить екран",
            "philosophicalPremise": "   ",
            "suggestedTitle": "Назва для YouTube"
          },
          "aiReasoning": "Розбір від моделі"
        }
        """
        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        #expect(analysis.primaryConcept.philosophicalPremise.isEmpty)
    }

    @Test("тезис, написанный моделью, остаётся её текстом")
    func premiseFromModelIsPreserved() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Слоган, який бачить екран",
            "philosophicalPremise": "Тез, який написала модель",
            "suggestedTitle": "Назва для YouTube"
          },
          "aiReasoning": "Розбір від моделі"
        }
        """
        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        #expect(analysis.primaryConcept.philosophicalPremise == "Тез, який написала модель")
        #expect(analysis.primaryConcept.tagline == "Слоган, який бачить екран")
    }

    @Test("legacy-массив без тезиса и без reasoning — nil, а не слоган в обосновании")
    func legacyArrayWithoutReasoningOrPremiseIsNil() {
        let array = """
        [
          {
            "word": "Ілюзія",
            "tagline": "Слоган, який бачить екран",
            "suggestedTitle": "Назва для YouTube"
          }
        ]
        """
        #expect(LongformThematicService.parseThematicAnalysis(from: array) == nil)
    }

    @Test("legacy-массив берёт обоснование из своих ключей, а не из слогана")
    func legacyArrayUsesItsOwnReasoning() throws {
        let array = """
        [
          {
            "word": "Ілюзія",
            "tagline": "Слоган, який бачить екран",
            "suggestedTitle": "Назва для YouTube",
            "reasoning": "Обґрунтування, яке модель дописала сама"
          }
        ]
        """
        let analysis = try #require(LongformThematicService.parseThematicAnalysis(from: array))
        #expect(analysis.aiReasoning == "Обґрунтування, яке модель дописала сама")
        #expect(analysis.aiReasoning != analysis.primaryConcept.tagline)
        #expect(analysis.primaryConcept.philosophicalPremise.isEmpty)
    }

    /// Переливка чужого поля в слот прозы — это подделка авторства, поэтому ловим
    /// её механически по исходнику парсера, а не только на фикстурах выше.
    @Test("парсер темы не переливает чужие поля в слоты прозы")
    func parserNeverPoursAnotherFieldIntoAProseSlot() throws {
        let text = try Self.productText("Services/Longform/LongformThematicService.swift")
        let code = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        for forbidden in ["tagline", "suggestedTitle"] {
            for line in code where line.contains("??") {
                #expect(
                    !line.contains(forbidden),
                    "вернулась переливка «\(forbidden)»: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    // MARK: - Бейдж провенанса: источник ровно того текста, что под ним

    @Test("бейдж названия акта читает источник самого акта")
    func actTitleBadgeReadsTheActsOwnSource() throws {
        let editor = try Self.productText("Views/Longform/LongformActEditorView.swift")
        let results = try Self.productText("Views/Longform/LongformResultsView.swift")

        // Редактор больше не выводит метку «из провенанса с дефолтом»: у него
        // то же правило, что у экрана результата, — nil это `.unknown`.
        #expect(editor.contains("var effectiveTitleSource: ActTitleSource"))
        for file in [(editor, "LongformActEditorView"), (results, "LongformResultsView")] {
            #expect(file.0.contains("effectiveTitleSource.isTrustworthy"), "\(file.1): бейдж не из источника акта")
            #expect(!file.0.contains("titleProvenance?.source.isTrustworthy"), "\(file.1): метка выведена из значения по умолчанию")
        }
        // Провенанс анализа/темы целиком не имеет права подписывать название акта.
        for file in [(editor, "LongformActEditorView"), (results, "LongformResultsView")] {
            #expect(!file.0.contains("concept.source"), "\(file.1): бейдж акта берёт источник темы")
            #expect(!file.0.contains("analysis?.source"), "\(file.1): бейдж акта берёт источник анализа")
        }
    }
}
