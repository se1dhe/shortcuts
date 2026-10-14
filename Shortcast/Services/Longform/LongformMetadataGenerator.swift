import Foundation

// MARK: - Protocols (SOLID: ISP & DIP)

/// Протокол генерации кликабельного авторского заголовка для YouTube кино-эссе
protocol LongformTitleGenerating: Sendable {
    func generateTitle(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> String
}

/// Протокол генерации таймкодов YouTube глав по актам эссе
protocol LongformChapterBuilding: Sendable {
    func buildChapters(
        acts: [LongformAct],
        concept: ThematicConcept
    ) -> String
}

/// Протокол генерации глубокого авторского описания-манифеста с драматургическим разбором
protocol LongformDescriptionGenerating: Sendable {
    func generateDescription(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc,
        chaptersText: String,
        tags: [String]
    ) -> String
}

/// Протокол генерации закрепленного комментария с провокационным вопросом к зрителям
protocol LongformPinnedCommentGenerating: Sendable {
    func generatePinnedComment(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> String
}

/// Протокол генерации релевантных семантических тегов
protocol LongformTagGenerating: Sendable {
    func generateTags(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> [String]
}

/// Фасад генерации полного пакета метаданных для длинного видео (SOLID: OCP & DIP)
protocol LongformMetadataGenerating: Sendable {
    func generate(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> LongformYouTubeMetadata
}

// MARK: - Default Title Generator (SOLID: SRP)

/// Генератор авторских вирусных заголовков на основе темы, конфликта и названия фильма
struct DefaultLongformTitleGenerator: LongformTitleGenerating {

    init() {}

