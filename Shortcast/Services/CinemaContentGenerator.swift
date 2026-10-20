import Foundation

/// Generates cinema-style captions and hashtags from a movie title/year,
/// optionally backed by TMDB metadata. Extracted from the old readiness-analysis
/// sheet so the same logic lives in the clip editor.
enum CinemaContentGenerator {

    struct MovieSearchQuery: Hashable {
        var title: String
        var year: String?

        func hash(into hasher: inout Hasher) {
            hasher.combine(title.lowercased())
            hasher.combine(year ?? "")
        }

        static func == (lhs: MovieSearchQuery, rhs: MovieSearchQuery) -> Bool {
            lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame && lhs.year == rhs.year
        }
    }

    struct GeneratedContent {
        var hook: String
        var description: String
        var hashtags: String
    }

    /// What goes into the post `description`: a caption describing the actual
    /// scene (written by the on-device model from the clip transcript) or the
    /// movie's own synopsis. Chosen per clip in the editor.
    enum DescriptionMode: String, Codable, CaseIterable, Sendable, Identifiable {
        case scene
        case movie

        var id: String { rawValue }
    }

    /// Looks the movie up on TMDB (returning every candidate so the caller can
    /// disambiguate e.g. "Острые козырьки" vs "Острые козырьки: Бессмертный")
    /// and returns generated platform content. If TMDB has no result, generates
    /// from the entered title/year.
    ///
    /// - Parameters:
    ///   - preselectedMovie: when the user has already picked a specific movie
    ///     from the dropdown, skip the TMDB search and use it directly.
    ///   - descriptionMode: whether the description is the scene caption or the
    ///     movie synopsis.
    ///   - sceneDescriptionProvider: supplies the on-device scene caption; only
    ///     called when `descriptionMode == .scene`.
    @MainActor
    static func generate(
        query: MovieSearchQuery,
        sourceText: String,
        tmdbAPIKey: String,
        descriptionMode: DescriptionMode = .scene,
        textAd: Bool = false,
        preselectedMovie: TMDBMovie? = nil,
        sceneDescriptionProvider: (() async -> String?)? = nil,
        fallbackMovieProvider: (() async -> TMDBMovie?)? = nil
    ) async -> (movie: TMDBMovie?, candidates: [TMDBMovie], query: MovieSearchQuery, content: [SocialPlatform: GeneratedContent], error: String?) {

        var movie: TMDBMovie? = preselectedMovie
        var candidates: [TMDBMovie] = preselectedMovie.map { [$0] } ?? []
        var error: String?

        if movie == nil, !tmdbAPIKey.trimmed.isEmpty {
            let service = TMDBService(apiKey: tmdbAPIKey.trimmed)
            for searchQuery in manualMovieSearchQueries(from: query) {
                if let found = try? await service.searchMovies(by: searchQuery.title, year: searchQuery.year),
                   !found.isEmpty {
                    candidates = found
                    movie = found.first
                    break
                }
            }
        }

        if movie == nil, let fallbackMovieProvider {
            movie = await fallbackMovieProvider()
            if let movie { candidates = [movie] }
        }

        // Resolve the description text once, then reuse across platforms. In text-ad
        // mode we only need the movie name, so skip the (slower) scene caption.
        var sceneDescription: String?
        if descriptionMode == .scene, !textAd, let sceneDescriptionProvider {
            sceneDescription = (await sceneDescriptionProvider())?.trimmed
        }

        let content: [SocialPlatform: GeneratedContent]
        let resolvedQuery: MovieSearchQuery
        if let movie {
            resolvedQuery = MovieSearchQuery(
                title: movie.title,
                year: movie.year.isEmpty ? query.year : movie.year)
            content = cinemaPlatformContent(
                movie: movie,
                descriptionMode: descriptionMode,
                textAd: textAd,
                sceneDescription: sceneDescription)
        } else {
            resolvedQuery = query
            content = cinemaPlatformContent(
                query: query,
                sourceText: sourceText,
                descriptionMode: descriptionMode,
                textAd: textAd,
                sceneDescription: sceneDescription)
            if !tmdbAPIKey.trimmed.isEmpty {
                error = String(localized: "TMDB did not find this movie. Generated from entered title and year.")
            }
        }

        return (movie, candidates, resolvedQuery, content, error)
    }

