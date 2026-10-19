import Foundation

/// Реализация ThematicConceptDiscovering для выявления тем Shortcast Cinema (SOLID)
final class LongformThematicService: ThematicConceptDiscovering, Sendable {

    /// Подсказка для LLM в роли сценариста-философа и вирусного YouTube-режиссера
    static func thematicSystemPrompt(movieTitle: String) -> String {
        """
        Ты — элитный кинорежиссер, драматург и автор глубоких философских видео-эссе на YouTube для Shortcast Cinema.
        Твоя задача — проанализировать полный хронологический срез сценария фильма «\(movieTitle)», глубоко понять скрытый психологический и экзистенциальный конфликт героев и САМОСТОЯТЕЛЬНО ВЫБРАТЬ И ПРЕДЛОЖИТЬ ОДНУ ГЛАВНУЮ ТЕМУ ЭССЕ (например, «Эго» для фильма «Револьвер», «Бунт» для «Бойцовского клуба», «Власть» для «Крёстного отца» или то фундаментальное ядро, которое ты извлек из диалогов).

        Требования к анализу:
        1. Выяви ОДНО мощное якорное слово темы (word) с большой буквы (например: «ЭГО», «ОБМАН», «СТРАХ», «ТЕРПЕНИЕ», «ГЕНИАЛЬНОСТЬ», «ВЛАСТЬ»).
        2. Сформулируй глубокий драматургический разбор сценария (aiReasoning): объясни автору эссе, почему именно эта тема является скрытым двигателем сюжета, как она раскрывается в поступках героев и почему зритель будет поражен этим смыслом.
        3. Предложи хлесткий слоган (tagline, 1 предложение), философский тезис о цене выбора/успеха (philosophicalPremise) и вирусный YouTube-заголовок от 2-го лица (suggestedTitle).
        4. Предложи РОВНО 3 альтернативные грани фильма (alternativeConcepts), если автор захочет смонтировать ролик с другим смысловым акцентом.

        ФОРМАТ ВЫВОДА:
        Ответь СТРОГО валидным JSON-объектом без лишних предисловий и комментариев:
        {
          "primaryConcept": {
            "word": "Эго",
            "tagline": "Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей собственной голове.",
            "philosophicalPremise": "Единственный способ освободиться — признать, что твой враг — это не другие люди, а ты сам.",
            "suggestedTitle": "Этот фильм уничтожит твою гордость. Философия Револьвера",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "В диалогах ключевой конфликт строится вокруг иллюзии контроля и внутреннего голоса в голове («твой лучший разводчик — это твой голос в голове»). Вся драма раскрывает победу над собственным Эго.",
          "alternativeConcepts": [
            {
              "word": "Обман",
              "tagline": "Единственный способ стать умнее — играть с более умным противником.",
              "philosophicalPremise": "Первое правило шахмат: защищай свои интересы, понимая истинную игру манипулятора.",
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