    func generateTitle(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> String {
        let isKnownMovie = !MovieMetadataService.isGarbageTitle(movieTitle)
        let word = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized

        // 1. Извлекаем авторский хук из концепта или формулируем из слогана
        var rawHook = concept.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawHook.isEmpty {
            rawHook = concept.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Очищаем от концевых точек, кавычек и лишних пробелов
        let cleanHook = cleanHeadline(rawHook)

        // 2. Если хук уже содержит разделитель packaging (| или —)
        if cleanHook.contains("|") {
            if isKnownMovie && !cleanHook.localizedCaseInsensitiveContains(movieTitle) {
                let candidate = "\(cleanHook) («\(movieTitle)»)"
                if candidate.count <= 95 {
                    return candidate
                }
            }
            return cleanHook
        }

        // 3. Если есть чистый хук от модели или сценария
        if !cleanHook.isEmpty {
            if isKnownMovie {
                if cleanHook.localizedCaseInsensitiveContains(movieTitle) {
                    let withWord = "\(cleanHook) | \(word)"
                    return withWord.count <= 95 ? withWord : cleanHook
                } else {
                    let withBoth = "\(cleanHook) | \(word) («\(movieTitle)»)"
                    if withBoth.count <= 95 {
                        return withBoth
                    }
                    let withMovie = "\(cleanHook) | «\(movieTitle)»"
                    if withMovie.count <= 95 {
                        return withMovie
                    }
                    let withWord = "\(cleanHook) | \(word)"
                    if withWord.count <= 95 {
                        return withWord
                    }
                    return cleanHook
                }
            } else {
                let withWord = "\(cleanHook) | \(word)"
                return withWord.count <= 95 ? withWord : cleanHook
            }
        }

        // 4. Динамический синтез при отсутствии прямого хука (без шаблонных списков!)
        if isKnownMovie {
            return "Скрытый смысл «\(movieTitle)»: почему \(word) меняет всё"
        } else {
            return "Скрытая правда о том, что управляет тобой | \(word)"
        }
    }

    private func cleanHeadline(_ text: String) -> String {
        var str = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while str.hasSuffix(".") || str.hasSuffix(";") || str.hasSuffix(",") || str.hasSuffix("!") {
            str.removeLast()
            str = str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return str
    }
}

// MARK: - Default Chapter Builder (SOLID: SRP)

/// Формирует YouTube-таймкоды глав с адаптивной разбивкой по актам
struct DefaultLongformChapterBuilder: LongformChapterBuilding {

    init() {}

    func buildChapters(acts: [LongformAct], concept: ThematicConcept) -> String {
        var lines: [String] = []
        let word = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        lines.append("00:00 — Вступление: \(word)")

        var currentOffset: Double = 2.5
        let romanNumerals = ["I", "II", "III", "IV", "V", "VI"]

        for (index, act) in acts.enumerated() {
            let mins = Int(currentOffset) / 60
            let secs = Int(currentOffset) % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            let roman = index < romanNumerals.count ? romanNumerals[index] : "\(index + 1)"
            lines.append("\(timeStr) — Акт \(roman): \(act.title)")

            currentOffset += max(act.duration, 1.0)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Default Description Generator (SOLID: SRP)

/// Генератор адаптивного описания-манифеста с драматургическим разбором фильма и актов
struct DefaultLongformDescriptionGenerator: LongformDescriptionGenerating {

    init() {}

    func generateDescription(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc,
        chaptersText: String,
        tags: [String]
    ) -> String {
        let isKnownMovie = !MovieMetadataService.isGarbageTitle(movieTitle)
        let movieRef = isKnownMovie ? "фильма «\(movieTitle)»" : "этого произведения"
        let wordCap = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized

        var sections: [String] = []

        // 1. Адаптивный авторский манифест
        var manifesto = "Кино-эссе: скрытый смысл \(movieRef) через призму темы «\(wordCap)»."
        if !concept.tagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifesto += "\n\n\(concept.tagline.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if !concept.philosophicalPremise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifesto += "\n\n\(concept.philosophicalPremise.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        sections.append(manifesto)

        // 2. Драматургический разбор фильма (arc.summary)
        let summary = arc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            sections.append("Драматургический разбор фильма:\n\(summary)")
        }

        // 3. Структура эссе по актам с драматическими битами (act.dramaticBeat)
        if !arc.acts.isEmpty {
            var actLines: [String] = ["Драматургия кино-эссе:"]
            let romanNumerals = ["I", "II", "III", "IV", "V", "VI"]
            for (index, act) in arc.acts.enumerated() {
                let roman = index < romanNumerals.count ? romanNumerals[index] : "\(index + 1)"
                let beat = act.dramaticBeat.trimmingCharacters(in: .whitespacesAndNewlines)
                if !beat.isEmpty {
                    actLines.append("• Акт \(roman): \(act.title) — \(beat)")
                } else {
                    actLines.append("• Акт \(roman): \(act.title)")
                }
            }
            sections.append(actLines.joined(separator: "\n"))
        }

        // 4. Таймкоды YouTube глав
        if !chaptersText.isEmpty {
            sections.append("Таймкоды:\n\(chaptersText)")
        }

        // 5. Кинематографический Fair Use дисклеймер
        sections.append("""
        ───────────────────────────────────────
        Disclaimer: This video is an analytical cinema essay intended for commentary, educational, and transformative artistic reflection. All footage used belongs to its respective copyright owners and is used under Fair Use principles (Section 107 of the Copyright Act).
        """)

        // 6. Семантические хэштеги из ключевых тегов
        let hashtags = buildHashtags(tags: tags, movieTitle: movieTitle, concept: concept)
        if !hashtags.isEmpty {
            sections.append(hashtags)
        }

        return sections.joined(separator: "\n\n")
    }

    private func buildHashtags(tags: [String], movieTitle: String, concept: ThematicConcept) -> String {
        var cleanHashtags: [String] = []
        var seen = Set<String>()

        func addTag(_ raw: String) {
            let filtered = raw
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
                .lowercased()
            guard !filtered.isEmpty, !seen.contains(filtered) else { return }
            seen.insert(filtered)
            cleanHashtags.append("#\(filtered)")
        }

        // Приоритетные тематические хэштеги
        addTag("киноэссе")
        addTag("смыслфильма")
        if !MovieMetadataService.isGarbageTitle(movieTitle) {
            addTag(movieTitle)
        }
        addTag(concept.word)
        addTag("психологиякино")
        addTag("разборфильма")

        // Дополнительные из общего списка тегов
        for tag in tags {
            addTag(tag)
            if cleanHashtags.count >= 10 { break }
        }

        return cleanHashtags.joined(separator: " ")
    }
}

// MARK: - Default Pinned Comment Generator (SOLID: SRP)

/// Генератор закрепленного комментария с провокационным вопросом по моральной дилемме
struct DefaultLongformPinnedCommentGenerator: LongformPinnedCommentGenerating {

    init() {}

    func generatePinnedComment(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> String {
        let isKnownMovie = !MovieMetadataService.isGarbageTitle(movieTitle)
        let movieRef = isKnownMovie ? "в «\(movieTitle)»" : "в этой истории"
        let lowerWord = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var paragraphs: [String] = []

        // 1. Сильный тезис из слогана концепта
        let tagline = concept.tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tagline.isEmpty {
            paragraphs.append("«\(tagline)»")
        }

        // 2. Провокационный вопрос о моральной дилемме темы и сюжета фильма
        let premise = concept.philosophicalPremise.trimmingCharacters(in: .whitespacesAndNewlines)
        if !premise.isEmpty {
            paragraphs.append(
                "Вопрос к тем, кто досмотрел до конца: в какой момент \(movieRef) цена темы «\(lowerWord)» становится необратимой? \(premise) Как вы лично для себя отвечаете на этот вопрос?"
            )
        } else {
            paragraphs.append(
                "Вопрос к тем, кто досмотрел до конца: в какой момент \(movieRef) стремление к «\(lowerWord)» перестает быть защитой и превращается в ловушку? Где для вас лично проходит граница между осознанным выбором и самообманом?"
            )
        }

        // 3. Призыв к обсуждению
        paragraphs.append("Поделитесь своими мыслями в комментариях 👇")

        return paragraphs.joined(separator: "\n\n")
    }
}

// MARK: - Default Tag Generator (SOLID: SRP)

/// Генератор семантических тегов для SEO и YouTube ранжирования
struct DefaultLongformTagGenerator: LongformTagGenerating {

    init() {}

    func generateTags(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func appendTag(_ tag: String) {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            result.append(trimmed)
        }

        let isKnownMovie = !MovieMetadataService.isGarbageTitle(movieTitle)
        let lowerMovie = movieTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerWord = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Теги с названием фильма
        if isKnownMovie {
            appendTag(lowerMovie)
            appendTag("\(lowerMovie) разбор")
            appendTag("\(lowerMovie) смысл")
            appendTag("\(lowerMovie) объяснение")
            appendTag("\(lowerMovie) философия")
            appendTag("\(lowerMovie) психология")
        }

        // 2. Теги философской темы и концепта
        appendTag(lowerWord)
        appendTag("смысл темы \(lowerWord)")
        appendTag("психология \(lowerWord)")
        appendTag("философия \(lowerWord)")

        // 3. Аспекты конфликта из актов
        for act in arc.acts {
            appendTag(act.title.lowercased())
        }

        // 4. Семантические теги кино-эссе
        let coreEssayTags = [
            "киноэссе",
            "смысл фильма",
            "разбор фильма",
            "психология кино",
            "философия кино",
            "драматургия",
            "глубокий разбор",
            "анализ фильма",
            "скрытый смысл",
            "кинематограф",
            "shortcast cinema"
        ]
        for tag in coreEssayTags {
            appendTag(tag)
        }

        return result
    }
}

// MARK: - LongformMetadataEngine (SOLID: DIP & OCP)

/// Движок сборки метаданных с возможностью внедрения зависимостей
struct LongformMetadataEngine: LongformMetadataGenerating {
    let titleGenerator: LongformTitleGenerating
    let chapterBuilder: LongformChapterBuilding
    let descriptionGenerator: LongformDescriptionGenerating
    let pinnedCommentGenerator: LongformPinnedCommentGenerating
    let tagGenerator: LongformTagGenerating

    init(
        titleGenerator: LongformTitleGenerating = DefaultLongformTitleGenerator(),
        chapterBuilder: LongformChapterBuilding = DefaultLongformChapterBuilder(),
        descriptionGenerator: LongformDescriptionGenerating = DefaultLongformDescriptionGenerator(),
        pinnedCommentGenerator: LongformPinnedCommentGenerating = DefaultLongformPinnedCommentGenerator(),
        tagGenerator: LongformTagGenerating = DefaultLongformTagGenerator()
    ) {
        self.titleGenerator = titleGenerator
        self.chapterBuilder = chapterBuilder
        self.descriptionGenerator = descriptionGenerator
        self.pinnedCommentGenerator = pinnedCommentGenerator
        self.tagGenerator = tagGenerator
    }

    func generate(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> LongformYouTubeMetadata {
        // 1. Адаптивный авторский заголовок
        let title = titleGenerator.generateTitle(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc
        )

        // 2. Таймкоды YouTube глав
        let chaptersText = chapterBuilder.buildChapters(
            acts: arc.acts,
            concept: concept
        )

        // 3. Семантические теги
        let tags = tagGenerator.generateTags(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc
        )

        // 4. Глубокое описание-манифест
        let description = descriptionGenerator.generateDescription(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc,
            chaptersText: chaptersText,
            tags: tags
        )

        // 5. Провокационный закрепленный комментарий
        let pinnedComment = pinnedCommentGenerator.generatePinnedComment(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc
        )

        return LongformYouTubeMetadata(
            title: title,
            description: description,
            tags: tags,
            pinnedComment: pinnedComment
        )
    }
}

// MARK: - LongformMetadataGenerator (Static Facade)

/// Публичный фасад генератора метаданных для обратной совместимости (SOLID)
enum LongformMetadataGenerator {

    private static let defaultEngine = LongformMetadataEngine()

    /// Формирует полный пакет осмысленных адаптивных метаданных для ролика
    static func generate(
        movieTitle: String,
        concept: ThematicConcept,
        arc: LongformNarrativeArc
    ) -> LongformYouTubeMetadata {
        defaultEngine.generate(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc
        )
    }
}