    /// Applies generated cinema content to a clip's variants and overlay text.
    ///
    /// - Parameter replaceHook: When `true` the cinema hook («🎬 Title (Year)») is
    ///   also written to `variant.hook` and used as the clip's overlay text. Pass
    ///   `true` when applying cinema content automatically (e.g. right after a
    ///   YouTube Short is downloaded); keep the default `false` when re-generating
    ///   from the manual editor so that a model-generated hook already present is
    ///   not silently clobbered.
    @MainActor
    static func apply(
        content: [SocialPlatform: GeneratedContent],
        to clip: ShortClip,
        replaceHook: Bool = false,
        saveToHistory: Bool = false,
        settings: AppSettings? = nil
    ) {
        for (platform, generated) in content {
            let index: Int
            if let existing = clip.variants.firstIndex(where: { $0.platform == platform }) {
                index = existing
            } else {
                clip.variants.append(PostVariant(platform: platform, hook: "", summary: "", hashtags: [], pinnedComment: ""))
                index = clip.variants.count - 1
            }

            // When replaceHook is true (automatic cinema mode) we write the
            // cinema-style hook; otherwise we preserve whatever the model wrote.
            if replaceHook && !generated.hook.isEmpty {
                clip.variants[index].hook = generated.hook
            }
            if !generated.description.isEmpty {
                clip.variants[index].summary = generated.description
            }
            if !generated.hashtags.isEmpty {
                let tags = generated.hashtags
                    .split { $0 == " " || $0 == "," }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                    .filter { !$0.isEmpty }
                clip.variants[index].hashtags = tags.map { $0.lowercased() }
            }
        }

        if replaceHook {
            let channel = settings?.telegramChannelId.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !channel.isEmpty {
                clip.overlayText = "🍿 Назва в Telegram: \(channel)"
            }
        }

        if saveToHistory, let settings, let tiktok = content[.tiktok] {
            saveProcessedRecord(tiktok: tiktok, clip: clip, settings: settings)
        }
    }

    // MARK: - Saving to history

    @MainActor
    private static func saveProcessedRecord(tiktok: GeneratedContent, clip: ShortClip, settings: AppSettings) {
        guard let url = clip.sourceMetadata?.webpageURL else { return }
        let videoID = url.pathComponents.last ?? url.lastPathComponent
        let tiktokVariant = clip.variants.first { $0.platform == .tiktok }
        let record = ProcessedVideoRecord(
            youtubeURL: url,
            videoID: videoID,
            title: clip.sourceMetadata?.title ?? clip.displayTitle,
            dateProcessed: Date(),
            hook: tiktokVariant?.hook ?? tiktok.hook,
            description: tiktokVariant?.summary ?? tiktok.description,
            hashtags: tiktokVariant?.hashtagLine ?? tiktok.hashtags)
        var history = settings.processedVideoHistory
        history.append(record)
        settings.processedVideoHistory = history
    }

    // MARK: - Query helpers

