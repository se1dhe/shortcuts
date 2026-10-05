import Foundation

/// Генератор авторской вирусной упаковки для YouTube в стиле канала @prrodan и Shortcast Cinema (SOLID)
enum LongformMetadataGenerator {

    /// Формирует полный пакет осмысленных метаданных для ролика
    static func generate(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> LongformYouTubeMetadata {
        let safeMovieTitle = MovieMetadataService.isGarbageTitle(movieTitle) ? "фильма" : "фильма «\(movieTitle)»"
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
            chaptersText: chaptersText
        )

        // 4. Глубокие смысловые теги
        let tags = buildPrrodanTags(movieTitle: movieTitle, concept: concept)

        // 5. Провокационный закрепленный комментарий
        let pinnedComment = buildPrrodanPinnedComment(movieTitle: displayMovieTitle, concept: concept)

        return LongformYouTubeMetadata(
            title: title,
            description: desc,
            tags: tags,
            pinnedComment: pinnedComment
        )
    }

    // MARK: - Вспомогательные генераторы

    private static func buildPrrodanTitle(movieTitle: String, concept: ThematicConcept) -> String {
        let hook = concept.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = concept.word.capitalized

        // Если заголовок концепта уже отточен и содержит сильную мысль
        if hook.lowercased().contains("ты") || hook.lowercased().contains("когда") || hook.lowercased().contains("почему") {
            if hook.contains("|") {
                return hook
            } else {
                return "\(hook) | \(word)"
            }
        }

        // Адаптивные формулы в стиле prrodan
        let templates = [
            "Ты проигрываешь, пока веришь в это | \(word)",
            "Однажды ты поймёшь, почему всё произошло именно так | \(word)",
            "Иногда, чтобы победить, нужно отпустить контроль | \(word)",
            "Ты никогда не будешь свободен, пока не осознаешь это | \(word)",
            "Самая опасная ложь — та, в которую ты веришь сам | \(word)"
        ]

        let selectedTemplate = templates[abs(concept.word.hashValue) % templates.count]
        return selectedTemplate
    }

    private static func buildChapters(acts: [LongformAct], concept: ThematicConcept) -> String {
        var lines: [String] = []
        lines.append("00:00 — Вступление: \(concept.word.capitalized)")

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
        chaptersText: String
    ) -> String {
        let isKnownMovie = !MovieMetadataService.isGarbageTitle(movieTitle)
        let movieRef = isKnownMovie ? "фильма «\(movieTitle)»" : "этой истории"

        return """
        Этот ролик — про другую сторону \(movieRef).

        Не про внешние декорации.
        Не про слова на поверхности.
        А про то, что на самом деле управляет нашими решениями.

        \(concept.philosophicalPremise)

        \(concept.tagline)

        Иногда иллюзия настолько плотно срастается с реальностью, что человек принимает чужие правила за свой собственный выбор. До тех пор, пока цена этого выбора не становится слишком высокой.

        Таймкоды:
        \(chaptersText)

        ───────────────────────────────────────
        Disclaimer: This video is an analytical cinema essay intended for commentary, educational, and transformative artistic reflection. All footage used belongs to its respective copyright owners and is used under Fair Use principles (Section 107 of the Copyright Act).

        #киноэссе #смыслфильма #психология #\(concept.word.lowercased()) #осознанность #саморазвитие #разборкино
        """
    }

    private static func buildPrrodanTags(movieTitle: String, concept: ThematicConcept) -> [String] {
        var tags: [String] = [
            concept.word.lowercased(),
            "киноэссе",
            "смысл фильма",
            "разбор фильма",
            "психология кино",
            "самообман",
            "иллюзия контроля",
            "осознанность",
            "характер",
            "мышление",
            "философия кино",
            "мотивация",
            "prrodan стиль",
            "shortcast cinema",
            "кинематограф"
        ]

        if !MovieMetadataService.isGarbageTitle(movieTitle) {
            let lower = movieTitle.lowercased()
            tags.insert("\(lower) смысл", at: 0)
            tags.insert("\(lower) разбор", at: 0)
            tags.insert(lower, at: 0)
        }

        return tags
    }

    private static func buildPrrodanPinnedComment(movieTitle: String, concept: ThematicConcept) -> String {
        let movieStr = movieTitle.isEmpty ? "этого фильма" : movieTitle
        return """
        Самый опасный враг — тот, кто прячется там, где ты меньше всего будешь его искать: внутри твоей собственной головы.

        Какой момент из \(movieStr) заставил тебя по-настоящему усомниться в том, кто на самом деле делает выбор в твоей жизни? Напиши свои мысли в комментариях 👇
        """
    }
}
