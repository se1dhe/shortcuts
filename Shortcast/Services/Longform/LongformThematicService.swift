import Foundation

/// Реализация ThematicConceptDiscovering для выявления тем Shortcast Cinema (SOLID)
final class LongformThematicService: ThematicConceptDiscovering, Sendable {

    /// Подсказка для LLM в роли сценариста-философа и вирусного YouTube-режиссера
    static func thematicSystemPrompt(movieTitle: String) -> String {
        """
        Ти — елітний кінорежисер, драматург і автор глибоких філософських відео-есів на YouTube для Shortcast Cinema.
        Твоє завдання — проаналізувати повний хронологічний зріз сценарію фільму «\(movieTitle)», глибо зрозуміти прихований психологічний та екзистенційний конфлікт героїв і САМОСТІЙНО ОБРАТИ І ЗАПРОПОНУВАТИ ОДНУ ГОЛОВНУ ТЕМУ ЕСЕ (наприклад, «Его» для фільму «Револьвер», «Бунт» для «Бійцівського клубу», «Влада» для «Хрещеного батька» або те фундаментальне ядро, яке ти видобув із діалогів).

        Вимоги до аналізу:
        1. Вияви ОДНЕ потужне якірне слово теми (word) з великої літери (наприклад: «ЕГО», «ОБМАН», «СТРАХ», «ТЕРПІННЯ», «ГЕНІАЛЬНІСТЬ», «ВЛАДА»).
        2. Сформулюй глибокий драматургічний розбір сценарію (aiReasoning): поясни автору есе, чому саме ця тема є прихованим двигуном сюжету, як вона розкривається у вчинках героїв і чому глядач буде вражений цим сенсом.
        3. Запропонуй гострий слоган (tagline, 1 речення), філософський тез про ціну вибору/успіху (philosophicalPremise) та вірусний YouTube-заголовок від 2-ї особи (suggestedTitle).
        4. Запропонуй РІВНО 3 альтернативні грані фільму (alternativeConcepts), якщо автор захоче змонтувати ролик з іншим сенсовим акцентом.

        ФОРМАТ ВИВОДУ:
        Відповідь СУВОРО валідним JSON-об'єктом без зайвих передмов і коментарів:
        {
          "primaryConcept": {
            "word": "Его",
            "tagline": "Твій головний ворог ховається там, де ти найменше будеш його шукати — в твоїй власній голові.",
            "philosophicalPremise": "Єдиний спосіб звільнитися — визнати, що твій ворог — це не інші люди, а ти сам.",
            "suggestedTitle": "Цей фільм знищить твою гординю. Філософія Револьвера",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "У діалогах ключовий конфлікт будується навколо ілюзії контролю та внутрішнього голосу в голові («твій найкращий розводчик — це твій голос у голові»). Вся драма розкриває перемогу над власним Его.",
          "alternativeConcepts": [
            {
              "word": "Обман",
              "tagline": "Єдиний спосіб стати розумнішим — грати з розумнішим суперником.",
              "philosophicalPremise": "Перше правило шахів: захищай свої інтереси, розуміючи справжню гру маніпулятора.",
              "suggestedTitle": "Ти програєш, якщо не зрозумієш цю розводку.",
              "accentColorHex": "#F5D020"
            },
            {
              "word": "Страх",
              "tagline": "Страх втрати контролю руйнує людину швидше за будь-яку кулю.",
              "philosophicalPremise": "Поки ти боїшся втратити те, чим дорожиш — тобою керує хтось інший.",
              "suggestedTitle": "Твій головний страх керує кожним твоїм рішенням.",
              "accentColorHex": "#E50914"
            }
          ]
        }
        """
    }