    static func manualMovieSearchQueries(from query: MovieSearchQuery) -> [MovieSearchQuery] {
        let title = query.title.trimmed
        var candidates = [
            MovieSearchQuery(title: title, year: query.year)
        ]
        candidates.append(contentsOf: candidates.map { MovieSearchQuery(title: $0.title, year: nil) })

        var seen = Set<MovieSearchQuery>()
        return candidates
            .filter { !$0.title.trimmed.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    /// Tries to extract an explicit movie query from source metadata text.
    static func explicitMovieQuery(from sourceText: String) -> MovieSearchQuery? {
        let candidates = [
            explicitMovieQueries(from: sourceText).first,
            cleanedTMDBQueries(from: sourceText).first
        ]
        return candidates.compactMap { $0 }.first
    }

    /// Best-effort human-readable film title from a messy source (a YouTube
    /// Shorts title like "Джентльмены нарезка #shorts дубляж"). Prefers an
    /// explicit quoted/parenthesized title, otherwise strips hashtags, emoji,
    /// bracketed junk, channel separators and content-type words to leave just
    /// the title. Used to seed the "Movie title" field; Regenerate then
    /// canonicalizes it against TMDB.
    static func movieTitleGuess(from raw: String) -> MovieSearchQuery? {
        if MovieMetadataService.isGarbageTitle(raw) { return nil }
        if let explicit = explicitMovieQuery(from: raw) {
            if !MovieMetadataService.isGarbageTitle(explicit.title) {
                return explicit
            }
        }

        let parsedCandidate = MovieMetadataService.parseCandidate(raw)
        if !parsedCandidate.title.isEmpty && !MovieMetadataService.isGarbageTitle(parsedCandidate.title) {
            return MovieSearchQuery(title: parsedCandidate.title, year: parsedCandidate.year)
        }

        // Pull a year out before we strip parentheses.
        let year = raw.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression)
            .map { String(raw[$0]) }

        var text = raw
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"#\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"@\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)

        // Keep only the first segment before a channel/title separator.
        if let sep = text.range(of: #"[|•·—–:\n]"#, options: .regularExpression) {
            text = String(text[..<sep.lowerBound])
        }

        // Drop emoji / symbols and years, collapse punctuation to spaces.
        text = text
            .replacingOccurrences(of: #"[\p{Emoji_Presentation}\p{So}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(19|20)\d{2}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s'’-]"#, with: " ", options: .regularExpression)

        // Remove content-type / marketing words (whole words, case-insensitive).
        let words = text
            .split { $0 == " " || $0 == "\t" }
            .map(String.init)
            .filter { !titleStopwords.contains($0.lowercased()) }

        let title = words.prefix(6).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed

        guard title.count >= 2, !MovieMetadataService.isGarbageTitle(title) else { return nil }
        return MovieSearchQuery(title: title, year: year)
    }

    /// Words that describe the clip, not the film — stripped from title guesses.
    private static let titleStopwords: Set<String> = [
        "нарізка", "нарізки", "нарізкою", "дубляж", "дубляжі", "дубляжем",
        "озвучка", "озвучці", "озвучкою", "озвучка.", "сцена", "сцени", "сцену",
        "момент", "моменти", "моментів", "фільм", "фільму", "фільми", "фільмі",
        "серіал", "серіалу", "серіали", "кіно", "дивитися", "онлайн", "трейлер",
        "огляд", "частина", "серія", "сезон", "повністю", "повний", "найкращі",
        "найкращий", "топ", "з", "по",
        "movie", "clip", "clips", "scene", "scenes", "moment", "moments", "best",
        "trailer", "full", "hd", "4k", "shorts", "short", "edit", "recap",
    ]

    static func cleanedTMDBQueries(from raw: String) -> [MovieSearchQuery] {
        var queries: [MovieSearchQuery] = []

        queries.append(contentsOf: explicitMovieQueries(from: raw))

        let removedExplicitMovieHints = explicitMovieQueries(from: raw).reduce(raw) { value, query in
            var next = value.replacingOccurrences(of: query.title, with: " ", options: .caseInsensitive)
            if let year = query.year {
                next = next.replacingOccurrences(of: year, with: " ")
            }
            return next
        }

        let withoutID = removedExplicitMovieHints
            .replacingOccurrences(of: #"-[A-Za-z0-9_-]{8,}\.[A-Za-z0-9]+$"#,
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#,
                                  with: "",
                                  options: .regularExpression)
        let base = withoutID
            .replacingOccurrences(of: #"#\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(shorts?|movie clips?|фільм|кіно|нарізка|сцена|сцени)\b"#,
                                  with: " ",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[|•_]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed

        let splitParts = base
            .components(separatedBy: CharacterSet(charactersIn: "-–—:"))
            .map(\.trimmed)
            .filter { $0.count >= 2 }

        queries.append(contentsOf: ([base] + splitParts)
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .map { MovieSearchQuery(title: $0, year: nil) })
        return queries.filter { !MovieMetadataService.isGarbageTitle($0.title) }
    }

    static func explicitMovieQueries(from raw: String) -> [MovieSearchQuery] {
        var queries: [MovieSearchQuery] = []

        // 1. Explicit keyword prefix: "Название фильма:", "Фильм:", "Movie:", "🎬Название фильма:", etc.
        let prefixPattern = #"(?i)(?:🎬\s*)?(?:назва\s+фільму|фільм|серіал|кіно|movie|film|title)\s*[:\-—–]\s*([^\n#⭐🎥🎬]+)"#
        for match in regexRanges(pattern: prefixPattern, in: raw) {
            let matched = String(raw[match])
            if let colonIndex = matched.firstIndex(where: { [":", "-", "—", "–"].contains($0) }) {
                let textAfterColon = String(matched[matched.index(after: colonIndex)...]).trimmed

                let year = textAfterColon.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression)
                    .map { String(textAfterColon[$0]) }

                var title = textAfterColon
                if let slashIndex = title.firstIndex(of: "/") {
                    title = String(title[..<slashIndex])
                }
                if let parenIndex = title.firstIndex(of: "(") {
                    title = String(title[..<parenIndex])
                }

                title = title
                    .replacingOccurrences(of: #"["«»]"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\b(19|20)\d{2}\b"#, with: "", options: .regularExpression)
                    .trimmed

                if title.count >= 2 {
                    queries.append(MovieSearchQuery(title: title, year: year))
                }
            }
        }

        // 2. Title with Year in parentheses: "Побег из Шоушенка (1994)"
        let titleWithYearPattern = #"([^\n#🎬⭐🎥:/\\]+?)\s*\(\s*((?:19|20)\d{2})\s*\)"#
        for match in regexRanges(pattern: titleWithYearPattern, in: raw) {
            let matched = String(raw[match])
            if let openParen = matched.lastIndex(of: "("), let closeParen = matched.lastIndex(of: ")") {
                let title = String(matched[..<openParen])
                    .replacingOccurrences(of: #"(?i)\b(назва фільму|фільм|серіал|кіно|movie|film)\b"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"["«»:]"#, with: "", options: .regularExpression)
                    .trimmed
                let year = String(matched[matched.index(after: openParen)..<closeParen]).trimmed
                if title.count >= 2 {
                    queries.append(MovieSearchQuery(title: title, year: year))
                }
            }
        }

        // 3. Quoted pattern: "Побег из Шоушенка" (1994) or «Побег из Шоушенка»
        let quotedPattern = #"["«]([^"»]+)["»]\s*(\d{4})?"#
        for match in regexRanges(pattern: quotedPattern, in: raw) {
            let matched = String(raw[match])
            let title = matched
                .replacingOccurrences(of: #"["«»]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\d{4}"#, with: "", options: .regularExpression)
                .trimmed
            let year = matched.range(of: #"\d{4}"#, options: .regularExpression).map { String(matched[$0]) }
            if title.count >= 2 {
                queries.append(MovieSearchQuery(title: title, year: year))
            }
        }

        var seen = Set<MovieSearchQuery>()
        return queries.filter { seen.insert($0).inserted }
    }

    // MARK: - Content builders

    private static func cinemaPlatformContent(
        movie: TMDBMovie,
        descriptionMode: DescriptionMode,
        textAd: Bool,
        sceneDescription: String?
    ) -> [SocialPlatform: GeneratedContent] {
        let yearPart = movie.year.isEmpty ? "" : " (\(movie.year))"
        let title = movie.title
        let synopsis = resolvedBodyText(
            overview: movie.overview,
            descriptionMode: descriptionMode,
            sceneDescription: sceneDescription)

        // Viral hooks (intrigue without spoiling the movie title)
        let viralVideoHook = "Такої розв'язки ніхто не очікував... 😳"
        let youtubeHook = "Такої розв'язки точно ніхто не очікував... 😳 #Shorts"
        let telegramHook = "🎬 \(title)\(yearPart)"

        // Viral platform-specific descriptions with @telonyx_club funnel
        let tiktokDesc = tiktokViralDescription(synopsis: synopsis, textAd: textAd)
        let instaDesc = instagramViralDescription(synopsis: synopsis, textAd: textAd)
        let youtubeDesc = youtubeViralDescription(synopsis: synopsis, textAd: textAd)
        let telegramDesc = telegramCardDescription(title: title, yearPart: yearPart, synopsis: synopsis, movie: movie)

        // Viral hashtags (genres and trends only, no movie title in video platforms!)
        let movieGenresAndCast = baseCinemaHashtags(movie: movie, includeTitle: false)
        let telegramMovieTags = baseCinemaHashtags(movie: movie, includeTitle: true)

        let tiktokTags = buildViralHashtags(base: movieGenresAndCast, trending: tiktokViralHashtags, maxCount: 12, textAd: textAd)
        let instaTags = buildViralHashtags(base: movieGenresAndCast, trending: instagramViralHashtags, maxCount: 15, textAd: textAd)
        let youtubeTags = buildViralHashtags(base: movieGenresAndCast, trending: youtubeShortsViralHashtags, maxCount: 10, textAd: textAd)

        return [
            .tiktok: GeneratedContent(hook: viralVideoHook, description: tiktokDesc, hashtags: tiktokTags.joined(separator: " ")),
            .instagram: GeneratedContent(hook: viralVideoHook, description: instaDesc, hashtags: instaTags.joined(separator: " ")),
            .youtube: GeneratedContent(hook: youtubeHook, description: youtubeDesc, hashtags: youtubeTags.joined(separator: " ")),
            .telegram: GeneratedContent(hook: telegramHook, description: telegramDesc, hashtags: telegramMovieTags.joined(separator: " "))
        ]
    }

    private static func cinemaPlatformContent(
        query: MovieSearchQuery,
        sourceText: String,
        descriptionMode: DescriptionMode,
        textAd: Bool,
        sceneDescription: String?
    ) -> [SocialPlatform: GeneratedContent] {
        let yearPart = query.year?.trimmed.isEmpty == false ? " (\(query.year!.trimmed))" : ""
        let title = query.title
        let synopsis = sceneDescription?.trimmed ?? ""

        let viralVideoHook = "Такої розв'язки ніхто не очікував... 😳"
        let youtubeHook = "Такої розв'язки точно ніхто не очікував... 😳 #Shorts"
        let telegramHook = "🎬 \(title)\(yearPart)"

        let tiktokDesc = tiktokViralDescription(synopsis: synopsis, textAd: textAd)
        let instaDesc = instagramViralDescription(synopsis: synopsis, textAd: textAd)
        let youtubeDesc = youtubeViralDescription(synopsis: synopsis, textAd: textAd)
        let telegramDesc = telegramCardDescription(title: title, yearPart: yearPart, synopsis: synopsis, movie: nil)

        let plainTags = baseCinemaHashtags(title: title, sourceText: sourceText, includeTitle: false)
        let telegramTags = baseCinemaHashtags(title: title, sourceText: sourceText, includeTitle: true)

        let tiktokTags = buildViralHashtags(base: plainTags, trending: tiktokViralHashtags, maxCount: 12, textAd: textAd)
        let instaTags = buildViralHashtags(base: plainTags, trending: instagramViralHashtags, maxCount: 15, textAd: textAd)
        let youtubeTags = buildViralHashtags(base: plainTags, trending: youtubeShortsViralHashtags, maxCount: 10, textAd: textAd)

        return [
            .tiktok: GeneratedContent(hook: viralVideoHook, description: tiktokDesc, hashtags: tiktokTags.joined(separator: " ")),
            .instagram: GeneratedContent(hook: viralVideoHook, description: instaDesc, hashtags: instaTags.joined(separator: " ")),
            .youtube: GeneratedContent(hook: youtubeHook, description: youtubeDesc, hashtags: youtubeTags.joined(separator: " ")),
            .telegram: GeneratedContent(hook: telegramHook, description: telegramDesc, hashtags: telegramTags.joined(separator: " "))
        ]
    }

    private static func resolvedBodyText(
        overview: String,
        descriptionMode: DescriptionMode,
        sceneDescription: String?
    ) -> String {
        let overview = overview.trimmed
        let scene = sceneDescription?.trimmed ?? ""
        switch descriptionMode {
        case .scene:
            return !scene.isEmpty ? scene : overview
        case .movie:
            return !overview.isEmpty ? overview : scene
        }
    }

    private static func tiktokViralDescription(
        synopsis: String,
        textAd: Bool
    ) -> String {
        if textAd {
            return "Такої розв'язки ніхто не очікував... 😳\n\n🎬 Назва фільму і де дивитися вже в Telegram: @telonyx_club\n\n\(botAdMessage())\n\nДивись до кінця 👇"
        }
        let leadIn = "Такої розв'язки точно ніхто не очікував... 😳"
        let brief = synopsis.count > 140 ? String(synopsis.prefix(140).trimmingCharacters(in: .whitespacesAndNewlines)) + "..." : synopsis
        var text = leadIn
        if !brief.isEmpty {
            text += "\n\n\(brief)"
        }
        text += "\n\nЯк би ти вчинив на його місці? Напиши в коментарі 👇"
        text += "\n\n🍿 Назву фільму і де подивитися вже виклали в наш Telegram: @telonyx_club (активне посилання в шапці профілю 👆)"
        return text
    }

    private static func instagramViralDescription(
        synopsis: String,
        textAd: Bool
    ) -> String {
        if textAd {
            return "Цей момент пробирає до мурашок... 🍿\n\n🎬 Назва фільму в шапці профілю 👆 (Telegram: @telonyx_club)\n\n\(botAdMessage())\n\n📌 Зберігай у закладки!"
        }
        var text = "Цей момент пробирає до мурашок... 🍿"
        if !synopsis.isEmpty {
            text += "\n\n\(synopsis)"
        }
        text += "\n\n📌 Зберігай, щоб не втратити на вечір!\nОціни цей момент від 1 до 10 у коментарях 👇"
        text += "\n\n🎬 Назва фільму і де подивитися — в шапці профілю 👆 (Telegram: @telonyx_club)"
        return text
    }

    private static func youtubeViralDescription(
        synopsis: String,
        textAd: Bool
    ) -> String {
        if textAd {
            return "Такої розв'язки ніхто не очікував... 😳 #Shorts\n\n🎬 Назва фільму в Telegram: https://t.me/telonyx_club\n\n\(botAdMessage())\n\n#Shorts #кіно #фільми"
        }
        var text = "Такої розв'язки точно ніхто не очікував... 😳"
        if !synopsis.isEmpty {
            text += "\n\n\(synopsis)"
        }
        text += "\n\n🎬 Назву фільму і де подивитися виклали в наш Telegram: https://t.me/telonyx_club (посилання в описі каналу та в закріпленому коментарі) 👇"
        text += "\n\n🔔 Підписуйся на канал, щоб не пропустити найкращі моменти з кіно!\n\n#Shorts #кіно #фільми"
        return text
    }

    private static func telegramCardDescription(
        title: String,
        yearPart: String,
        synopsis: String,
        movie: TMDBMovie?
    ) -> String {
        var lines: [String] = []
        lines.append("🎬 «\(title)»\(yearPart)")
        lines.append("")

        var metaItems: [String] = []
        if let imdb = movie?.imdbRating, imdb > 0 {
            metaItems.append(String(format: "⭐️ IMDb: %.1f", imdb))
        }
        if let genres = movie?.genres, !genres.isEmpty {
            metaItems.append("🎭 " + genres.prefix(3).joined(separator: ", "))
        }
        if !metaItems.isEmpty {
            lines.append(metaItems.joined(separator: " | "))
            lines.append("")
        }

        if !synopsis.isEmpty {
            lines.append("📝 Про фільм:")
            let overviewText = synopsis.count > 500 ? String(synopsis.prefix(500).trimmingCharacters(in: .whitespacesAndNewlines)) + "..." : synopsis
            lines.append(overviewText)
            lines.append("")
        }

        lines.append("🍿 Приємного перегляду!")
        lines.append("Канал: @telonyx_club")
        return lines.joined(separator: "\n")
    }

    /// The channel hashtag, placed right after the movie-title hashtag.
    private static func withBotHashtag(_ tags: [String]) -> [String] {
        let channelTag = "#telonyx_club"
        var out = tags.filter { $0.lowercased() != channelTag }
        out.insert(channelTag, at: min(1, out.count))
        return out
    }

    /// A rotating pool of catchy Russian promos for the @telonyx_club Telegram channel,
    /// used as the post description in text-ad mode.
    private static func botAdMessage() -> String {
        channelAdMessages.randomElement() ?? channelAdMessages[0]
    }

    private static let channelAdMessages: [String] = [
        "Шукаєш, що подивитися ввечері? 🍿 Ексклюзивні підбірки шедеврів кіно, приховані діаманти та прем'єри — щодня в нашому закритому клубі: https://t.me/telonyx_club 🎬",
        "Назва фільму, огляд та найкращі моменти без цензури вже в нашому Telegram: https://t.me/telonyx_club 🍿 Переходь та підписуйся!",
        "Хочеш більше потужних сцен та топових фільмів на вечір? Приєднуйся до кіноманів у Telegram: https://t.me/telonyx_club 🍿",
        "Вся інформація про цей фільм та тисячі інших рекомендацій — в нашому Telegram-каналі https://t.me/telonyx_club 🎬 Тисни та дивись!",
        "Кіно без спойлерів і нудних списків. Тільки найкраще кіно з усього світу: https://t.me/telonyx_club 🍿"
    ]

    private static func baseCinemaHashtags(movie: TMDBMovie, includeTitle: Bool) -> [String] {
        var tags: [String] = []
        if includeTitle {
            tags.append(hashtag(movie.title))
        }
        tags.append(contentsOf: movie.genres.prefix(3).map(hashtag))
        tags.append(contentsOf: movie.cast.prefix(2).map(hashtag))
        if let director = movie.director {
            tags.append(hashtag(director))
        }

        var seen = Set<String>()
        return tags
            .map(\.trimmed)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func baseCinemaHashtags(title: String, sourceText: String, includeTitle: Bool) -> [String] {
        var tags: [String] = []
        if includeTitle {
            tags.append(hashtag(title))
        }
        tags.append(contentsOf: Self.hashtags(from: sourceText)
            .filter { !Self.genericCinemaHashtags.contains($0.lowercased()) }
            .prefix(3))

        var seen = Set<String>()
        return tags
            .map(\.trimmed)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func combineHashtags(base: [String], trending: [String]) -> [String] {
        let existing = Set(base.map { $0.lowercased() })
        return base + trending.filter { !existing.contains($0.lowercased()) }
    }

    private static var tiktokViralHashtags: [String] {
        [
            "#кіноввечір", "#моментзфільму", "#фільми", "#кіно", "#фільм",
            "#уривокзфільму", "#найкращіфільми", "#щоподивитися",
            "#рек", "#рекомендації", "#fyp", "#fypシ"
        ]
    }

    private static var instagramViralHashtags: [String] {
        [
            "#reels", "#reelsinstagram", "#кіно", "#фільм", "#фільмнавечір",
            "#уривокзфільму", "#моментзфільму", "#кіноман",
            "#найкращіфільми", "#топфільми", "#кінопошук", "#вкіно"
        ]
    }

    private static var youtubeShortsViralHashtags: [String] {
        [
            "#Shorts", "#кіно", "#фільми", "#фільмнавечір",
            "#моментизфільмів", "#найкращіфільми", "#топкіно",
            "#шортс", "#shortsyoutube", "#кінопошук"
        ]
    }

    private static func buildViralHashtags(base: [String], trending: [String], maxCount: Int, textAd: Bool) -> [String] {
        let combined = combineHashtags(base: base, trending: trending)
        let withAd = textAd ? withBotHashtag(combined) : combined
        return Array(withAd.prefix(maxCount))
    }

    private static func hashtags(from raw: String) -> [String] {
        regexRanges(pattern: #"#([^\s\]\)]+)"#, in: raw)
            .map { String(raw[$0]).trimmed }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\"]")) }
            .filter { $0.count > 1 }
    }

    private static var genericCinemaHashtags: Set<String> {
        [
            "#кіно", "#фільм", "#фільми", "#серіал", "#серіали", "#short", "#shorts",
            "#момент", "#моменткіно", "#моментфільму", "#моментзфільму", "#нарізка",
            "#кіноогляд", "#рекомендації", "#щоподивитися"
        ]
    }

    private static func regexRanges(pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { Range($0.range, in: text) }
    }

    private static func hashtag(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
            .trimmed
        return cleaned.isEmpty ? "" : "#\(cleaned)"
    }
}
