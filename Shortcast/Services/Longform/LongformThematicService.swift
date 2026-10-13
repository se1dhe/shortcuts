import Foundation
import MLXLMCommon

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
        4. Предложи от 3 до 5 альтернативных граней фильма (alternativeConcepts), если автор захочет смонтировать ролик с другим смысловым акцентом.
        5. Сформулируй драматургические названия и задачи ЧЕТЫРЁХ актов эссе (actDescriptors) — индивидуально под ЭТОТ фильм и ЭТУ тему, без шаблонов. Типы актов строго: "hook", "downfall", "struggle", "catharsis". Для каждого дай короткое кинематографичное название (title) и одну фразу о драматургической задаче акта (beat).

        ФОРМАТ ВЫВОДА:
        Ответь СТРОГО валидным JSON-объектом. Начинай ответ сразу с открывающей фигурной скобки '{' и заканчивай закрывающей '}' без обрамления ```json и без каких-либо вводных слов или рассуждений.
        КРИТИЧЕСКИ ВАЖНО: Внутри строковых значений (aiReasoning, philosophicalPremise, tagline, suggestedTitle) для цитат и названий используй русские кавычки «елочки», а не обычные двойные кавычки, чтобы JSON оставался валидным.
        {
          "primaryConcept": {
            "word": "Эго",
            "tagline": "Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей собственной голове.",
            "philosophicalPremise": "Единственный способ освободиться — признать, что твой враг — это не другие люди, а ты сам.",
            "suggestedTitle": "Этот фильм уничтожит твою гордость. Философия Револьвера",
            "accentColorHex": "#F5D020"
          },
          "aiReasoning": "В диалогах ключевой конфликт строится вокруг иллюзии контроля и внутреннего голоса в голове («твой лучший разводчик — это твой голос в голове»). Вся драма раскрывает победу над собственным Эго.",
          "actDescriptors": [
            {"type": "hook", "title": "Правила игры", "beat": "Сильнейший монолог, задающий тему внутреннего врага."},
            {"type": "downfall", "title": "Голос, которому ты веришь", "beat": "Разрушение уверенности: герой теряет контроль."},
            {"type": "struggle", "title": "Смерть своего эго", "beat": "Предел страха и встреча с истинным противником."},
            {"type": "catharsis", "title": "Кто дёргает за ниточки", "beat": "Освобождение от иллюзии и победа над собой."}
          ],
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

    /// Протокольный вход (без защиты от повторов): делегирует полной версии.
    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String? = nil,
        modelManager: ModelManager? = nil
    ) async throws -> ThematicAnalysisResult {
        try await discoverThematicAnalysis(
            from: transcript,
            movieTitle: movieTitle,
            movieOverview: movieOverview,
            modelManager: modelManager,
            avoidThemeWords: []
        )
    }

    /// Глубоко анализирует полный сценарий фильма и возвращает структурированный результат с ОДНОЙ главной темой.
    /// `avoidThemeWords` — темы, уже занятые другими эссе канала: модель обязана обойти их,
    /// чтобы ролики не повторялись.
    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String? = nil,
        modelManager: ModelManager? = nil,
        avoidThemeWords: [String]
    ) async throws -> ThematicAnalysisResult {
        let sampleText = Self.stratifiedThematicSample(from: transcript)

        // 1. Всегда запускаем Director LLM на реальном транскрипте Whisper, если доступен modelManager
        if let mm = modelManager, !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await mm.prepareDirectorIfNeeded()
            if let aiResult = await mm.momentFinder.analyzeThematicCore(
                transcriptSample: sampleText,
                movieTitle: movieTitle,
                movieOverview: movieOverview,
                avoidThemeWords: avoidThemeWords
            ) {
                return aiResult
            }

            // AI-путь не удался — показываем РЕАЛЬНУЮ причину вместо одинакового
            // «модель недоступна» для разных классов отказа (краш-репорт 2026-10-11).
            if case .failed(let loadError) = await mm.momentFinder.phase {
                return Self.genericFallback(
                    reasoning: "Модель недоступна — Director не загрузился: \(loadError). Проверьте сеть и место на диске, затем нажмите «Пересчитать темы с AI».")
            }
            if await mm.momentFinder.isReady {
                return Self.genericFallback(
                    reasoning: "Director-модель ответила, но результат не распознался как валидный JSON. Нажмите «Пересчитать темы с AI» ещё раз.")
            }

            // Модель не загрузилась и не в ошибке (idle/loading/downloading) — раньше
            // это молча давало одинаковый текст. Сообщаем фактическую фазу, чтобы
            // причину было видно и в UI, и в логе.
            let phase = await mm.momentFinder.phase
            MomentFinderService.log("discoverThematicAnalysis fallback: director not ready, phase=\(phase)")
            return Self.genericFallback(
                reasoning: "Модель ещё не готова (состояние: \(phase)). Обычно это нехватка памяти или незавершённая загрузка Director-модели. Закройте тяжёлые приложения и нажмите «Пересчитать темы с AI».")
        }

        // 2. modelManager не передан или сэмпл пуст — один generic-эталон.
        //    Никаких захардкоженных тем под конкретные тайтлы: LLM — единственный
        //    источник смысловых ядер, а это лишь аварийный минимум.
        return Self.genericFallback(
            reasoning: "Модель недоступна — предложен универсальный концепт преодоления. Запустите анализ снова, когда Director-модель загрузится, чтобы получить тему, выявленную из диалогов фильма.")
    }

    /// Аварийный универсальный концепт с указанной причиной фолбэка.
    private static func genericFallback(reasoning: String) -> ThematicAnalysisResult {
        let defaultConcept = ThematicConcept(
            word: "Характер",
            tagline: "Способность стоять до конца, когда весь мир против тебя.",
            philosophicalPremise: "Истинная сила проявляется в моменты, когда от тебя ничего не ждут.",
            suggestedTitle: "В этом мире нельзя быть слабым.",
            accentColorHex: "#F5D020",
            isPrimaryChoice: true
        )
        return ThematicAnalysisResult(
            primaryConcept: defaultConcept,
            aiReasoning: reasoning,
            alternativeConcepts: []
        )
    }

    func discoverConcepts(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String? = nil,
        forceAI: Bool = false,
        modelManager: ModelManager? = nil
    ) async throws -> [ThematicConcept] {
        let result = try await discoverThematicAnalysis(
            from: transcript,
            movieTitle: movieTitle,
            movieOverview: movieOverview,
            modelManager: modelManager
        )
        return result.allConcepts
    }

    /// Парсит структурированный ответ модели в ThematicAnalysisResult
    static func parseThematicAnalysis(from jsonText: String) -> ThematicAnalysisResult? {
        let clean = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        // 1. Попытка десериализации напрямую (работает для чистого JSON: и массива [...], и объекта {...})
        if let root = JSONVariantParser.deserializeTolerant(clean) {
            if let result = parseFromObject(root) {
                return result
            }
        }

        // 2. Очистка от markdown блоков ```json ... ``` если они есть
        var unwrapped = clean
        if unwrapped.contains("```") {
            let lines = unwrapped.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }
            unwrapped = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Если ответ представляет собой JSON-массив [...], находим его границы
        let firstBracket = unwrapped.firstIndex(of: "[")
        let firstBrace = unwrapped.firstIndex(of: "{")

        if let b = firstBracket, (firstBrace == nil || b < firstBrace!) {
            if let endBracket = unwrapped.range(of: "]", options: .backwards),
               b <= endBracket.lowerBound {
                let candidate = String(unwrapped[b...endBracket.lowerBound])
                if let root = JSONVariantParser.deserializeTolerant(candidate),
                   let result = parseFromObject(root) {
                    return result
                }
            }
        }

        // 4. Попытка извлечения первого сбалансированного JSON-объекта {...}
        if let jsonString = JSONVariantParser.extractJSONObject(from: unwrapped) ?? JSONVariantParser.extractJSONObject(from: clean) {
            if let root = JSONVariantParser.deserializeTolerant(jsonString),
               let result = parseFromObject(root) {
                return result
            }
        }

        if let startObj = unwrapped.range(of: "{"),
           let endObj = unwrapped.range(of: "}", options: .backwards),
           startObj.lowerBound <= endObj.lowerBound {
            let candidate = String(unwrapped[startObj.lowerBound..<endObj.upperBound])
            if let root = JSONVariantParser.deserializeTolerant(candidate),
               let result = parseFromObject(root) {
                return result
            }
        }

        // 5. Fallback: извлечение через Regex (на случай неэкранированных кавычек внутри aiReasoning)
        if let regexResult = parseWithRegex(clean) {
            return regexResult
        }

        // 4. Фолбэк на массив [ ... ] если модель вернула legacy формат
        let legacyList = parseConcepts(from: clean)
        if let first = legacyList.first {
            var primary = first
            primary.isPrimaryChoice = true
            let reasoning = "Анализ диалогов фильма выявил «\(first.word)» как определяющий конфликт сценария."
            primary.aiReasoning = reasoning
            let alts = Array(legacyList.dropFirst())
            return ThematicAnalysisResult(
                primaryConcept: primary,
                aiReasoning: reasoning,
                alternativeConcepts: alts
            )
        }

        return nil
    }

    private static func parseFromObject(_ root: Any) -> ThematicAnalysisResult? {
        if let dict = root as? [String: Any] {
            // Ищем primary concept
            var primaryDict: [String: Any]? = (dict["primaryConcept"] as? [String: Any])
                ?? (dict["primary_concept"] as? [String: Any])
                ?? (dict["primary"] as? [String: Any])
                ?? (dict["concept"] as? [String: Any])
                ?? (dict["theme"] as? [String: Any])

            // Если сам dict имеет ключ "word" (модель вернула концепт прямо в корневом объекте)
            if primaryDict == nil && (dict["word"] != nil || dict["conceptWord"] != nil) {
                primaryDict = dict
            }

            // Если концепты лежат в массиве "concepts" / "themes"
            if primaryDict == nil, let list = (dict["concepts"] as? [[String: Any]] ?? dict["themes"] as? [[String: Any]]), !list.isEmpty {
                primaryDict = list.first
            }

            guard let p = primaryDict,
                  let w = extractString(p, keys: ["word", "conceptWord", "theme", "name", "title"])
            else { return nil }

            let tag = extractString(p, keys: ["tagline", "slogan", "subtitle", "logline", "description", "summary", "quote"])
                ?? extractString(dict, keys: ["tagline", "slogan", "subtitle", "logline", "description"])
                ?? "Философский лейтмотив фильма."
            let premise = extractString(p, keys: ["philosophicalPremise", "philosophical_premise", "premise", "thesis", "idea"]) ?? tag
            let suggestedTitle = extractString(p, keys: ["suggestedTitle", "suggested_title", "title", "youtubeTitle", "youtube_title"]) ?? "Этот фильм изменит твоё восприятие."
            let accentColor = extractString(p, keys: ["accentColorHex", "accent_color_hex", "color"]) ?? "#F5D020"

            let reasoning = extractString(dict, keys: ["aiReasoning", "ai_reasoning", "reasoning", "explanation", "analysis"])
                ?? extractString(p, keys: ["aiReasoning", "ai_reasoning", "reasoning"])
                ?? "Сценарий раскрывает этот концепт как центральную философскую мысль картины."

            // Извлекаем actDescriptors
            let rawActs = (dict["actDescriptors"] as? [[String: Any]])
                ?? (dict["act_descriptors"] as? [[String: Any]])
                ?? (dict["acts"] as? [[String: Any]])
                ?? []

            let actTuples = rawActs.compactMap { d -> (type: String, title: String, beat: String)? in
                guard let typeStr = extractString(d, keys: ["type", "actType", "act_type"]),
                      let title = extractString(d, keys: ["title", "name"]),
                      let beat = extractString(d, keys: ["beat", "dramaticBeat", "dramatic_beat", "task"])
                else { return nil }
                return (typeStr, title, beat)
            }
            let descriptors = parseActDescriptors(actTuples)

            let primaryConcept = ThematicConcept(
                word: w,
                tagline: tag,
                philosophicalPremise: premise,
                suggestedTitle: suggestedTitle,
                accentColorHex: accentColor,
                isPrimaryChoice: true,
                aiReasoning: reasoning,
                actDescriptors: descriptors
            )

            // Извлекаем alternativeConcepts
            let rawAlts = (dict["alternativeConcepts"] as? [[String: Any]])
                ?? (dict["alternative_concepts"] as? [[String: Any]])
                ?? (dict["alternatives"] as? [[String: Any]])
                ?? (dict["alternativeThemes"] as? [[String: Any]])
                ?? (dict["concepts"] as? [[String: Any]])?.dropFirst().map { $0 }
                ?? []

            var altConcepts: [ThematicConcept] = []
            for item in rawAlts {
                guard let iw = extractString(item, keys: ["word", "conceptWord", "theme", "name"]),
                      let itag = extractString(item, keys: ["tagline", "slogan", "subtitle"])
                else { continue }
                let iprem = extractString(item, keys: ["philosophicalPremise", "philosophical_premise", "premise"]) ?? itag
                let ititle = extractString(item, keys: ["suggestedTitle", "suggested_title", "title"]) ?? "Правда, которую скрывает этот фильм."
                let icolor = extractString(item, keys: ["accentColorHex", "accent_color_hex", "color"]) ?? "#F5D020"

                altConcepts.append(ThematicConcept(
                    word: iw,
                    tagline: itag,
                    philosophicalPremise: iprem,
                    suggestedTitle: ititle,
                    accentColorHex: icolor,
                    isPrimaryChoice: false,
                    aiReasoning: nil
                ))
            }

            return ThematicAnalysisResult(
                primaryConcept: primaryConcept,
                aiReasoning: reasoning,
                alternativeConcepts: altConcepts
            )
        } else if let array = root as? [[String: Any]], let first = array.first {
            guard let w = extractString(first, keys: ["word", "conceptWord", "theme"]),
                  let tag = extractString(first, keys: ["tagline", "slogan", "subtitle"])
            else { return nil }
            let prem = extractString(first, keys: ["philosophicalPremise", "philosophical_premise", "premise"]) ?? tag
            let title = extractString(first, keys: ["suggestedTitle", "suggested_title", "title"]) ?? "В этом мире нельзя быть слабым."
            let color = extractString(first, keys: ["accentColorHex", "accent_color_hex"]) ?? "#F5D020"
            let reasoning = extractString(first, keys: ["aiReasoning", "ai_reasoning", "reasoning"])
                ?? "Анализ диалогов фильма выявил «\(w)» как определяющий конфликт сценария."

            let primary = ThematicConcept(
                word: w,
                tagline: tag,
                philosophicalPremise: prem,
                suggestedTitle: title,
                accentColorHex: color,
                isPrimaryChoice: true,
                aiReasoning: reasoning
            )

            let alts = array.dropFirst().compactMap { item -> ThematicConcept? in
                guard let iw = extractString(item, keys: ["word", "conceptWord", "theme"]),
                      let itag = extractString(item, keys: ["tagline", "slogan", "subtitle"])
                else { return nil }
                return ThematicConcept(
                    word: iw,
                    tagline: itag,
                    philosophicalPremise: extractString(item, keys: ["philosophicalPremise", "premise"]) ?? itag,
                    suggestedTitle: extractString(item, keys: ["suggestedTitle", "title"]) ?? "Правда сценария.",
                    accentColorHex: extractString(item, keys: ["accentColorHex"]) ?? "#F5D020",
                    isPrimaryChoice: false
                )
            }

            return ThematicAnalysisResult(
                primaryConcept: primary,
                aiReasoning: reasoning,
                alternativeConcepts: alts
            )
        }
        return nil
    }

    private static func extractString(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let str = dict[k] as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func parseWithRegex(_ raw: String) -> ThematicAnalysisResult? {
        func extractField(pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            if let match = regex.firstMatch(in: raw, options: [], range: nsRange) {
                for i in 1..<match.numberOfRanges {
                    let r = match.range(at: i)
                    if r.location != NSNotFound, let range = Range(r, in: raw) {
                        let val = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !val.isEmpty { return val }
                    }
                }
            }
            return nil
        }

        guard let word = extractField(pattern: #""(?:word|conceptWord|theme|name)"\s*:\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|«([^»]*)»)"#) else {
            return nil
        }
        let tagline = extractField(pattern: #""(?:tagline|slogan|subtitle|logline|description)"\s*:\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|«([^»]*)»)"#)
            ?? "Философский лейтмотив фильма."
        let premise = extractField(pattern: #""(?:philosophicalPremise|philosophical_premise|premise|thesis)"\s*:\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|«([^»]*)»)"#)
            ?? tagline
        let suggestedTitle = extractField(pattern: #""(?:suggestedTitle|suggested_title|title)"\s*:\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|«([^»]*)»)"#)
            ?? "Этот фильм изменит твоё восприятие."
        let reasoning = extractField(pattern: #""(?:aiReasoning|ai_reasoning|reasoning|explanation)"\s*:\s*(?:"([^"\\]*(?:\\.[^"\\]*)*)"|«([^»]*)»)"#)
            ?? "Анализ сценария фильма выявил концепт «\(word)» как определяющую мысль сюжета."

        let primary = ThematicConcept(
            word: word,
            tagline: tagline,
            philosophicalPremise: premise,
            suggestedTitle: suggestedTitle,
            accentColorHex: "#F5D020",
            isPrimaryChoice: true,
            aiReasoning: reasoning
        )

        return ThematicAnalysisResult(
            primaryConcept: primary,
            aiReasoning: reasoning,
            alternativeConcepts: []
        )
    }

    /// Парсит список (type, title, beat) от LLM в `[LongformActDescriptor]`,
    /// сопоставляя строковые типы с 4-актной структурой. Порядок сохраняется
    /// как hook → downfall → struggle → catharsis независимо от порядка в ответе.
    static func parseActDescriptors(_ raw: [(type: String, title: String, beat: String)]) -> [LongformActDescriptor] {
        func actType(from value: String) -> LongformActType? {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "hook": return .hook
            case "downfall": return .downfall
            case "struggle": return .struggle
            case "catharsis": return .catharsis
            default: return nil
            }
        }
        var byType: [LongformActType: LongformActDescriptor] = [:]
        for entry in raw {
            guard let type = actType(from: entry.type) else { continue }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let beat = entry.beat.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            byType[type] = LongformActDescriptor(type: type, title: title, beat: beat)
        }
        return LongformActType.allCases.compactMap { byType[$0] }
    }

    /// Парсит структурированный ответ модели в список ThematicConcept (для совместимости)
    static func parseConcepts(from jsonText: String) -> [ThematicConcept] {
        var clean = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = clean.range(of: "["),
           let end = clean.range(of: "]", options: .backwards),
           start.lowerBound <= end.lowerBound {
            clean = String(clean[start.lowerBound..<end.upperBound])
        }

        struct RawConcept: Decodable {
            let word: String?
            let tagline: String?
            let philosophicalPremise: String?
            let suggestedTitle: String?
            let accentColorHex: String?
        }

        if let data = clean.data(using: .utf8),
           let rawList = try? JSONDecoder().decode([RawConcept].self, from: data) {
            let parsed = rawList.compactMap { item -> ThematicConcept? in
                guard let w = item.word?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty,
                      let tag = item.tagline?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty,
                      let prem = item.philosophicalPremise?.trimmingCharacters(in: .whitespacesAndNewlines), !prem.isEmpty,
                      let title = item.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
                else { return nil }
                return ThematicConcept(
                    word: w,
                    tagline: tag,
                    philosophicalPremise: prem,
                    suggestedTitle: title,
                    accentColorHex: item.accentColorHex ?? "#F5D020"
                )
            }
            if !parsed.isEmpty {
                return parsed
            }
        }

        return []
    }

}
