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

    /// Глубоко анализирует полный сценарий фильма и возвращает структурированный результат с ОДНОЙ главной темой
    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String? = nil,
        modelManager: ModelManager? = nil
    ) async throws -> ThematicAnalysisResult {
        let sampleText = Self.stratifiedThematicSample(from: transcript)

        // 1. Всегда запускаем Director LLM на реальном транскрипте Whisper, если доступен modelManager
        if let mm = modelManager, !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await mm.prepareDirectorIfNeeded()
            if let aiResult = await mm.momentFinder.analyzeThematicCore(
                transcriptSample: sampleText,
                movieTitle: movieTitle,
                movieOverview: movieOverview
            ) {
                return aiResult
            }
        }

        // 2. Если модель недоступна или запрос не вернул структуру — один generic-эталон.
        //    Никаких захардкоженных тем под конкретные тайтлы: LLM — единственный
        //    источник смысловых ядер, а это лишь аварийный минимум.
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
            aiReasoning: "Модель недоступна — предложен универсальный концепт преодоления. Запустите анализ снова, когда Director-модель загрузится, чтобы получить тему, выявленную из диалогов фильма.",
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
        var clean = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Снимаем markdown обертки ```json ... ```
        if clean.hasPrefix("```") {
            let lines = clean.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }
            clean = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 1. Попытка распарсить как объект { "primaryConcept": ..., "aiReasoning": ..., "alternativeConcepts": ... }
        if let startObj = clean.range(of: "{"),
           let endObj = clean.range(of: "}", options: .backwards),
           startObj.lowerBound <= endObj.lowerBound {
            let objJSON = String(clean[startObj.lowerBound..<endObj.upperBound])
            if let data = objJSON.data(using: .utf8) {
                struct RawObjectResponse: Decodable {
                    struct RawConcept: Decodable {
                        let word: String?
                        let tagline: String?
                        let philosophicalPremise: String?
                        let suggestedTitle: String?
                        let accentColorHex: String?
                    }
                    struct RawActDescriptor: Decodable {
                        let type: String?
                        let title: String?
                        let beat: String?
                    }
                    let primaryConcept: RawConcept?
                    let aiReasoning: String?
                    let actDescriptors: [RawActDescriptor]?
                    let alternativeConcepts: [RawConcept]?
                }

                if let parsed = try? JSONDecoder().decode(RawObjectResponse.self, from: data),
                   let p = parsed.primaryConcept,
                   let w = p.word?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty,
                   let tag = p.tagline?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                    
                    let reasoning = parsed.aiReasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Сценарий раскрывает этот концепт как центральную философскую мысль картины."

                    let descriptors = Self.parseActDescriptors(parsed.actDescriptors?.compactMap { d in
                        guard let typeStr = d.type, let title = d.title, let beat = d.beat else { return nil }
                        return (typeStr, title, beat)
                    } ?? [])

                    let primaryConcept = ThematicConcept(
                        word: w,
                        tagline: tag,
                        philosophicalPremise: p.philosophicalPremise?.trimmingCharacters(in: .whitespacesAndNewlines) ?? tag,
                        suggestedTitle: p.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Этот фильм изменит твоё восприятие.",
                        accentColorHex: p.accentColorHex ?? "#F5D020",
                        isPrimaryChoice: true,
                        aiReasoning: reasoning,
                        actDescriptors: descriptors
                    )

                    let alts = (parsed.alternativeConcepts ?? []).compactMap { item -> ThematicConcept? in
                        guard let iw = item.word?.trimmingCharacters(in: .whitespacesAndNewlines), !iw.isEmpty,
                              let itag = item.tagline?.trimmingCharacters(in: .whitespacesAndNewlines), !itag.isEmpty else { return nil }
                        return ThematicConcept(
                            word: iw,
                            tagline: itag,
                            philosophicalPremise: item.philosophicalPremise?.trimmingCharacters(in: .whitespacesAndNewlines) ?? itag,
                            suggestedTitle: item.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Правда, которую скрывает этот фильм.",
                            accentColorHex: item.accentColorHex ?? "#F5D020",
                            isPrimaryChoice: false,
                            aiReasoning: nil
                        )
                    }

                    return ThematicAnalysisResult(
                        primaryConcept: primaryConcept,
                        aiReasoning: reasoning,
                        alternativeConcepts: alts
                    )
                }
            }
        }

        // 2. Фолбэк на массив [ ... ] если модель вернула legacy формат
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