    /// Сжимает ВЕСЬ транскрипт в хронологический срез для LLM: соседние реплики
    /// одной сцены (пауза < 0.8с) сливаются в одну строку с таймкодом начала.
    /// Формат `[MM:SS] текст` без дробных секунд и пустых строк — максимум
    /// покрытия сюжета при минимуме символов. `targetSegmentsCount` больше не
    /// используется как квота (оставлен для совместимости сигнатуры).
    static func stratifiedThematicSample(from transcript: Transcript, targetSegmentsCount: Int = 0) -> String {
        let segments = transcript.segments.filter { seg in
            !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !segments.isEmpty else { return "" }

        var lines: [String] = []
        var sceneStart = segments[0].start
        var sceneEnd = segments[0].end
        var sceneText = segments[0].text.trimmingCharacters(in: .whitespacesAndNewlines)

        for seg in segments.dropFirst() {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let gap = seg.start - sceneEnd
            if gap < 0.8 {
                sceneText += " " + text
                sceneEnd = seg.end
            } else {
                lines.append(formatCompressedLine(start: sceneStart, text: sceneText))
                sceneStart = seg.start
                sceneEnd = seg.end
                sceneText = text
            }
        }
        lines.append(formatCompressedLine(start: sceneStart, text: sceneText))

        return lines.joined(separator: "\n")
    }

    private static func formatCompressedLine(start: Double, text: String) -> String {
        let minutes = Int(start) / 60
        let seconds = Int(start) % 60
        return String(format: "[%02d:%02d] %@", minutes, seconds, text)
    }

    private static func formatSegmentForPrompt(_ seg: TranscriptSegment) -> String {
        formatCompressedLine(start: seg.start, text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }


    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        modelManager: ModelManager,
        directorProfile: ChatModelProfile
    ) async throws -> ThematicAnalysisResult {
        let sampleText = Self.stratifiedThematicSample(from: transcript)
        guard !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThematicDiscoveryError.transcriptEmpty
        }

        try await modelManager.requireDirector(profile: directorProfile)
        return try await modelManager.momentFinder.analyzeThematicCore(
            transcriptSample: sampleText,
            movieTitle: movieTitle,
            movieOverview: movieOverview
        )
    }

    /// Парсит ответ модели в структурированный результат. nil означает
    /// «модель не справилась» — вызывающий обязан показать это, а не
    /// подставлять заготовку. word/tagline/suggestedTitle обязательны: их
    /// должна написать модель, а не код.
    static func parseThematicAnalysis(from jsonText: String) -> ThematicAnalysisResult? {
        if let jsonString = JSONVariantParser.extractJSONObject(from: jsonText),
           let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any],
           let primary = parseConcept(root["primaryConcept"]),
           let reasoning = nonEmptyString(root["aiReasoning"]) {
            return makeResult(primary: primary, reasoning: reasoning, alternatives: conceptArray(root["alternativeConcepts"]))
        }

        // Модель иногда возвращает массив вместо объекта: первая грань и есть главная тема.
        if let array = tolerantArray(from: jsonText), let head = array.first,
           let primary = parseConcept(head) {
            let reasoning = nonEmptyString(primary.philosophicalPremise) ?? primary.tagline
            return makeResult(primary: primary, reasoning: reasoning, alternatives: conceptArray(Array(array.dropFirst())))
        }

        return nil
    }

    private static func makeResult(
        primary: ThematicConcept,
        reasoning: String,
        alternatives: [ThematicConcept]
    ) -> ThematicAnalysisResult {
        var main = primary
        main.isPrimaryChoice = true
        main.aiReasoning = reasoning
        return ThematicAnalysisResult(
            primaryConcept: main,
            aiReasoning: reasoning,
            alternativeConcepts: alternatives,
            source: .llm
        )
    }

    private static func conceptArray(_ value: Any?) -> [ThematicConcept] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { parseConcept($0) }
    }

    private static func parseConcept(_ value: Any?) -> ThematicConcept? {
        guard let dict = value as? [String: Any],
              let word = nonEmptyString(dict["word"]),
              let tagline = nonEmptyString(dict["tagline"]),
              let title = nonEmptyString(dict["suggestedTitle"])
        else { return nil }

        return ThematicConcept(
            word: word,
            tagline: tagline,
            philosophicalPremise: nonEmptyString(dict["philosophicalPremise"]) ?? tagline,
            suggestedTitle: title,
            accentColorHex: nonEmptyString(dict["accentColorHex"]) ?? "#F5D020",
            source: .llm
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tolerantArray(from raw: String) -> [[String: Any]]? {
        guard let start = raw.firstIndex(of: "["),
              let parsed = JSONVariantParser.deserializeTolerant(String(raw[start...])) as? [[String: Any]]
        else { return nil }
        return parsed.isEmpty ? nil : parsed
    }
}
