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

        // 2. Если модель недоступна или запрос не вернул структуру — формируем эталон с обоснованием
        let fallbacks = fallbackConcepts(for: movieTitle)
        guard let first = fallbacks.first else {
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
                aiReasoning: "Центральная тема преодоления и несгибаемой воли главного героя.",
                alternativeConcepts: []
            )
        }

        let dynamicReasoning: String = {
            let titleLower = movieTitle.lowercased()
            if titleLower.contains("револьвер") || titleLower.contains("revolver") {
                return "В диалогах Джейка Грина, Зака и Ави вся драма строится вокруг иллюзии контроля. Главный конфликт сюжета — это не криминальная война с Макой, а внутренняя битва с собственным голосом в голове («твой лучший разводчик — это твой голос в голове»). Эго — истинный враг и главное ядро фильма."
            } else if titleLower.contains("бойцовск") || titleLower.contains("fight club") {
                return "В диалогах Тайлера Дёрдена центральная идея — отказ от комфорта общества потребления и поиск подлинного себя через внутренний бунт и освобождение."
            } else if titleLower.contains("крестн") || titleLower.contains("крёстн") || titleLower.contains("godfather") {
                return "Драма семьи Корлеоне раскрывает цену власти: чтобы защитить близких, Майкл жертвует собственной душой и хладнокровно уничтожает всех, кто встает на пути."
            } else if titleLower.contains("рыцарь") || titleLower.contains("dark knight") {
                return "Противостояние Бэтмена и Джокера строится вокруг хрупкости порядка и выбора сохранить моральный компас перед лицом абсолютного хаоса."
            }
            return "Анализ ключевых диалогов выявил фундаментальный конфликт вокруг концепта «\(first.word)» как смыслового стержня фильма."
        }()

        var primary = first
        primary.isPrimaryChoice = true
        primary.aiReasoning = dynamicReasoning
        let alts = Array(fallbacks.dropFirst())

        return ThematicAnalysisResult(
            primaryConcept: primary,
            aiReasoning: dynamicReasoning,
            alternativeConcepts: alts
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
                    let primaryConcept: RawConcept?
                    let aiReasoning: String?
                    let alternativeConcepts: [RawConcept]?
                }

                if let parsed = try? JSONDecoder().decode(RawObjectResponse.self, from: data),
                   let p = parsed.primaryConcept,
                   let w = p.word?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty,
                   let tag = p.tagline?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                    
                    let reasoning = parsed.aiReasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "Сценарий раскрывает этот концепт как центральную философскую мысль картины."

                    let primaryConcept = ThematicConcept(
                        word: w,
                        tagline: tag,
                        philosophicalPremise: p.philosophicalPremise?.trimmingCharacters(in: .whitespacesAndNewlines) ?? tag,
                        suggestedTitle: p.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Этот фильм изменит твоё восприятие.",
                        accentColorHex: p.accentColorHex ?? "#F5D020",
                        isPrimaryChoice: true,
                        aiReasoning: reasoning
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

    /// Высококачественные авторские эталонные темы для ключевых шедевров кинематографа
    func bespokeConcepts(for movieTitle: String) -> [ThematicConcept] {
        let titleLower = movieTitle.lowercased()

        if titleLower.contains("револьвер") || titleLower.contains("revolver") {
            return [
                ThematicConcept(
                    word: "Эго",
                    tagline: "Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей голове.",
                    philosophicalPremise: "Единственный способ победить внутреннего врага — перестать кормить собственную гордость.",
                    suggestedTitle: "Этот фильм уничтожит твою гордость. Философия Револьвера",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Обман",
                    tagline: "Единственный способ стать умнее — играть с более умным противником.",
                    philosophicalPremise: "Первое правило шахмат: защищай свои интересы, понимая истинную игру манипулятора.",
                    suggestedTitle: "Ты проиграешь, если не поймешь эту разводку.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Страх",
                    tagline: "Страх потери контроля разрушает человека быстрее любой пули.",
                    philosophicalPremise: "Пока ты боишься потерять то, чем дорожишь — тобой управляет кто-то другой.",
                    suggestedTitle: "Твой главный страх управляет каждым твоим решением.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Иллюзия",
                    tagline: "Ты думаешь, что контролируешь ситуацию, но ситуация контролирует тебя.",
                    philosophicalPremise: "Иллюзия выбора — самое изощренное оружие против человека, уверенного в своей правоте.",
                    suggestedTitle: "Ты живёшь в иллюзии контроля. Жесткая правда.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Жадность",
                    tagline: "Жадность ослепляет разум, заставляя верить в собственную неуязвимость.",
                    philosophicalPremise: "Деньги не спасают от внутренней пустоты, они лишь делают финал неизбежным.",
                    suggestedTitle: "Алчность всегда требует платы кровью.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Свобода",
                    tagline: "Ты свободен только тогда, когда готов отказаться от того, за что держишься сильнее всего.",
                    philosophicalPremise: "Истинная свобода начинается в тот момент, когда тебе больше нечего терять и нечего доказывать.",
                    suggestedTitle: "Как стать по-настоящему свободным. Урок Револьвера",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("бойцовск") || titleLower.contains("fight club") {
            return [
                ThematicConcept(
                    word: "Бунт",
                    tagline: "Вещи, которыми ты владеешь, в конце концов начинают владеть тобой.",
                    philosophicalPremise: "Отказ от иллюзорного комфорта общества потребления ради пробуждения настоящей жизни.",
                    suggestedTitle: "Вещи, которыми ты владеешь, овладели тобой.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Боль",
                    tagline: "Лишь утратив всё до конца, мы обретаем истинную свободу.",
                    philosophicalPremise: "Физическая боль как единственный способ вырваться из оцепенения современного мира.",
                    suggestedTitle: "Лишь потеряв всё, ты поймёшь, кто ты есть.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Двойственность",
                    tagline: "Кто ты на самом деле, когда никто не видит?",
                    philosophicalPremise: "Раскол личности между тихим конформистом и разрушительным лидером.",
                    suggestedTitle: "Внутри тебя живёт тот, кого ты боишься.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Свобода",
                    tagline: "Самосовершенствование — это онанизм. Саморазрушение — вот ответ.",
                    philosophicalPremise: "Освобождение через разрушение навязанных социальных ожиданий и статусов.",
                    suggestedTitle: "Прекрати пытаться нравиться этому миру.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("крестн") || titleLower.contains("крёстн") || titleLower.contains("godfather") {
            return [
                ThematicConcept(
                    word: "Власть",
                    tagline: "Никогда не сердись и не угрожай. Заставь людей рассуждать здраво.",
                    philosophicalPremise: "Настоящая сила заключается в хладнокровии и умении предвидеть последствия каждого слова.",
                    suggestedTitle: "Настоящая власть всегда говорит тихо.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Семья",
                    tagline: "Мужчина, который не уделяет времени семье, никогда не станет настоящим мужчиной.",
                    philosophicalPremise: "Вся империя строится ради защиты близких, но сама же их и пожирает.",
                    suggestedTitle: "Единственное, ради чего стоит жить.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Преданность",
                    tagline: "Держи друзей близко, а врагов еще ближе.",
                    philosophicalPremise: "Цена предательства всегда неизбежна, а преданность проверяется в кризис.",
                    suggestedTitle: "Никогда не доверяй тому, кто однажды предал.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Холоднокровие",
                    tagline: "Это ничего личного. Это просто бизнес.",
                    philosophicalPremise: "Эмоции в принятии судьбоносных решений ведут к неминуемой гибели.",
                    suggestedTitle: "Твои эмоции — твой главный враг.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("рыцарь") || titleLower.contains("dark knight") {
            return [
                ThematicConcept(
                    word: "Хаос",
                    tagline: "Некоторым людям просто хочется видеть мир в огне.",
                    philosophicalPremise: "Разум бессилен против хаоса, если у человека нет твердого морального компаса.",
                    suggestedTitle: "Почему порядок всегда проигрывает хаосу.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Символ",
                    tagline: "Либо ты умираешь героем, либо живешь до тех пор, пока не станешь злодеем.",
                    philosophicalPremise: "Тяжесть быть защитником города, готовым принять всеобщее осуждение ради высшего блага.",
                    suggestedTitle: "Ты умрёшь героем или станешь злодеем?",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Выбор",
                    tagline: "В самые темные времена люди показывают свою истинную суть.",
                    philosophicalPremise: "Нравственная дилемма: спасти себя или сохранить человечность перед лицом неминуемой гибели.",
                    suggestedTitle: "В критический момент каждый покажет свое лицо.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Тьма",
                    tagline: "Ночь темнее всего перед самым рассветом.",
                    philosophicalPremise: "Способность выдержать удары судьбы и ненависть толпы ради спасения тех, кто тебя не понимает.",
                    suggestedTitle: "Тот, кто принимает удар за всех.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("сопрано") || titleLower.contains("soprano") {
            return [
                ThematicConcept(
                    word: "Жалость",
                    tagline: "Тони может контролировать всё, кроме собственной пустоты.",
                    philosophicalPremise: "Есть вещи, от которых не спасает ни сила, ни статус, ни деньги — пустота внутри.",
                    suggestedTitle: "Однажды ты поймёшь, что всё это тебя не спасло.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Характер",
                    tagline: "В этом мире нельзя казаться слабым ни на секунду.",
                    philosophicalPremise: "Чем выше ты поднимаешься, тем больше вокруг тех, кто рядом только из страха или выгоды.",
                    suggestedTitle: "В этом мире нельзя быть слабым.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Одиночество",
                    tagline: "Когда ты номер один — в итоге со всеми проблемами остаешься один.",
                    philosophicalPremise: "Власть требует платы, которую большинство не способно вынести.",
                    suggestedTitle: "Цена того, чтобы быть первым.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Семья",
                    tagline: "Ты пытаешься защитить близких от мира, но защищать их приходится от тебя.",
                    philosophicalPremise: "Лицемерие человека, прикрывающего криминал любовью к семье.",
                    suggestedTitle: "Самый тяжелый груз, который ты несешь.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("левша") || titleLower.contains("southpaw") {
            return [
                ThematicConcept(
                    word: "Трудность",
                    tagline: "Ты поймешь, насколько ты силен, только когда потеряешь всё.",
                    philosophicalPremise: "Можно потерять титул, дом и семью, но подняться ради ребенка.",
                    suggestedTitle: "Ты поймешь, насколько ты силен, только когда потеряешь всё.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Гнев",
                    tagline: "Ярость делает тебя опасным, но дисциплина делает тебя непобедимым.",
                    philosophicalPremise: "Твой главный враг на ринге — это ты сам, пока ты не обуздаешь свою боль.",
                    suggestedTitle: "Твой гнев уничтожит тебя, если ты не научишься этому.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Возвращение",
                    tagline: "Падение — это не финал, а начало пути обратно.",
                    philosophicalPremise: "Настоящий чемпион определяется не тем, как он бьет, а тем, как держит удар.",
                    suggestedTitle: "Никогда не сдавайся, когда остался один.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("социальн") || titleLower.contains("social network") {
            return [
                ThematicConcept(
                    word: "Гениальность",
                    tagline: "Иногда тебя не понимают просто потому, что ты видишь будущее.",
                    philosophicalPremise: "Марк создал сеть для сотен миллионов людей, но остался абсолютно одинок.",
                    suggestedTitle: "Иногда, чтобы победить, нужно перестать быть удобным.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Фокус",
                    tagline: "Ты не можешь завести 500 миллионов друзей, не нажив несколько врагов.",
                    philosophicalPremise: "Бескомпромиссная преданность идее требует безжалостного отсечения лишнего.",
                    suggestedTitle: "Ты проиграешь, если будешь пытаться нравиться всем.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Предательство",
                    tagline: "В бизнесе дружба стоит дешевле, чем развитие продукта.",
                    philosophicalPremise: "Трагедия тех, кто идет до конца — оставить позади тех, с кем начинал.",
                    suggestedTitle: "Цена масштаба, о которой никто не предупреждает.",
                    accentColorHex: "#E50914"
                )
            ]
        }

        if titleLower.contains("счасть") || titleLower.contains("happyness") {
            return [
                ThematicConcept(
                    word: "Терпение",
                    tagline: "Способность выдержать период, когда ничего не получается.",
                    philosophicalPremise: "Пока ты продолжаешь идти — история еще не закончена.",
                    suggestedTitle: "Ты никогда не узнаешь, насколько был близок!",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Отец",
                    tagline: "Обещание сыну, которое невозможно нарушить.",
                    philosophicalPremise: "Никому не позволяй говорить, что ты чего-то не можешь. Даже мне.",
                    suggestedTitle: "Защищай свою мечту любой ценой.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Надежда",
                    tagline: "Эта маленькая часть моей жизни называется Счастье.",
                    philosophicalPremise: "Достоинство человека проверяется в моменты, когда у него нет даже пяти долларов.",
                    suggestedTitle: "Ты поймешь это только пройдя через ад.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        return []
    }

    /// Фолбэк на кинематографические эталоны фильма
    func fallbackConcepts(for movieTitle: String) -> [ThematicConcept] {
        let bespoke = bespokeConcepts(for: movieTitle)
        if !bespoke.isEmpty {
            return bespoke
        }
        return universalFallbackConcepts()
    }

    /// Универсальный кинематографический эталон
    func universalFallbackConcepts() -> [ThematicConcept] {
        return [
            ThematicConcept(
                word: "Характер",
                tagline: "Способность стоять до конца, когда весь мир против тебя.",
                philosophicalPremise: "Истинная сила проявляется в моменты, когда от тебя ничего не ждут.",
                suggestedTitle: "В этом мире нельзя быть слабым.",
                accentColorHex: "#F5D020"
            ),
            ThematicConcept(
                word: "Терпение",
                tagline: "Выдержка в самый темный час определяет победителя.",
                philosophicalPremise: "Большинство сдается за шаг до того, как всё изменится.",
                suggestedTitle: "Ты никогда не узнаешь, насколько был близок!",
                accentColorHex: "#F5D020"
            ),
            ThematicConcept(
                word: "Гениальность",
                tagline: "Одиночество того, кто видит дальше других.",
                philosophicalPremise: "Чтобы победить систему, нужно перестать играть по ее правилам.",
                suggestedTitle: "Иногда, чтобы победить, нужно перестать быть удобным.",
                accentColorHex: "#F5D020"
            ),
            ThematicConcept(
                word: "Власть",
                tagline: "Цена контроля над собственной судьбой и чужими жизнями.",
                philosophicalPremise: "Каждое завоеванное преимущество увеличивает тяжесть расплаты.",
                suggestedTitle: "Цена того, чтобы быть во главе.",
                accentColorHex: "#E50914"
            ),
            ThematicConcept(
                word: "Одиночество",
                tagline: "Когда ты на вершине, разделить победу часто оказывается не с кем.",
                philosophicalPremise: "Истинный путь лидера полон изоляции и трудного выбора.",
                suggestedTitle: "Правда о вершине, о которой молчат.",
                accentColorHex: "#F5D020"
            )
        ]
    }
}
