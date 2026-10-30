import Foundation

/// Упаковка конкретного эссе: тексты модели, название фильма и фактический таймлайн.
enum LongformMetadataGenerator {
    static let currentVersion = 2

    /// Publication destinations come from current channel settings. Updating
    /// this footer must not rebuild the essay or change its approved arc.
    static func updatingTelegram(in metadata: LongformYouTubeMetadata, channelID: String) -> LongformYouTubeMetadata {
        guard let url = LongformEditorialSupport.telegramURL(channelID: channelID) else { return metadata }
        var updated = metadata
        if let footer = updated.description.range(of: #"(?m)^Telegram:[ \t]*https://t\.me/[^\s]+[ \t]*$"#, options: .regularExpression) {
            let old = String(updated.description[footer]).replacingOccurrences(of: "Telegram:", with: "").trimmed
            updated.description.replaceSubrange(footer, with: "Telegram: " + url)
            updated.pinnedComment = updated.pinnedComment.replacingOccurrences(of: old, with: url)
        } else {
            updated.description += "\n\nTelegram: " + url
        }
        if !updated.pinnedComment.contains(url) {
            updated.pinnedComment += "\n\nОбговорення та нові есе: " + url
        }
        return updated
    }

    static func generate(movieTitle: String, concept: ThematicConcept, arc: LongformNarrativeArc,
                         timeline: LongformTimeline? = nil) -> LongformYouTubeMetadata {
        let film = canonicalMovieTitle(movieTitle, arc: arc)
        let essayTitle = clean(arc.publicationTitle ?? concept.suggestedTitle)
        let title = publicationTitle(essay: essayTitle, film: film)
        let thesis = clean(arc.thesis ?? concept.philosophicalPremise)
        let hook = clean(arc.hookText ?? "")
        let conclusion = clean(arc.conclusionText ?? "")
        let keywords = unique([film.lowercased(), concept.word.lowercased(), "кіноесе", "розбір фільму", "Кадр і Сенс"])
        let hashtags = unique([film, concept.word, "Кіноесе", "КадрІСенс"].compactMap(hashtag))
        var paragraphs = ["«\(film)» — \(essayTitle.isEmpty ? concept.word : essayTitle)."]
        paragraphs += unique([hook, thesis, conclusion].filter { !$0.isEmpty })
        if thesis.isEmpty && !concept.tagline.trimmed.isEmpty { paragraphs.append(clean(concept.tagline)) }
        let chapters = buildChapters(acts: arc.acts, concept: concept, timeline: timeline ?? LongformTimeline(arc: arc))
        var footer = "Таймкоди:\n" + chapters
        if let url = LongformEditorialSupport.telegramURL(channelID: arc.discussionURL ?? "") {
            footer += "\n\nTelegram: " + url
        }
        footer += "\n\n" + LongformYouTubeMetadata.standardFairUseDisclaimer
        footer += "\n\n" + hashtags.joined(separator: " ")
        let body = paragraphs.joined(separator: "\n\n")
        let description = utf8Prefix(body, limit: max(0, 5_000 - footer.utf8.count - 2)) + "\n\n" + footer
        let cta = clean(LongformEditorialSupport.actionableCTA(arc.ctaText, destination: arc.discussionURL) ?? "")
        var comment = "«\(film)» — \(essayTitle.isEmpty ? concept.word : essayTitle)."
        if !cta.isEmpty { comment += "\n\n" + cta }
        else if !hook.isEmpty { comment += "\n\n" + hook }
        var metadata = LongformYouTubeMetadata(title: title, description: description,
                                               tags: keywords, pinnedComment: comment)
        metadata.hashtagTokens = hashtags
        metadata.packagingVersion = currentVersion
        return metadata
    }

    static func canonicalMovieTitle(_ supplied: String, arc: LongformNarrativeArc) -> String {
        let proposed = clean(supplied)
        if !MovieMetadataService.isGarbageTitle(proposed), !looksLikeReleaseName(proposed) { return proposed }
        let saved = clean(arc.movieTitle)
        if !MovieMetadataService.isGarbageTitle(saved), !looksLikeReleaseName(saved) { return saved }
        return proposed.isEmpty ? saved : proposed
    }

    static func publicationTitle(essay: String, film: String) -> String {
        let essay = clean(essay)
        let film = clean(film)
        guard !film.isEmpty else { return String(essay.prefix(100)) }
        if normalized(essay).contains(normalized(film)), !normalized(film).isEmpty, essay.count <= 100 { return essay }
        // Сначала резервируем имя фильма, затем сокращаем только заголовок эссе.
        let suffix = " | " + film
        guard suffix.count < 100 else { return String(film.prefix(100)) }
        let budget = 100 - suffix.count
        let heading = ellipsis(essay, limit: budget)
        return heading.isEmpty ? film : heading + suffix
    }

    static func hashtag(_ input: String) -> String? {
        let normalized = input.precomposedStringWithCanonicalMapping
        let allowed = normalized.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        let body = String(String.UnicodeScalarView(allowed))
        guard body.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return "#" + String(body.prefix(64))
    }

    static func buildChapters(acts: [LongformAct], concept: ThematicConcept, timeline: LongformTimeline) -> String {
        var lines: [String] = []
        if timeline.introDuration > 0 { lines.append("00:00 — Вступ: \(concept.word.capitalized)") }
        let roman = ["I", "II", "III", "IV", "V", "VI"]
        for (index, act) in acts.enumerated() {
            guard let offset = timeline.start(ofAct: index) else { continue }
            let time = String(format: "%02d:%02d", Int(offset) / 60, Int(offset) % 60)
            lines.append("\(time) — Акт \(index < roman.count ? roman[index] : String(index + 1)): \(act.title)")
        }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "uk_UA"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }
    private static func looksLikeReleaseName(_ text: String) -> Bool {
        text.range(of: #"(?i)(1080p|2160p|720p|bluray|x26[45]|\.mkv|\.mp4)"#, options: .regularExpression) != nil
    }
    private static func ellipsis(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))).trimmed + "…"
    }
    private static func utf8Prefix(_ text: String, limit: Int) -> String {
        var result = "", bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= limit else { break }
            result.append(character); bytes += size
        }
        return result
    }
}
