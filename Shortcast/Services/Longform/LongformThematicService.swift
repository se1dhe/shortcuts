import Foundation
import os

/// Реализация ThematicConceptDiscovering для выявления тем Shortcast Cinema (SOLID)
final class LongformThematicService: ThematicConceptDiscovering, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "LongformThematicService")

    /// Подсказка для LLM в роли сценариста-философа и вирусного YouTube-режиссера
    static func thematicSystemPrompt(movieTitle: String) -> String {
        """
        Ти — елітний кінорежисер, драматург і автор глибоких філософських відео-есів на YouTube для Shortcast Cinema.
        Твоє завдання — проаналізувати повний хронологічний зріз сценарію фільму «\(movieTitle)», глибо зрозуміти прихований психологічний та екзистенційний конфлікт героїв і САМОСТІЙНО ОБРАТИ І ЗАПРОПОНУВАТИ ОДНУ ГОЛОВНУ ТЕМУ ЕСЕ та КОНКРЕТНІ МОМЕНТИ для монтажу.

        КРОК 1: ГЛИБОКИЙ АНАЛІЗ СТРУКТУРИ ФІЛЬМУ (chain-of-thought)
        Перед вибором теми ти повинен спочатку проаналізувати:
        1. Драматургічну арку фільму (зав'язка, кульмінація, розв'язка)
        2. Ключові конфлікти та екзистенційні питання, які піднімає фільм
        3. Психологічну еволюцію головного героя
        4. 3-5 найсильніших сцен, які найкраще розкривають головну тему

        КРОК 2: ВИБІР ТЕМИ ТА МОМЕНТІВ
        1. Вияви ОДНЕ потужне якірне слово теми (word) з великої літери (наприклад: «ЕГО», «ОБМАН», «СТРАХ», «ТЕРПІННЯ», «ГЕНІАЛЬНІСТЬ», «ВЛАДА»).
        2. Сформулюй драматургічний розбір (aiReasoning) — не більше 600 символів: чому саме ця тема є прихованим двигуном сюжету.
        3. Запропонуй гострий слоган (tagline), філософський тез (philosophicalPremise) та вірусний YouTube-заголовок (suggestedTitle).
        4. Склади план есе (essayPlan): thesis, 3 hookVariants, 2 ctaVariants, actFocus.
        5. ВИЗНАЧ 16-24 КОНКРЕТНИХ МОМЕНТІВ для есе (selectedMoments) з таймкодами та ролями — НЕ БІЛЬШЕ 24.
        6. Запропонуй РІВНО 3 альтернативні грані фільму (alternativeConcepts).

        СТРУКТУРА ЕСЕ (5 актів, саме в цьому порядку; хук — 0:00–0:40):
        1. hook — перша сцена есе: обіцянка/парадокс, який утримує глядача; 1-2 речення, без переказу фіналу.
           Роль hook отримує РІВНО ОДНА сцена тривалістю 20-40 с — це зачіпка, а не аналіз.
        2. form — як фільм зроблений: монтаж, ритм, повторювані прийоми, структура сцен.
        3. psychology — що насправді рухає героєм: страх, бажання, захист, самообман.
        4. philosophy — прихований підтекст: що фільм каже про людину, свободу, владу, вибір.
        5. catharsis — розв'язка думки: що змінюється в глядачеві після цього аналізу.
           Остання сцена акту — розв'язка фільму і найсильніша сцена всього есе.
        CTA — заклик перейти в Telegram (опитування, лонгрід або добірка), а не коментарі;
        без хендлів, посилань і назв каналів.
        Для кожного акта сформулюй у actFocus, ЩО САМЕ цей акт доводить у цьому фільмі.
        Кожній сцені признач actRole зі списку: hook|form|psychology|philosophy|catharsis.
        supports — одним реченням, який тезис акта доводить сцена; featured=true лише для найсильніших 1-2 сцен акта.
        Розподіляй сцени за РОЛЛЮ В АРЦІ ЕСЕ, а не за місцем у фільмі: хук може бути з середини,
        а наступний акт — з початку. Есе не зобов'язане йти хронологією фільму.
        Кожен момент — ЦІЛІСНА СЦЕНА тривалістю 20-60 с, а не окрема репліка: початок і кінець
        мають збігатися з межами думки, щоб глядач почув закінчену розмову.
        Сумарна тривалість усіх сцен — 720-900 с (12-15 хвилин). Це запас матеріалу:
        монтаж потім візьме з нього обраний хронометраж 8-15 хвилин.
        У кожному з чотирьох аналітичних актів — 3-6 сцен; у hook — рівно одна сцена 20-40 с.
        НЕ вигадуй конкретних візуальних деталей (кольори, ракурси, реквізит), яких немає в діалогах:
        акт form описуй через структуру, монтаж і ритм, які виводяться з матеріалу.

        СТИСЛІСТЬ (відповідь мусить уміститися в ліміт токенів):
        - Ключі JSON пиши САМЕ в цьому порядку: primaryConcept → essayPlan → selectedMoments → alternativeConcepts → reasoning.
          Головне — тема й сцени: навіть обірвана відповідь має лишити монтаж придатним.
        - tagline, philosophicalPremise, reason і supports — до 20 слів кожен.
        - alternativeConcepts — рівно 3, стисло: word, tagline, suggestedTitle.
        - selectedMoments — максимум 24 сцени. Спершу обери по 1-2 найсильніші сцени
          на КОЖЕН акт (hook, form, psychology, philosophy, catharsis) по всьому фільму,
          включно з фіналом, і лише потім додавай решту до 24.
          Не перелічуй сцени підряд за таймкодом і не бери репліки коротші за 20 с.

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
          "essayPlan": {
            "thesis": "Контроль — це не сила, а страх, який ти називаєш порядком.",
            "hookVariants": [
              "Ти контролюєш усе, крім того, що насправді вирішує твоє життя.",
              "Герой цього фільму переміг усіх. Крім одного — себе.",
              "Що, як твоя найбільша сила — це й твоя найбільша пастка?"
            ],
            "ctaVariants": [
              "Повний розбір і опитування — у Telegram-каналі.",
              "Продовження розбору та добірка матеріалів — у Telegram."
            ],
            "actFocus": {
              "form": "Ритм і повторювані прийоми видають внутрішній конфлікт героя.",
              "psychology": "Страх втратити контроль керує кожним його рішенням.",
              "philosophy": "Свобода починається там, де закінчується потреба все тримати.",
              "catharsis": "Глядач бачить ціну контролю і власний вибір."
            }
          },
          "selectedMoments": [
            {
              "startTime": 754.5,
              "endTime": 810.3,
              "reason": "Ця сцена показує перший конфлікт героя з власним его, коли він усвідомлює...",
              "dramaticWeight": 0.85,
              "actRole": "hook",
              "supports": "Герой ще вірить, що контролює ситуацію.",
              "featured": true
            },
            {
              "startTime": 4500.0,
              "endTime": 4558.0,
              "reason": "Кульмінація внутрішнього конфлікту: герой стикається з наслідками своєї гордині...",
              "dramaticWeight": 0.95,
              "actRole": "catharsis",
              "supports": "Ціна контролю стає очевидною.",
              "featured": true
            }
          ],
          "alternativeConcepts": [
            {
              "word": "Обман",
              "tagline": "Єдиний спосіб стати розумнішим — грати з розумнішим суперником.",
              "philosophicalPremise": "Перше правило шахів: захищай свої інтереси, розуміючи справжню гру маніпулятора.",
              "suggestedTitle": "Ти програєш, якщо не зрозумієш цю розводку.",
              "accentColorHex": "#F5D020"
            }
          ],
          "reasoning": "Головний конфлікт фільму і чому ця тема центральна — 2-3 речення."
        }

        ВАЖЛИВО:
        - selectedMoments повинен містити 16-24 сцени з точними таймкодами (startTime, endTime)
        - Кожна сцена триває 20-60 с; сума (endTime - startTime) усіх сцен — 720-900 с
        - Кожен момент повинен мати reason, dramaticWeight (0.0-1.0), actRole, supports і featured
        - НЕ включай титри в кінці фільму — фокусуйся на сюжетних сценах
        - Таймкоди повинні відповідати реальним сценам з транскрипту
        - Таймкоди в транскрипті — це СЕКУНДИ ВІД ПОЧАТКУ ФІЛЬМУ (наприклад, [754.5] = 12 хвилин 34.5 секунди)
        - startTime та endTime у відповіді — теж у секундах від початку фільму (числа, не MM:SS)
        - Кожен з п'яти актів має отримати хоча б одну сцену
        - catharsis — це розв'язка: включи сцену розв'язки фільму, а featured=true постав найсильнішій сцені есе — монтаж завершить ним

        МОВА (КРИТИЧНО ВАЖЛИВО):
        - Використовуй ВИКЛЮЧНО ПРАВИЛЬНУ УКРАЇНСЬКУ ЛІТЕРАТУРНУ МОВУ
        - ЗАБОРОНЕНО використовувати русизми та суржик
        - Використовуй ВИКЛЮЧНО правильні українські літературні слова: ВРЯТУВАТИ, ЗБАВИТИ, НИЖНІЙ, ЕПОХА, ДОБА
        - Приклади правильних тем: "ВРЯТУВАТИ", "ЗБАВИТИ", "ЕГО", "ОБМАН", "СТРАХ", "ТЕРПІННЯ", "ГЕНІАЛЬНІСТЬ", "ВЛАДА", "СВОБОДА", "ІСТИНА"
        - Кожен теглайн, філософський тез та назва мають бути граматично правильними українською
        - Якщо сумніваєшся у слові — використовуй простіше, але правильне українське слово
        """
    }

    /// Сжимает ВЕСЬ транскрипт в хронологический срез для LLM: соседние реплики
    /// одной сцены (пауза < 0.8с) сливаются в одну строку с таймкодом начала.
    /// Формат `[MM:SS] текст` без дробных секунд и пустых строк — максимум
    /// покрытия сюжета при минимуме символов. `targetSegmentsCount` больше не
    /// используется как квота (оставлен для совместимости сигнатуры).
    static func stratifiedThematicSample(from transcript: Transcript, targetSegmentsCount: Int = 0) -> String {
        // Director не должен видеть субтитровые подписи, звуковые описания и
        // чужие языки: иначе он честно выбирает их как «сцены фильма».
        let segments = TranscriptQualityGate(segments: transcript.segments)
            .filtered(transcript.segments)
            .filter { seg in
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

    // Формат `[секунды.десятые]` вместо `[MM:SS]`: модель не должна mentally
    // конвертировать минуты в секунды — это приводило к тому, что LLM выдавала
    // таймкоды кластерами в первых ~130 секундах вместо распределения по всему
    // фильму. Абсолютные секунды устраняют неоднозначность.
    private static func formatCompressedLine(start: Double, text: String) -> String {
        return String(format: "[%.1f] %@", start, text)
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
           let strict = parseAnalysisObject(jsonString) {
            return strict
        }

        // Генерация упирается в maxTokens и обрывает JSON: закрываем хвост и
        // берём всё, что модель успела выдать целиком. Без хотя бы одной
        // завершённой сцены монтаж собрать не из чего — тогда честный nil.
        if let repairedJSON = JSONVariantParser.extractTruncatedJSONObject(from: jsonText),
           let repaired = parseAnalysisObject(repairedJSON, allowDerivedReasoning: true),
           !repaired.selectedMoments.isEmpty {
            Self.logger.info(
                "salvaged truncated thematic JSON: \(repaired.selectedMoments.count) moment(s), theme '\(repaired.primaryConcept.word, privacy: .public)'"
            )
            return repaired
        }

        // Модель иногда возвращает массив вместо объекта: первая грань и есть главная тема.
        if let array = tolerantArray(from: jsonText), let head = array.first,
           let primary = parseConcept(head) {
            let filteredPrimary = filterConcept(primary)
            guard isValidConcept(filteredPrimary) else { return nil }
            let reasoning = nonEmptyString(filteredPrimary.philosophicalPremise) ?? filteredPrimary.tagline
            return makeResult(primary: filteredPrimary, reasoning: filterNonCyrillic(reasoning ?? ""), moments: [], alternatives: conceptArray(Array(array.dropFirst())).map { filterConcept($0) }.filter { isValidConcept($0) })
        }

        return nil
    }

    /// Разбирает объект анализа (полный или восстановленный из обрезанного ответа).
    /// nil — если нет темы или обоснования: без них результат бесполезен.
    ///
    /// `allowDerivedReasoning` — только для восстановленного хвоста: reasoning
    /// пишется последним и обрезается первым, поэтому его отсутствие там означает
    /// обрыв, а не небрежность модели. Тогда обоснованием служит philosophicalPremise
    /// самой модели — текста мы не придумываем.
    private static func parseAnalysisObject(
        _ jsonString: String,
        allowDerivedReasoning: Bool = false
    ) -> ThematicAnalysisResult? {
        guard let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any],
              let primary = parseConcept(root["primaryConcept"])
        else { return nil }

        // После фильтрации некириллицы обязательные поля могут опустеть.
        let filteredPrimary = filterConcept(primary)
        guard isValidConcept(filteredPrimary) else { return nil }

        let modelReasoning = nonEmptyString(root["aiReasoning"]) ?? nonEmptyString(root["reasoning"])
        guard let reasoning = modelReasoning ?? (allowDerivedReasoning ? filteredPrimary.philosophicalPremise : nil)
        else { return nil }

        let filteredMoments = parseSelectedMoments(root["selectedMoments"]).map { moment in
            SelectedMoment(
                startTime: moment.startTime,
                endTime: moment.endTime,
                reason: filterNonCyrillic(moment.reason),
                dramaticWeight: moment.dramaticWeight,
                actRole: moment.actRole,
                supports: moment.supports.map(filterNonCyrillic),
                featured: moment.featured
            )
        }
        let filteredAlts = conceptArray(root["alternativeConcepts"])
            .map { filterConcept($0) }
            .filter { isValidConcept($0) }
        return makeResult(
            primary: filteredPrimary,
            reasoning: filterNonCyrillic(reasoning),
            moments: filteredMoments,
            alternatives: filteredAlts,
            plan: parseEssayPlan(root["essayPlan"])
        )
    }

    /// Проверяет, что обязательные поля концепта (word, tagline, suggestedTitle) не пусты
    /// после фильтрации некириллических символов.
    private static func isValidConcept(_ concept: ThematicConcept) -> Bool {
        !concept.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !concept.tagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !concept.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Фильтрация некириллических символов (Задача 2)

    /// Whitelist кино-терминов и имён собственных, которые разрешены в не-кириллических фильмах
    private static let allowedNonCyrillicTerms = [
        // Кино-термины
        "hook", "catharsis", "form", "psychology", "philosophy", "CTA",
        // Платформы
        "Telegram", "YouTube", "Shorts", "TikTok", "Instagram", "Facebook", "Twitter", "Netflix", "HBO", "Disney", "Pixar", "Marvel", "DC",
        // Режиссёры (латиница)
        "Nolan", "Fincher", "Scorsese", "Coen", "Villeneuve", "Besson", "Darabont", "Chazelle", "Refn", "Tarantino",
        // Актёры (латиница)
        "DiCaprio", "Pitt", "Jolie", "Clooney", "Gosling", "Bale", "Ledger",
        // Кино-термины (кириллица)
        "хук", "катарсис", "форма", "психологія", "філософія",
        // Платформы (кириллица)
        "Телеграм", "Ютуб", "ТікТок", "Інстаграм", "Фейсбук", "Твіттер", "Нетфлікс", "Дісней", "Піксар", "Марвел"
    ]

    /// Удаляет некириллические символы (арабские, латинские и др.), сохраняя кириллицу,
    /// цифры, пробелы, знаки препинания и whitelist термины.
    static func filterNonCyrillic(_ text: String) -> String {
        var processedText = text
        var placeholders: [String: String] = [:]
        
        // Заменяем whitelist термины на уникальные кириллические плейсхолдеры
        for (index, term) in allowedNonCyrillicTerms.enumerated() {
            let placeholder = "КІНОТЕРМІН\(index)КИНОТЕРМ"
            if processedText.contains(term) {
                processedText = processedText.replacingOccurrences(of: term, with: placeholder)
                placeholders[placeholder] = term
            }
        }
        
        // Применяем фильтр не-кириллицы
        guard let regex = try? NSRegularExpression(
            pattern: "[^\\p{Cyrillic}\\p{Number}\\s\\p{Punctuation}]",
            options: []
        ) else { return text }
        let range = NSRange(processedText.startIndex..., in: processedText)
        processedText = regex.stringByReplacingMatches(in: processedText, range: range, withTemplate: "")
        
        // Восстанавливаем whitelist термины из плейсхолдеров
        for (placeholder, original) in placeholders {
            processedText = processedText.replacingOccurrences(of: placeholder, with: original)
        }
        
        return processedText
    }

    /// Применяет фильтрацию некириллических символов к текстовым полям концепта.
    private static func filterConcept(_ concept: ThematicConcept) -> ThematicConcept {
        var filtered = concept
        filtered.word = filterNonCyrillic(concept.word)
        filtered.tagline = filterNonCyrillic(concept.tagline)
        filtered.philosophicalPremise = filterNonCyrillic(concept.philosophicalPremise)
        filtered.suggestedTitle = filterNonCyrillic(concept.suggestedTitle)
        return filtered
    }

    private static func parseSelectedMoments(_ value: Any?) -> [SelectedMoment] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry -> SelectedMoment? in
            guard let dict = entry as? [String: Any],
                  let startTime = parseDouble(dict["startTime"]),
                  let endTime = parseDouble(dict["endTime"]),
                  let reason = nonEmptyString(dict["reason"])
            else { return nil }
            
            let weight = parseDouble(dict["dramaticWeight"]) ?? 0.5
            let role = (dict["actRole"] as? String).flatMap { LongformActType(promptKey: $0) }
            let supports = nonEmptyString(dict["supports"])
            return SelectedMoment(
                startTime: startTime,
                endTime: endTime,
                reason: reason,
                dramaticWeight: weight,
                actRole: role,
                supports: supports,
                featured: dict["featured"] as? Bool
            )
        }
    }

    /// Разбирает необязательный план эссе. Модель может ответить без него или
    /// с частичными полями — тогда работаем с тем, что есть, и не выдумываем остальное.
    static func parseEssayPlan(_ value: Any?) -> EssayPlan? {
        guard let dict = value as? [String: Any] else { return nil }
        let hooks = parseTextVariants(dict["hookVariants"])
        let ctas = parseTextVariants(dict["ctaVariants"])
        var focus: [String: String] = [:]
        if let rawFocus = dict["actFocus"] as? [String: Any] {
            for (key, raw) in rawFocus {
                guard let type = LongformActType(promptKey: key),
                      let text = nonEmptyString(raw) else { continue }
                let filtered = filterNonCyrillic(text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !filtered.isEmpty {
                    focus[type.promptKey] = filtered
                }
            }
        }
        let thesis = nonEmptyString(dict["thesis"]).map(filterNonCyrillic)
        guard thesis != nil || !hooks.isEmpty || !ctas.isEmpty || !focus.isEmpty else { return nil }
        return EssayPlan(
            thesis: thesis,
            hookVariants: Array(hooks.prefix(3)),
            selectedHook: hooks.first,
            ctaVariants: Array(ctas.prefix(2)),
            selectedCTA: ctas.first,
            actFocus: focus
        )
    }

    private static func parseTextVariants(_ value: Any?) -> [EssayPlan.TextVariant] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry in
            let raw: String?
            if let text = entry as? String {
                raw = text
            } else if let dict = entry as? [String: Any] {
                raw = nonEmptyString(dict["text"])
            } else {
                raw = nil
            }
            guard let raw else { return nil }
            let filtered = filterNonCyrillic(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return filtered.isEmpty ? nil : EssayPlan.TextVariant(text: filtered, source: .llm)
        }
    }

    /// Парсит числовое значение в Double. Поддерживает Double, Int и String (Задача 8).
    private static func parseDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    private static func makeResult(
        primary: ThematicConcept,
        reasoning: String,
        moments: [SelectedMoment],
        alternatives: [ThematicConcept],
        plan: EssayPlan? = nil
    ) -> ThematicAnalysisResult {
        var main = primary
        main.isPrimaryChoice = true
        main.aiReasoning = reasoning
        return ThematicAnalysisResult(
            primaryConcept: main,
            aiReasoning: reasoning,
            selectedMoments: moments,
            alternativeConcepts: alternatives,
            essayPlan: plan,
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
