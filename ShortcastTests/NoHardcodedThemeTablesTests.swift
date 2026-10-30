import Testing
import Foundation
@testable import Shortcast

/// Анти-хардкод. Правило владельца: лингвистические правила остаются, данные о
/// содержимом уходят. Тест сканирует продуктивный код, потому что список
/// «правильных тем» нельзя ни вынести в конфиг, ни починить точечной правкой —
/// его можно только удалить, и он обязан оставаться удалённым.
@Suite("No hardcoded theme tables")
struct NoHardcodedThemeTablesTests {

    private static let productRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ShortcastTests/
        .deletingLastPathComponent()   // корень репозитория
        .appendingPathComponent("Shortcast", isDirectory: true)

    /// Все .swift продукта, кроме Vendor.
    private static func productSources() throws -> [(path: String, text: String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: productRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(String, String)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append((url.path.replacingOccurrences(of: productRoot.path + "/", with: ""), text))
        }
        return files
    }

    /// Один конкретный файл продукта по пути от `Shortcast/` — для проверок, у
    /// которых есть адресат (экран выбора темы), а не только общий запрет.
    private static func productText(_ relativePath: String) throws -> String {
        let url = productRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Содержимое строковых литералов одной строки-аргумента: объявления полей и
    /// ключи JSON в промпте мимо нас проходят, а вот значение `tagline:` с нашей
    /// фразой внутри — уже изобретение содержимого.
    private static func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            var current = ""
            i += 1
            while i < chars.count {
                if chars[i] == "\\" && i + 1 < chars.count {
                    if chars[i + 1] == "(" {
                        // Интерполяция: её содержимое — переменные, а не наш текст.
                        var depth = 1
                        i += 2
                        while i < chars.count && depth > 0 {
                            if chars[i] == "(" { depth += 1 }
                            if chars[i] == ")" { depth -= 1 }
                            i += 1
                        }
                        continue
                    }
                    current.append(chars[i + 1])
                    i += 2
                    continue
                }
                if chars[i] == "\"" { break }
                current.append(chars[i])
                i += 1
            }
            literals.append(current)
            i += 1
        }
        return literals
    }

    /// Кириллические слова (русская или украинская проза — обе запрещены как наше
    /// содержимое) длиной от 3 букв: «и», «не», «до» фразу не создают.
    private static func cyrillicWords(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.filter { $0.count >= 3 }
    }

    /// Слова, которые когда-то лежали в промпте как «примеры правильных тем», и
    /// местоимение, из-за которого всё и началось.
    private static let poisonedWords = [
        "СВОБОДА", "ОБМАН", "СТРАХ", "ТЕРПІННЯ", "ВЛАДА", "ГЕНІАЛЬНІСТЬ", "ЕГО", "ЙОГО",
    ]

    @Test("no hardcoded theme table survives in product code")
    func noThemeTables() throws {
        let sources = try Self.productSources()
        #expect(!sources.isEmpty, "не нашёл исходники продукта — тест ничего не проверяет")

        for file in sources {
            #expect(
                !file.text.contains("semanticThematicMap"),
                "\(file.path): вернулась таблица тематических слов")
            for word in Self.poisonedWords {
                let quoted = "\"\(word)\""
                if file.text.contains(quoted) {
                    // Единственное законное вхождение — стоп-лист служебных слов
                    // субтитров, где «ЙОГО» отклоняется, а не предлагается.
                    #expect(
                        file.path.hasPrefix("Services/SubtitleRenderer.swift"),
                        "\(file.path): тема «\(word)» зашита в код")
                    #expect(
                        file.text.contains("minorWords"),
                        "\(file.path): «\(word)» вне стоп-листа служебных слов")
                }
            }
        }
    }

    @Test("clickbait title formulas are gone")
    func noClickbaitFormulas() throws {
        for file in try Self.productSources() {
            for fragment in ["Ти програєш, поки віриш", "Що б ти не робив", "Чому ти програєш"] {
                #expect(!file.text.contains(fragment), "\(file.path): формула заголовка «\(fragment)»")
            }
        }
    }

    /// То же самое, что и кликбейт-формулы, но для ручной темы: экран когда-то
    /// подставлял своё предложение в `suggestedTitle`, и оно уходило в
    /// опубликованное название YouTube. Фраза вымышленная, а провенанс — `.manual`,
    /// поэтому её не ловил ни один из предыдущих проверок.
    @Test("invented sentences never become the manual theme's text")
    func noInventedManualThemeSentences() throws {
        for file in try Self.productSources() {
            for fragment in [
                "Ты никогда не поймёшь",
                "Сквозное эссе вокруг идеи",
                "Исследование цены успеха",
            ] {
                #expect(!file.text.contains(fragment), "\(file.path): выдуманная фраза «\(fragment)»")
            }
        }
    }

    /// Механический класс ловушки, а не список строк: текстовые поля концепта
    /// обязан наполнять вывод модели или текст пользователя, поэтому литерал с
    /// целой фразой на кириллице в позиции значения — это изобретение содержимого.
    /// Единственное законное кириллическое вложение — плейсхолдер JSON-схемы в
    /// промпте (`<СЛОГАН ДО 20 СЛІВ>`): он описывает форму, а не тему.
    @Test("no prose sentence is hardcoded as a concept text field value")
    func noHardcodedProseDefaults() throws {
        let fields = ["tagline", "philosophicalPremise", "suggestedTitle"]

        for file in try Self.productSources() {
            for line in file.text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let matched = fields.filter {
                    trimmed.hasPrefix("\($0):") || trimmed.hasPrefix("\($0) =") || trimmed.hasPrefix("\"\($0)\":")
                }
                guard let field = matched.first else { continue }

                for literal in Self.stringLiterals(in: trimmed) {
                    let placeholder = literal.hasPrefix("<") && literal.hasSuffix(">")
                    #expect(
                        placeholder || Self.cyrillicWords(literal).count <= 2,
                        "\(file.path): \(field) получает зашитую фразу «\(literal)»")
                }
            }
        }
    }

    /// Ручная тема обязана оставаться пустой, а не «чуть-чуть дописанной»:
    /// пустое значение — это честное «текста нет», любое наше слово — изобретение.
    @Test("the sheet's manual theme carries only the user's own words")
    func manualThemeStaysHonest() throws {
        let sheet = try Self.productText("Views/Longform/ThematicConceptSelectionSheet.swift")

        #expect(sheet.contains("tagline: \"\""), "ручной теме снова дописали слоган")
        #expect(sheet.contains("philosophicalPremise: \"\""), "ручной теме снова дописали тезис")
        #expect(
            sheet.contains("suggestedTitle: customTitle"),
            "ручной теме снова подставлен заголовок по умолчанию")
        // Провенанс ручной темы не имеет притворяться модельным.
        #expect(sheet.contains("source: .manual"))

        // Обратное тоже правда: пустую ручную тему нельзя молча отклонять гейтом
        // прозы модели — `DirectorArtifactGate.concept` стоит только на разборе
        // ответа модели в сервисах, но не в экранах выбора.
        for file in try Self.productSources() where file.path.hasPrefix("Views/") {
            #expect(
                !file.text.contains("DirectorArtifactGate.concept("),
                "\(file.path): выбор пользователя прогоняется через гейт прозы модели")
        }
    }

    /// Словарь `[String: [String]]` в слое Longform — это и есть форма, которой
    /// когда-то была таблица тем. Единственное законное вложение — история
    /// просмотров в UserDefaults.
    @Test("no theme-shaped dictionaries in the longform layer")
    func noThemeShapedDictionaries() throws {
        for file in try Self.productSources() where file.path.hasPrefix("Services/Longform/") {
            guard file.text.contains("[String: [String]]") else { continue }
            #expect(
                file.path.hasPrefix("Services/Longform/LongformHistoryService.swift"),
                "\(file.path): словарь «тема -> список» вернулся")
        }
    }

    /// Живой промпт, а не файл: меню тем могло уйти из кода и остаться в тексте,
    /// который уходит модели.
    @Test("the prompts the model actually receives carry no theme menu")
    func promptsOfferNoMenu() {
        let stage1 = DirectorStagedAnalysis.candidatesInstructions(movieTitle: "Фільм")
        let stage2 = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")
        for text in [stage1, stage2] {
            for word in Self.poisonedWords {
                #expect(!text.contains("«\(word)»"), "промпт подсовывает тему «\(word)»")
            }
        }
        // Этап 1 обязан сказать, что пример — это формат, а не содержимое.
        #expect(stage1.contains("ФОРМАТУ, а НЕ змісту"))
        // И ни одно из правил не «подсказывает тему»: только форму.
        #expect(stage1.contains("Ми НЕ даємо тобі списку тем"))
    }

    /// Конечный критерий из плана: `.llm` — только когда слово реально напечатала
    /// модель. По умолчанию провенанса нет ни у чего.
    @Test("nothing is credited to the model by default")
    func provenanceDefaultsToUnknown() throws {
        let bare = ThematicConcept(
            word: "ВИБІР", tagline: "т", philosophicalPremise: "п", suggestedTitle: "з")
        #expect(bare.source == .unknown)
        #expect(!bare.source.isTrustworthy)

        let decoded = try JSONDecoder().decode(
            ThematicConcept.self,
            from: Data("""
            {"word":"ВИБІР","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з"}
            """.utf8))
        #expect(decoded.source == .unknown)

        let analysis = ThematicAnalysisResult(
            primaryConcept: bare, aiReasoning: "Р")
        #expect(analysis.source == .unknown)
        #expect(analysis.primaryConcept.source == .unknown)
    }
}
