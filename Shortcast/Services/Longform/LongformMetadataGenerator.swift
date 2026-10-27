import Foundation

/// Генератор авторской вирусной упаковки для YouTube в стиле канала @prrodan и Shortcast Cinema (SOLID)
enum LongformMetadataGenerator {

    /// Формирует полный пакет осмысленных метаданных для ролика
    static func generate(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> LongformYouTubeMetadata {
        let safeMovieTitle = MovieMetadataService.isGarbageTitle(movieTitle) ? "фільму" : "фільму «\(movieTitle)»"
        let displayMovieTitle = MovieMetadataService.isGarbageTitle(movieTitle) ? "" : "«\(movieTitle)»"

        // 1. Адаптивный кинематографический заголовок в стиле @prrodan (ударная фраза от 2-го лица)
        let title = buildPrrodanTitle(movieTitle: movieTitle, concept: concept)

        // 2. Таймкоды YouTube по адаптивным актам
        let chaptersText = buildChapters(acts: arc.acts, concept: concept)

        // 3. Строфическое описание-манифест в стиле @prrodan
        let desc = buildPrrodanDescription(
            movieTitle: movieTitle,
            safeMovieTitle: safeMovieTitle,
            concept: concept,
            chaptersText: chaptersText,
            hook: arc.hookText,
            thesis: arc.thesis
        )

        // 4. Глубокие смысловые теги
        let tags = buildPrrodanTags(movieTitle: movieTitle, concept: concept)

        // 5. Провокационный закрепленный комментарий
        let pinnedComment = buildPrrodanPinnedComment(
            movieTitle: displayMovieTitle, concept: concept, cta: arc.ctaText)

        return LongformYouTubeMetadata(
            title: title,
            description: desc,
            tags: tags,
            pinnedComment: pinnedComment
        )
    }

    // MARK: - Вспомогательные генераторы

    /// Устойчивый хеш слова (djb2 по UTF-16). `String.hashValue` пересевается на каждый
    /// запуск процесса, поэтому выбор шаблона заголовка молча менялся между рендерами
    /// одного и того же ролика — YouTube-тайтл переименовывал сам себя.
    static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 5381
        for unit in text.utf16 {
            hash = (hash &* 33) &+ UInt64(unit)
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    private static func buildPrrodanTitle(movieTitle: String, concept: ThematicConcept) -> String {
        let hook = concept.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = concept.word.capitalized

        // Если заголовок концепта уже отточен и содержит сильную мысль
        if hook.lowercased().contains("ти") || hook.lowercased().contains("коли") || hook.lowercased().contains("чому") {
            if hook.contains("|") {
                return hook
            } else {
                return "\(hook) | \(word)"
            }
        }

        // Адаптивные формулы в стиле prrodan
        let templates = [
            "Ти програєш, поки віриш у це | \(word)",
            "Одного разу ти зрозумієш, чому все сталося саме так | \(word)",
            "Іноді, щоб перемогти, потрібно відпустити контроль | \(word)",
            "Ти ніколи не будеш вільним, поки не усвідоміш це | \(word)",
            "Найнебезпечніша брехня — та, в яку ти віриш сам | \(word)"
        ]

        let selectedTemplate = templates[stableHash(concept.word) % templates.count]
        return selectedTemplate
    }

    private static func buildChapters(acts: [LongformAct], concept: ThematicConcept) -> String {
        var lines: [String] = []
        lines.append("00:00 — Вступ: \(concept.word.capitalized)")

        var currentOffset: Double = 2.5
        let romanNumerals = ["I", "II", "III", "IV", "V", "VI"]

        for (index, act) in acts.enumerated() {
            let mins = Int(currentOffset) / 60
            let secs = Int(currentOffset) % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            let roman = index < romanNumerals.count ? romanNumerals[index] : "\(index + 1)"
            lines.append("\(timeStr) — Акт \(roman): \(act.title)")

            currentOffset += act.duration
        }

        return lines.joined(separator: "\n")
    }

    private static func buildPrrodanDescription(
        movieTitle: String,
        safeMovieTitle: String,
        concept: ThematicConcept,
        chaptersText: String,
        hook: String?,
        thesis: String?
    ) -> String {
        let isKnownMovie = !MovieMetadataService.isGarbageTitle(movieTitle)
        let movieRef = isKnownMovie ? "фільму «\(movieTitle)»" : "цієї історії"
        let cleanHook = hook?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanThesis = thesis?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let opening: String
        if !cleanHook.isEmpty {
            opening = cleanHook
        } else {
            opening = "Це відео — про інший бік \(movieRef)."
        }
        let thesisBlock = (!cleanThesis.isEmpty && cleanThesis != cleanHook)
            ? "\n\n\(cleanThesis)"
            : ""

        return """
        \(opening)\(thesisBlock)

        Не про зовнішні декорації.
        Не про слова на поверхні.
        А про те, що насправді керує нашими рішеннями.

        \(concept.philosophicalPremise)

        \(concept.tagline)

        Іноді ілюзія настільки щільно зростається з реальністю, що людина приймає чужі правила за свій власний вибір. До тих пір, поки ціна цього вибору не стає надто високою.

        Таймкоди:
        \(chaptersText)

        ───────────────────────────────────────
        Disclaimer: This video is an analytical cinema essay intended for commentary, educational, and transformative artistic reflection. All footage used belongs to its respective copyright owners and is used under Fair Use principles (Section 107 of the Copyright Act).

        #кіноеесе #сенсфільму #психологія #\(concept.word.lowercased()) #усвідомленість #саморозвиток #розбіркіно
        """
    }

    private static func buildPrrodanTags(movieTitle: String, concept: ThematicConcept) -> [String] {
        var tags: [String] = [
            concept.word.lowercased(),
            "кіноеесе",
            "сенс фільму",
            "розбір фільму",
            "психологія кіно",
            "самообман",
            "ілюзія контролю",
            "усвідомленість",
            "характер",
            "мислення",
            "філософія кіно",
            "мотивація",
            "prrodan стиль",
            "shortcast cinema",
            "кінематограф"
        ]

        if !MovieMetadataService.isGarbageTitle(movieTitle) {
            let lower = movieTitle.lowercased()
            tags.insert("\(lower) сенс", at: 0)
            tags.insert("\(lower) розбір", at: 0)
            tags.insert(lower, at: 0)
        }

        return tags
    }

    private static func buildPrrodanPinnedComment(
        movieTitle: String,
        concept: ThematicConcept,
        cta: String?
    ) -> String {
        let movieStr = movieTitle.isEmpty ? "цього фільму" : movieTitle
        let cleanCTA = cta?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanCTA.isEmpty {
            return """
            \(cleanCTA)

            Який момент з \(movieStr) змусив тебе по-справжньому засумніватися в тому, хто насправді робить вибір у твоєму житті? Напиши свої думки в коментарях 👇
            """
        }
        return """
        Найнебезпечніший ворог — той, хто ховається там, де ти найменше будеш його шукати: всередині твоєї власної голови.

        Який момент з \(movieStr) змусив тебе по-справжньому засумніватися в тому, хто насправді робить вибір у твоєму житті? Напиши свої думки в коментарях 👇
        """
    }
}
