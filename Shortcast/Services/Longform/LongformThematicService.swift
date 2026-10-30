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
        4. Найсильніші сцени фільму — саме з них у КРОЦІ 2 складеться пул для монтажу.

        КРОК 2: ВИБІР ТЕМИ ТА МОМЕНТІВ
        1. Вияви ОДНЕ якірне слово теми (word) — слово, яке САМЕ цей фільм робить видимим.
           Формальні вимоги (без них відповідь відхиляється):
           - одне слово з великої літери, називний відмінок;
           - іменник або дієслово в інфінітиві — НЕ займенник, НЕ прийменник, НЕ сполучник,
             НЕ частка і НЕ числівник («він», «його», «що», «в», «і», «не» темою не є);
           - щонайменше 4 літери;
           - сугубо українське літературне слово, без русизмів;
           - слово прямо називає конфлікт фільму; воно не зобов’язане звучати в діалозі.
           Ми НЕ даємо тобі списку тем: перелік прикладів був би підстановкою, а не знахідкою,
           і ти обирав би слово зі словника замість слова з фільму. Теми не буває в ім'ї героя,
           в жанровій бирці й у службових словах — тема є висновок з аналізу КРОКУ 1.
        2. Сформулюй драматургічний розбір (aiReasoning) — не більше 600 символів: чому саме ця тема є прихованим двигуном сюжету.
        3. Запропонуй гострий слоган (tagline), філософський тез (philosophicalPremise) та вірусний YouTube-заголовок (suggestedTitle).
        4. Склади план есе (essayPlan): thesis, один найкращий hook, 2 ctaVariants, actFocus.
        5. ВИЗНАЧ 14-22 КОНКРЕТНИХ МОМЕНТІВ для есе (selectedMoments) з таймкодами та ролями — НЕ БІЛЬШЕ 22.

        СТРУКТУРА ЕСЕ (5 актів, саме в цьому порядку; хук — 0:00–0:40):
        1. hook — перша сцена есе: обіцянка/парадокс, який утримує глядача; 1-2 речення, без переказу фіналу.
           Роль hook отримує РІВНО ОДНА сцена тривалістю 18-40 с — це зачіпка, а не аналіз.
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
        Кожен момент — ЦІЛІСНА СЦЕНА тривалістю 18-40 с, а не окрема репліка: початок і кінець
        мають збігатися з межами думки, щоб глядач почув закінчену розмову.
        Сумарна тривалість усього пулу — 310-590 с. Це РАНЖОВАНИЙ запас матеріалу, а не мета:
        монтаж візьме з нього рівно стільки, скільки вмістить есе на 4-8 хвилин, тому
        порядок сцен у пулі (від найсильнішої до найслабшої) важливіший за їхню кількість.
        Разом 14-22 сцени (прагни 18): одна на hook, решта — на чотири аналітичні акти,
        щонайменше по 3 в кожному; у кожному аналітичному акті — 3-6 сцен.
        НЕ вигадуй конкретних візуальних деталей (кольори, ракурси, реквізит), яких немає в діалогах:
        акт form описуй через структуру, монтаж і ритм, які виводяться з матеріалу.

        СТИСЛІСТЬ (відповідь мусить уміститися в ліміт токенів):
        - Ключі JSON пиши САМЕ в цьому порядку: primaryConcept → essayPlan → selectedMoments → reasoning.
          Тема — найцінніше, тому сцени (найдовша частина) пишуться останніми.
          Альтернативні грані (alternativeConcepts) залиш ПОРОЖНЬОМ масивом: їх знайшов
          попередній етап аналізу, і повторювати їх тут — тільки ризикувати обривом відповіді.
        - tagline, philosophicalPremise, reason і supports — до 20 слів кожен.
        - evidenceQuote — 3–8 слів ДОСЛІВНО з діалогу в межах таймкоду сцени.
          Це доказ місця у фільмі, а supports — пояснення зв'язку з тезою акта.
        - selectedMoments — максимум 22 сцени. Спершу обери по 1-2 найсильніші сцени
          на КОЖЕН акт (hook, form, psychology, philosophy, catharsis) по всьому фільму,
          включно з фіналом, і лише потім додавай решту до 22.
          Не перелічуй сцени підряд за таймкодом і не бери репліки коротші за 18 с.

        ФОРМАТ ВИВОДУ:
        Відповідь СУВОРО валідним JSON-об'єктом без зайвих передмов і коментарів.
        Зразок нижче — приклад ФОРМАТУ, а НЕ змісту: усе в гострих дужках вибираєш ти сам
        з аналізу цього фільму. Копіюй із зразка лише ключі та тип значення, нічого більше.
        {
          "primaryConcept": {
            "word": "<СЛОВО_ТЕМИ>",
            "tagline": "<СЛОГАН ДО 20 СЛІВ>",
            "philosophicalPremise": "<ФІЛОСОФСЬКИЙ ТЕЗ ДО 20 СЛІВ>",
            "suggestedTitle": "<НАЗВА ДЛЯ YouTube>",
            "accentColorHex": "#F5D020"
          },
          "essayPlan": {
            "thesis": "<ТЕЗА ЕСЕ>",
            "hook": "<ОДИН НАЙКРАЩИЙ ХУК>",
            "ctaVariants": ["<ЗАКЛИК У TELEGRAM 1>", "<ЗАКЛИК У TELEGRAM 2>"],
            "actFocus": {
              "form": "<ЩО САМЕ ДОВОДИТЬ ЦЕЙ АКТ>",
              "psychology": "<ЩО САМЕ ДОВОДИТЬ ЦЕЙ АКТ>",
              "philosophy": "<ЩО САМЕ ДОВОДИТЬ ЦЕЙ АКТ>",
              "catharsis": "<ЩО САМЕ ДОВОДИТЬ ЦЕЙ АКТ>"
            }
          },
          "selectedMoments": [
            {
              "startTime": 754.5,
              "endTime": 790.0,
              "reason": "<ЧОМУ ЦЯ СЦЕНА ПОТУЖНА>",
              "dramaticWeight": 0.85,
              "actRole": "hook",
              "supports": "<ТЕЗИС АКТУ, ЯКИЙ ДОВОДИТЬ СЦЕНА>",
              "evidenceQuote": "<ДОСЛІВНА ЦИТАТА З ДІАЛОГУ ЦІЄЇ СЦЕНИ>",
              "featured": true
            }
          ],
          "alternativeConcepts": [
            {
              "word": "<ІНШЕ_СЛОВО_ТЕМИ>",
              "tagline": "<СЛОГАН ДО 20 СЛІВ>",
              "philosophicalPremise": "<ТЕЗ ДО 20 СЛІВ>",
              "suggestedTitle": "<НАЗВА ДЛЯ YouTube>",
              "accentColorHex": "#F5D020"
            }
          ],
          "reasoning": "<ДРАМАТУРГІЧНИЙ РОЗБІР ДО 600 СИМВОЛІВ>"
        }

        ВАЖЛИВО:
        - selectedMoments повинен містити 14-22 сцени з точними таймкодами (startTime, endTime)
        - Кожна сцена триває 18-40 с; сума (endTime - startTime) усіх сцен — 310-590 с
        - Найсильніші сцени — на початку списку: монтаж обрізає пул з кінця, а не з середини
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
            .sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return "" }

        var lines: [String] = []
        var sceneStart = segments[0].start
        var sceneEnd = segments[0].end
        var sceneText = segments[0].text.trimmingCharacters(in: .whitespacesAndNewlines)

        for seg in segments.dropFirst() {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let gap = seg.start - sceneEnd
            // Непрерывная речь может длиться минуты: один таймкод в начале
            // такого монолога не позволяет модели точно выбрать 18–40 секунд.
            if gap < 0.8, seg.end - sceneStart <= 40, sceneText.count + text.count <= 1_200 {
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
            movieOverview: movieOverview,
            transcript: transcript
        )
    }

    func planThematicAnalysis(
        for concept: ThematicConcept,
        candidates: [ThematicConcept],
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        modelManager: ModelManager,
        directorProfile: ChatModelProfile
    ) async throws -> ThematicAnalysisResult {
        try await modelManager.requireDirector(profile: directorProfile)
        return try await modelManager.momentFinder.analyzeSelectedTheme(
            concept, candidates: candidates, transcript: transcript,
            movieTitle: movieTitle, movieOverview: movieOverview)
    }

    /// Парсит ответ модели в структурированный результат. nil означает
    /// «модель не справилась» — вызывающий обязан показать это, а не
    /// подставлять заготовку. word/tagline/suggestedTitle обязательны: их
    /// должна написать модель, а не код. philosophicalPremise необязателен —
    /// и именно поэтому он не подменяется никаким другим полем.
    static func parseCatalogueAnalysis(
        from raw: String, catalogue: EssaySceneCatalogue
    ) -> ThematicAnalysisResult? {
        try? decodeCatalogueAnalysis(from: raw, catalogue: catalogue)
    }

    static func decodeCatalogueAnalysis(
        from raw: String, catalogue: EssaySceneCatalogue
    ) throws -> ThematicAnalysisResult {
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              var root = JSONVariantParser.deserializeTolerant(json) as? [String: Any] else {
            throw EssaySceneCatalogue.SelectionError(detail: "Ответ с планом эссе содержит повреждённый JSON.")
        }
        let moments = try catalogue.decodeMoments(from: root["selection"])
        root["selectedMoments"] = moments.map { moment -> [String: Any] in
            ["startTime": moment.startTime, "endTime": moment.endTime,
             "reason": moment.reason, "dramaticWeight": moment.dramaticWeight,
             "actRole": moment.actRole?.promptKey ?? "", "supports": moment.supports ?? "",
             "featured": moment.featured ?? false, "evidenceQuote": moment.evidenceQuote ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let text = String(data: data, encoding: .utf8),
              let analysis = parseAnalysisObject(text) else {
            throw EssaySceneCatalogue.SelectionError(detail: "В плане отсутствуют тема, название или обоснование эссе.")
        }
        return analysis
    }

    static func parseThematicAnalysis(from jsonText: String) -> ThematicAnalysisResult? {
        if let jsonString = JSONVariantParser.extractJSONObject(from: jsonText),
           let strict = parseAnalysisObject(jsonString) {
            return strict
        }

        // Модель иногда возвращает массив вместо объекта: первая грань и есть главная тема.
        if let array = tolerantArray(from: jsonText), let head = array.first,
           let primary = parseConcept(head) {
            let filteredPrimary = filterConcept(primary)
            guard isValidConcept(filteredPrimary) else { return nil }
            // Обоснование эссе обязан написать модель: ни слоган, ни название его
            // не заменяют (клон слогана = та же строка дважды на экране и в озвучке).
            // В legacy-массиве грань несёт reasoning при себе; её тезис — последний
            // честный источник, а когда нет ни того, ни другого — честный nil.
            let ownReasoning = [head["aiReasoning"], head["reasoning"]]
                .compactMap { value -> String? in
                    guard let raw = nonEmptyString(value) else { return nil }
                    let filtered = filterNonCyrillic(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    return filtered.isEmpty ? nil : filtered
                }
                .first
            guard let reasoning = ownReasoning ?? nonEmptyString(filteredPrimary.philosophicalPremise)
            else { return nil }
            return makeResult(primary: filteredPrimary, reasoning: reasoning, moments: [], alternatives: conceptArray(Array(array.dropFirst())).map { filterConcept($0) }.filter { isValidConcept($0) })
        }

        return nil
    }

    /// Разбирает этап 1: темы-кандидаты. Провенанс `.llm` здесь честен ровно
    /// потому, что сырой ответ этого прохода уже лежит в director-raw-дампе.
    static func parseThemeCandidates(from raw: String) -> [ThematicConcept] {
        guard let jsonString = JSONVariantParser.extractJSONObject(from: raw),
              let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any],
              let entries = root["candidates"] as? [Any] else { return [] }
        return entries.compactMap { entry -> ThematicConcept? in
            guard let dict = entry as? [String: Any],
                  let word = nonEmptyString(dict["word"]),
                  let tagline = nonEmptyString(dict["tagline"]),
                  let why = nonEmptyString(dict["why"]),
                  let title = nonEmptyString(dict["title"]) else { return nil }
            let concept = ThematicConcept(
                word: filterNonCyrillic(word).trimmingCharacters(in: .whitespacesAndNewlines),
                tagline: filterNonCyrillic(tagline),
                philosophicalPremise: filterNonCyrillic(why),
                suggestedTitle: filterNonCyrillic(title),
                source: .llm)
            return isValidConcept(concept) ? concept : nil
        }
    }

    /// Разбирает объект анализа. nil — если нет темы или обоснования: без них
    /// результат бесполезен, а «долечить» его нечем: reasoning пишет модель, и
    /// если она его не дописала, ответ был обрезан, а не сформулирован короче.
    private static func parseAnalysisObject(
        _ jsonString: String
    ) -> ThematicAnalysisResult? {
        guard let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any],
              let primary = parseConcept(root["primaryConcept"])
        else { return nil }

        // После фильтрации некириллицы обязательные поля могут опустеть.
        let filteredPrimary = filterConcept(primary)
        guard isValidConcept(filteredPrimary) else { return nil }

        // Необязательный слот: молча подставлять в него чужую строку нельзя
        // (клон слогана = та же фраза дважды на экране под видом тезиса), поэтому
        // пустота остаётся пустотой и фиксируется в логе. Гейт её не отбивает.
        if filteredPrimary.philosophicalPremise.isEmpty {
            Self.logger.notice(
                "тема «\(filteredPrimary.word, privacy: .public)» без philosophicalPremise: слот остаётся пустым, эссе собирается только из того, что модель написала сама"
            )
        }

        guard let reasoning = nonEmptyString(root["aiReasoning"]) ?? nonEmptyString(root["reasoning"])
        else { return nil }

        let filteredMoments = parseSelectedMoments(root["selectedMoments"]).map { moment in
            SelectedMoment(
                startTime: moment.startTime,
                endTime: moment.endTime,
                reason: filterNonCyrillic(moment.reason),
                dramaticWeight: moment.dramaticWeight,
                actRole: moment.actRole,
                supports: moment.supports.map(filterNonCyrillic),
                featured: moment.featured,
                evidenceQuote: moment.evidenceQuote
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

    /// Удаляет некириллические символы (арабские, латинские и др.), сохраняя
    /// кириллицу, цифры, пробелы и знаки препинания.
    ///
    /// Whitelist совпадает целым словом: подстрокой «Performance» contain-ил бы
    /// «form» и превратился в него — то есть фильтр дописал бы в текст модели то,
    /// чего она не писала.
    static func filterNonCyrillic(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let runIsLetter = text[index].isLetter
            var end = index
            while end < text.endIndex, text[end].isLetter == runIsLetter {
                end = text.index(after: end)
            }
            let run = String(text[index..<end])
            if runIsLetter {
                if allowedNonCyrillicTerms.contains(where: { $0.caseInsensitiveCompare(run) == .orderedSame }) {
                    result += run
                } else {
                    result += String(run.unicodeScalars.filter { TextUtilities.isCyrillic($0) })
                }
            } else {
                result += String(run.unicodeScalars.filter { scalar in
                    CharacterSet.decimalDigits.contains(scalar)
                        || scalar.properties.isWhitespace
                        || CharacterSet.punctuationCharacters.contains(scalar)
                }.map(Character.init))
            }
            index = end
        }
        return result
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
                featured: dict["featured"] as? Bool,
                evidenceQuote: nonEmptyString(dict["evidenceQuote"]) ?? nonEmptyString(dict["quote"])
            )
        }
    }

    /// Разбирает необязательный план эссе. Модель может ответить без него или
    /// с частичными полями — тогда работаем с тем, что есть, и не выдумываем остальное.
    static func parseEssayPlan(_ value: Any?) -> EssayPlan? {
        guard let dict = value as? [String: Any] else { return nil }
        let hooks = parseTextVariants(dict["hookVariants"])
        let modelHook = nonEmptyString(dict["hook"]).map {
            EssayPlan.TextVariant(text: filterNonCyrillic($0), source: .llm)
        }
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
        guard thesis != nil || modelHook != nil || !hooks.isEmpty || !ctas.isEmpty || !focus.isEmpty else { return nil }
        return EssayPlan(
            thesis: thesis,
            hookVariants: modelHook.map { [$0] } ?? Array(hooks.prefix(3)),
            // Новый контракт содержит один явный hook. Старый список вариантов
            // читается для совместимости, но сам по себе выбором не считается.
            selectedHook: modelHook,
            ctaVariants: Array(ctas.prefix(2)),
            selectedCTA: nil,
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

        // Слот тезиса остаётся пустым, когда модель его не дописала. Переливка
        // слогана в этот слот означала бы, что в эссе звучит строка, написанная
        // для другого слота, а зритель видел бы её дважды: авторство подделал бы
        // код. Пустая строка — это «текста нет», и фиксирует это гейт
        // (`DirectorArtifactGate.concept` → `.missingProse`), а не мы.
        return ThematicConcept(
            word: word,
            tagline: tagline,
            philosophicalPremise: nonEmptyString(dict["philosophicalPremise"]) ?? "",
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
