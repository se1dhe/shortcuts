import Foundation

/// Heuristic gate for the "Trending movie shorts" feed.
///
/// The goal: keep only clips from **foreign** films/series that have a **Russian
/// voiceover (dub)** — and drop Russian/Soviet productions and subtitle-only
/// (undubbed) clips. YouTube's Data API exposes no "has Russian dub" field, so we
/// score the title + description + channel text against marker lists. It's
/// deliberately conservative and easy to tune: edit the arrays below.
enum MovieShortsRelevanceFilter {

    /// Whether a search result should be shown in the recommendations feed.
    static func isRelevant(title: String, description: String, channel: String) -> Bool {
        let text = normalize([title, description, channel].joined(separator: " \n "))

        // 1. Hard-exclude clearly Russian/Soviet productions.
        if containsAny(text, russianOriginMarkers) {
            return false
        }

        // 2. Hard-exclude subtitle-only / original-audio clips (not dubbed).
        if containsAny(text, undubbedMarkers), !containsAny(text, russianDubMarkers) {
            return false
        }

        // 3. Keep if there's an explicit Russian-dub / Russian-studio marker.
        if containsAny(text, russianDubMarkers) {
            return true
        }

        // 4. Otherwise accept only when the clip looks like a Russian-language
        //    channel presenting a FOREIGN title: Cyrillic text (Russian caption)
        //    together with a foreign-origin cue (a Latin original title, a year in
        //    parentheses, or an English word). A Russian channel captioning a
        //    foreign film in Russian almost always ships Russian audio.
        return hasCyrillic(text) && hasForeignCue(text)
    }

    static func isRelevant(_ result: YouTubeSearchResult) -> Bool {
        isRelevant(title: result.title, description: result.description, channel: result.channel)
    }

    // MARK: - Marker lists (lowercased, no leading '#')

    /// Explicit "this has a Russian dub" signals, incl. well-known RU dub studios.
    static let russianDubMarkers: [String] = [
        "дубляж", "дублирован", "дублированный", "в дубляже",
        "озвучка", "озвучание", "озвучено", "русская озвучка", "рус озвучка",
        "рус. озвучка", "на русском", "русский дубляж", "многоголос", "многоголосый",
        "профессиональный перевод", "перевод и озвучка", "лостфильм", "lostfilm",
        "кубик в кубе", "hdrezka", "резка", "невафильм", "пифагор",
        "дублированный трейлер", "русский трейлер",
    ]

    /// Subtitle-only / original-audio signals — present a clip WITHOUT a dub.
    static let undubbedMarkers: [String] = [
        "субтитры", "с субтитрами", "original audio", "оригинальная озвучка",
        "оригинальная дорожка", "на английском", "eng audio", "без перевода",
        "original language", "sub rus", "рус суб",
    ]

    /// Russian/Soviet production markers — the stuff we want to drop entirely.
    static let russianOriginMarkers: [String] = [
        "российский фильм", "русский фильм", "российский сериал", "русский сериал",
        "советский фильм", "советское кино", "советский", "ссср", "мосфильм",
        "ленфильм", "союзмультфильм", "отечественн", "наше кино", "русское кино",
        "снят в россии", "производство россия", "российское кино", "россия 1",
        "нтв", "тнт", "стс", "первый канал", "кинопоиск originals", "okko originals",
        "premier", "wink originals", "start originals",
    ]

    // MARK: - Text helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
    }

    /// Foreign-origin cue: a 4-digit year, or a run of Latin letters (an original
    /// title / English word) that isn't just a stray character.
    private static func hasForeignCue(_ s: String) -> Bool {
        if s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
            return true
        }
        if s.range(of: #"[a-z]{3,}"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
