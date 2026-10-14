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
        candidateHook: String? = nil,
        candidateSummary: String? = nil,
        transcriptSlice: String? = nil,
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
                sceneDescription: sceneDescription,
                candidateHook: candidateHook,
                candidateSummary: candidateSummary,
                transcriptSlice: transcriptSlice)
        } else {
            resolvedQuery = query
            content = cinemaPlatformContent(
                query: query,
                sourceText: sourceText,
                descriptionMode: descriptionMode,
                textAd: textAd,
                sceneDescription: sceneDescription,
                candidateHook: candidateHook,
                candidateSummary: candidateSummary,
                transcriptSlice: transcriptSlice)
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
                clip.overlayText = "🍿 Название в Telegram: \(channel)"
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
        "нарезка", "нарезки", "нарезкой", "дубляж", "дубляже", "дубляжом",
        "озвучка", "озвучке", "озвучкой", "озвучка.", "сцена", "сцены", "сцену",
        "момент", "моменты", "моментов", "фильм", "фильма", "фильмы", "фильме",
        "сериал", "сериала", "сериалы", "кино", "смотреть", "онлайн", "трейлер",
        "обзор", "часть", "серия", "сезон", "полностью", "полный", "лучшие",
        "лучший", "топ", "из", "по",
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
            .replacingOccurrences(of: #"(?i)\b(shorts?|movie clips?|фильм|кино|нарезка|сцена|сцены)\b"#,
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
        let prefixPattern = #"(?i)(?:🎬\s*)?(?:название\s+фильма|фильм|сериал|кино|movie|film|title)\s*[:\-—–]\s*([^\n#⭐🎥🎬]+)"#
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
                    .replacingOccurrences(of: #"(?i)\b(название фильма|фильм|сериал|кино|movie|film)\b"#, with: "", options: .regularExpression)
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

    // MARK: - Platform Copywriters (SOLID / OCP / SRP)

    /// Context describing the movie, scene, and platform parameters for copywriting.
    struct CinemaSceneContext: Sendable {
        var movieTitle: String
        var year: String?
        var genres: [String] = []
        var overview: String = ""
        var imdbRating: Double? = nil
        var cast: [String] = []
        var director: String? = nil
        var candidateHook: String? = nil
        var candidateSummary: String? = nil
        var transcriptSlice: String? = nil
        var descriptionMode: DescriptionMode = .scene
        var textAd: Bool = false
        var sourceText: String = ""
    }

    /// Contract for platform-specific copywriting (Open/Closed & Liskov Substitution).
    protocol CinemaPlatformCopywriter: Sendable {
        var platform: SocialPlatform { get }
        func generate(context: CinemaSceneContext) -> GeneratedContent
    }

    /// TikTok copywriter: Dynamic viral hook, intriguing hero dilemma, comment discussion call, genre hashtags.
    struct TikTokCinemaCopywriter: CinemaPlatformCopywriter {
        var platform: SocialPlatform { .tiktok }

        func generate(context: CinemaSceneContext) -> GeneratedContent {
            let hook = buildHook(context: context)
            let description = buildDescription(context: context)
            let hashtags = buildHashtags(context: context)
            return GeneratedContent(hook: hook, description: description, hashtags: hashtags)
        }

        private func buildHook(context: CinemaSceneContext) -> String {
            if let hook = context.candidateHook?.trimmed, !hook.isEmpty {
                return hook.hasTerminalEmoji ? hook : "\(hook) 😳"
            }
            return CinemaContentGenerator.dynamicGenreHook(genres: context.genres, defaultEmoji: "😳")
        }

        private func buildDescription(context: CinemaSceneContext) -> String {
            if context.textAd {
                let dynamicHook = buildHook(context: context)
                return "\(dynamicHook)\n\n🎬 Название фильма и где смотреть уже в Telegram: @telonyx_club\n\n\(CinemaContentGenerator.botAdMessage())\n\nСмотри до конца 👇"
            }

            let effectiveSummary = CinemaContentGenerator.resolvedSceneSummary(context: context)
            let brief = effectiveSummary.count > 180
                ? String(effectiveSummary.prefix(180).trimmingCharacters(in: .whitespacesAndNewlines)) + "..."
                : effectiveSummary

            var paragraphs: [String] = []
            if !brief.isEmpty {
                paragraphs.append(brief)
            }

            let lower = context.genres.map { $0.lowercased() }
            let dilemmaQuestion: String
            if lower.contains(where: { $0.contains("комеди") }) {
                dilemmaQuestion = "Узнали себя или знакомого в этой ситуации? 😂 Напишите в комменты 👇"
            } else {
                dilemmaQuestion = "Как бы ты поступил на месте героя? Напиши в комменты 👇"
            }
            paragraphs.append(dilemmaQuestion)
            paragraphs.append("🍿 Название фильма и где посмотреть уже выложили в наш Telegram: @telonyx_club (активная ссылка в шапке профиля 👆)")

            return paragraphs.joined(separator: "\n\n")
        }

        private func buildHashtags(context: CinemaSceneContext) -> String {
            let base = CinemaContentGenerator.baseGenresAndCastHashtags(context: context, includeTitle: false)
            let tags = CinemaContentGenerator.buildViralHashtags(
                base: base,
                trending: CinemaContentGenerator.tiktokViralHashtags,
                maxCount: 12,
                textAd: context.textAd
            )
            return tags.joined(separator: " ")
        }
    }

    /// Instagram Reels copywriter: Cinematographic hook, acting and atmospheric tension, save call, aesthetics tags.
    struct InstagramCinemaCopywriter: CinemaPlatformCopywriter {
        var platform: SocialPlatform { .instagram }

        func generate(context: CinemaSceneContext) -> GeneratedContent {
            let hook = buildHook(context: context)
            let description = buildDescription(context: context)
            let hashtags = buildHashtags(context: context)
            return GeneratedContent(hook: hook, description: description, hashtags: hashtags)
        }

        private func buildHook(context: CinemaSceneContext) -> String {
            if let hook = context.candidateHook?.trimmed, !hook.isEmpty {
                return hook.hasTerminalEmoji ? hook : "🎬 \(hook) 🍿"
            }
            let lower = context.genres.map { $0.lowercased() }
            if lower.contains(where: { $0.contains("триллер") || $0.contains("драма") }) {
                return "Культовый момент: когда атмосфера и актерская игра на пределе 🎭"
            }
            return "Момент, ради которого стоит пересмотреть весь фильм 🍿"
        }

        private func buildDescription(context: CinemaSceneContext) -> String {
            if context.textAd {
                return "Этот момент пробирает до мурашек... 🍿\n\n🎬 Название фильма в шапке профиля 👆 (Telegram: @telonyx_club)\n\n\(CinemaContentGenerator.botAdMessage())\n\n📌 Сохраняй в закладки!"
            }

            var paragraphs: [String] = []
            paragraphs.append("Этот момент пробирает до мурашек... Актерская игра и режиссура создают невероятное напряжение. 🍿")

            let effectiveSummary = CinemaContentGenerator.resolvedSceneSummary(context: context)
            if !effectiveSummary.isEmpty {
                paragraphs.append(effectiveSummary)
            }

            paragraphs.append("📌 Сохраняй в закладки, чтобы не потерять на вечер!\nОцени этот момент от 1 до 10 в комментариях 👇")
            paragraphs.append("🎬 Название фильма и где посмотреть — в шапке профиля 👆 (Telegram: @telonyx_club)")

            return paragraphs.joined(separator: "\n\n")
        }

        private func buildHashtags(context: CinemaSceneContext) -> String {
            let base = CinemaContentGenerator.baseGenresAndCastHashtags(context: context, includeTitle: false)
            let tags = CinemaContentGenerator.buildViralHashtags(
                base: base,
                trending: CinemaContentGenerator.instagramViralHashtags,
                maxCount: 15,
                textAd: context.textAd
            )
            return tags.joined(separator: " ")
        }
    }

    /// YouTube Shorts copywriter: Clickable relevant hook with #Shorts, character motivation question, channel source.
    struct YouTubeCinemaCopywriter: CinemaPlatformCopywriter {
        var platform: SocialPlatform { .youtube }

        func generate(context: CinemaSceneContext) -> GeneratedContent {
            let hook = buildHook(context: context)
            let description = buildDescription(context: context)
            let hashtags = buildHashtags(context: context)
            return GeneratedContent(hook: hook, description: description, hashtags: hashtags)
        }

        private func buildHook(context: CinemaSceneContext) -> String {
            let baseHook: String
            if let hook = context.candidateHook?.trimmed, !hook.isEmpty {
                baseHook = hook
            } else {
                baseHook = CinemaContentGenerator.dynamicGenreHook(genres: context.genres, defaultEmoji: "😳")
            }
            if baseHook.localizedCaseInsensitiveContains("#shorts") {
                return baseHook
            }
            return "\(baseHook) #Shorts"
        }

        private func buildDescription(context: CinemaSceneContext) -> String {
            if context.textAd {
                let dynamicHook = buildHook(context: context)
                return "\(dynamicHook)\n\n🎬 Название фильма в Telegram: https://t.me/telonyx_club\n\n\(CinemaContentGenerator.botAdMessage())\n\n#Shorts #кино #фильмы"
            }

            var paragraphs: [String] = []
            let effectiveSummary = CinemaContentGenerator.resolvedSceneSummary(context: context)
            if !effectiveSummary.isEmpty {
                paragraphs.append(effectiveSummary)
            }

            paragraphs.append("Что двигало героем в этот момент — холодный расчет или отчаяние? Напишите свои мысли в комментариях 👇")
            paragraphs.append("🎬 Название фильма и где посмотреть выложили в наш Telegram: https://t.me/telonyx_club (ссылка в описании канала и в закрепленном комментарии) 👇")
            paragraphs.append("🔔 Подписывайся на канал, чтобы не пропустить лучшие моменты из кино!\n\n#Shorts #кино #фильмы")

            return paragraphs.joined(separator: "\n\n")
        }

        private func buildHashtags(context: CinemaSceneContext) -> String {
            let base = CinemaContentGenerator.baseGenresAndCastHashtags(context: context, includeTitle: false)
            let tags = CinemaContentGenerator.buildViralHashtags(
                base: base,
                trending: CinemaContentGenerator.youtubeShortsViralHashtags,
                maxCount: 10,
                textAd: context.textAd
            )
            return tags.joined(separator: " ")
        }
    }

    /// Telegram copywriter: Rich card with movie title, year, IMDb rating, genres, scene quote, synopsis, subscriber prompt.
    struct TelegramCinemaCopywriter: CinemaPlatformCopywriter {
        var platform: SocialPlatform { .telegram }

        func generate(context: CinemaSceneContext) -> GeneratedContent {
            let yearPart = (context.year?.trimmed.isEmpty == false) ? " (\(context.year!.trimmed))" : ""
            let hook = "🎬 \(context.movieTitle)\(yearPart)"
            let description = buildCardDescription(context: context, yearPart: yearPart)
            let hashtags = buildHashtags(context: context)
            return GeneratedContent(hook: hook, description: description, hashtags: hashtags)
        }

        private func buildCardDescription(context: CinemaSceneContext, yearPart: String) -> String {
            var lines: [String] = []
            lines.append("🎬 «\(context.movieTitle)»\(yearPart)")
            lines.append("")

            var metaItems: [String] = []
            if let imdb = context.imdbRating, imdb > 0 {
                metaItems.append(String(format: "⭐️ IMDb: %.1f", imdb))
            }
            if !context.genres.isEmpty {
                metaItems.append("🎭 " + context.genres.prefix(3).joined(separator: ", "))
            }
            if !metaItems.isEmpty {
                lines.append(metaItems.joined(separator: " | "))
                lines.append("")
            }

            var credits: [String] = []
            if let director = context.director?.trimmed, !director.isEmpty {
                credits.append("🎥 Режиссер: \(director)")
            }
            if !context.cast.isEmpty {
                credits.append("👥 В ролях: " + context.cast.prefix(3).joined(separator: ", "))
            }
            if !credits.isEmpty {
                lines.append(contentsOf: credits)
                lines.append("")
            }

            if let quote = CinemaContentGenerator.extractQuote(from: context.transcriptSlice, fallback: context.candidateHook) {
                lines.append("💬 «\(quote)»")
                lines.append("")
            }

            if let sceneSummary = context.candidateSummary?.trimmed, !sceneSummary.isEmpty {
                lines.append("📝 О сцене:")
                let sceneText = sceneSummary.count > 300
                    ? String(sceneSummary.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines)) + "..."
                    : sceneSummary
                lines.append(sceneText)
                lines.append("")
            }

            if !context.overview.trimmed.isEmpty {
                lines.append("📖 О фильме:")
                let overviewText = context.overview.count > 450
                    ? String(context.overview.prefix(450).trimmingCharacters(in: .whitespacesAndNewlines)) + "..."
                    : context.overview
                lines.append(overviewText)
                lines.append("")
            }

            let lower = context.genres.map { $0.lowercased() }
            let question: String
            if lower.contains(where: { $0.contains("триллер") || $0.contains("детектив") }) {
                question = "❓ Как вам развязка этого фильма? Догадались сразу или были в шоке? Пишите в комментариях!"
            } else if lower.contains(where: { $0.contains("криминал") || $0.contains("боевик") }) {
                question = "❓ Оправдан ли поступок главного героя в этой ситуации? Делитесь мнением!"
            } else if lower.contains(where: { $0.contains("комеди") }) {
                question = "❓ Сколько раз пересматривали эту комедию? Какой момент самый смешной?"
            } else {
                question = "❓ Смотрели этот фильм? Как оцениваете? Оставьте оценку от 1 до 10 в комментариях!"
            }
            lines.append(question)
            lines.append("")

            lines.append("🍿 Приятного просмотра!")
            lines.append("Канал: @telonyx_club")
            return lines.joined(separator: "\n")
        }

        private func buildHashtags(context: CinemaSceneContext) -> String {
            let base = CinemaContentGenerator.baseGenresAndCastHashtags(context: context, includeTitle: true)
            return base.joined(separator: " ")
        }
    }

    // MARK: - Content Dispatcher (OCP / DIP)

    static func cinemaPlatformContent(
        context: CinemaSceneContext
    ) -> [SocialPlatform: GeneratedContent] {
        let copywriters: [CinemaPlatformCopywriter] = [
            TikTokCinemaCopywriter(),
            InstagramCinemaCopywriter(),
            YouTubeCinemaCopywriter(),
            TelegramCinemaCopywriter()
        ]
        var result: [SocialPlatform: GeneratedContent] = [:]
        for copywriter in copywriters {
            result[copywriter.platform] = copywriter.generate(context: context)
        }
        return result
    }

    static func cinemaPlatformContent(
        movie: TMDBMovie,
        descriptionMode: DescriptionMode,
        textAd: Bool,
        sceneDescription: String?,
        candidateHook: String? = nil,
        candidateSummary: String? = nil,
        transcriptSlice: String? = nil
    ) -> [SocialPlatform: GeneratedContent] {
        let context = CinemaSceneContext(
            movieTitle: movie.title,
            year: movie.year.isEmpty ? nil : movie.year,
            genres: movie.genres,
            overview: movie.overview,
            imdbRating: movie.imdbRating,
            cast: movie.cast,
            director: movie.director,
            candidateHook: candidateHook,
            candidateSummary: candidateSummary ?? sceneDescription,
            transcriptSlice: transcriptSlice,
            descriptionMode: descriptionMode,
            textAd: textAd,
            sourceText: ""
        )
        return cinemaPlatformContent(context: context)
    }

    static func cinemaPlatformContent(
        query: MovieSearchQuery,
        sourceText: String,
        descriptionMode: DescriptionMode,
        textAd: Bool,
        sceneDescription: String?,
        candidateHook: String? = nil,
        candidateSummary: String? = nil,
        transcriptSlice: String? = nil
    ) -> [SocialPlatform: GeneratedContent] {
        let context = CinemaSceneContext(
            movieTitle: query.title,
            year: query.year,
            genres: [],
            overview: "",
            imdbRating: nil,
            cast: [],
            director: nil,
            candidateHook: candidateHook,
            candidateSummary: candidateSummary ?? sceneDescription,
            transcriptSlice: transcriptSlice,
            descriptionMode: descriptionMode,
            textAd: textAd,
            sourceText: sourceText
        )
        return cinemaPlatformContent(context: context)
    }

    static func resolvedSceneSummary(context: CinemaSceneContext) -> String {
        let sceneWhy = context.candidateSummary?.trimmed ?? ""
        let overview = context.overview.trimmed
        switch context.descriptionMode {
        case .scene:
            return !sceneWhy.isEmpty ? sceneWhy : overview
        case .movie:
            return !overview.isEmpty ? overview : sceneWhy
        }
    }

    static func dynamicGenreHook(genres: [String], defaultEmoji: String = "😳") -> String {
        let lower = genres.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("криминал") || $0.contains("боевик") || $0.contains("детектив") }) {
            return "Он совершил роковую ошибку... 🤫"
        } else if lower.contains(where: { $0.contains("триллер") || $0.contains("ужас") }) {
            return "В этот момент напряжение зашкаливает... 😱"
        } else if lower.contains(where: { $0.contains("драма") || $0.contains("мелодрама") }) {
            return "Слова, после которых всё изменилось... 💔"
        } else if lower.contains(where: { $0.contains("фантастика") || $0.contains("приключени") }) {
            return "В этот момент реальность перевернулась... 🤯"
        } else if lower.contains(where: { $0.contains("комеди") }) {
            return "Эту сцену пересматривают сотни раз 😂"
        } else {
            return "Момент, который врезается в память навсегда... \(defaultEmoji)"
        }
    }

    static func extractQuote(from transcript: String?, fallback: String?) -> String? {
        if let fallback = fallback?.trimmed, !fallback.isEmpty {
            let quoteCandidates = regexRanges(pattern: #"["«]([^"»]+)["»]"#, in: fallback)
                .map { String(fallback[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "\"«» ")) }
            if let first = quoteCandidates.first, first.count >= 6 {
                return first
            }
            if fallback.contains(":") || fallback.contains("—") {
                let parts = fallback.components(separatedBy: CharacterSet(charactersIn: ":—"))
                if let last = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines), last.count >= 6 && last.count < 100 {
                    return last
                }
            }
        }
        guard let transcript = transcript?.trimmed, !transcript.isEmpty else { return nil }
        let lines = transcript.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 10 && !$0.hasPrefix("[") }
        if let firstLine = lines.first {
            let cleaned = firstLine.replacingOccurrences(of: #"^\d+:\d+\s*"#, with: "", options: .regularExpression).trimmed
            return cleaned.count > 100 ? String(cleaned.prefix(97)) + "..." : cleaned
        }
        return nil
    }

    static func baseGenresAndCastHashtags(context: CinemaSceneContext, includeTitle: Bool) -> [String] {
        var tags: [String] = []
        if includeTitle && !context.movieTitle.trimmed.isEmpty {
            tags.append(hashtag(context.movieTitle))
        }
        tags.append(contentsOf: context.genres.prefix(3).map(hashtag))
        tags.append(contentsOf: context.cast.prefix(2).map(hashtag))
        if let director = context.director?.trimmed, !director.isEmpty {
            tags.append(hashtag(director))
        }
        if tags.isEmpty && !context.sourceText.trimmed.isEmpty {
            tags.append(contentsOf: hashtags(from: context.sourceText)
                .filter { !genericCinemaHashtags.contains($0.lowercased()) }
                .prefix(3))
        }

        var seen = Set<String>()
        return tags
            .map(\.trimmed)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
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
        "Ищешь, что посмотреть вечером? 🍿 Эксклюзивные подборки шедевров кино, скрытые бриллианты и премьеры — каждый день в нашем закрытом клубе: https://t.me/telonyx_club 🎬",
        "Название фильма, обзор и лучшие моменты без цензуры уже в нашем Telegram: https://t.me/telonyx_club 🍿 Переходи и подписывайся!",
        "Хочешь больше мощных сцен и топовых фильмов на вечер? Присоединяйся к киноманам в Telegram: https://t.me/telonyx_club 🍿",
        "Вся информация об этом фильме и тысячи других рекомендаций — в нашем Telegram-канале https://t.me/telonyx_club 🎬 Жми и смотри!",
        "Кино без спойлеров и скучных списков. Только лучшее кино со всего мира: https://t.me/telonyx_club 🍿"
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
            "#кинонавечер", "#моментсфильма", "#фильмы", "#кино", "#фильм",
            "#отрывокизфильма", "#лучшиефильмы", "#чтопосмотреть",
            "#рек", "#рекомендации", "#fyp", "#fypシ"
        ]
    }

    private static var instagramViralHashtags: [String] {
        [
            "#reels", "#reelsinstagram", "#кино", "#фильм", "#фильмнавечер",
            "#отрывокизфильма", "#моментизфильма", "#киноман",
            "#лучшиефильмы", "#топфильмы", "#кинопоиск", "#вкино"
        ]
    }

    private static var youtubeShortsViralHashtags: [String] {
        [
            "#Shorts", "#кино", "#фильмы", "#фильмнавечер",
            "#моментыизфильмов", "#лучшиефильмы", "#топкино",
            "#шортс", "#shortsyoutube", "#кинопоиск"
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
            "#кино", "#фильм", "#фильмы", "#сериал", "#сериалы", "#short", "#shorts",
            "#момент", "#моменткино", "#моментфильма", "#моментизфильма", "#нарезка",
            "#кинообзор", "#рекомендации", "#чтопосмотреть"
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

private extension String {
    var hasTerminalEmoji: Bool {
        guard let lastChar = self.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        for scalar in lastChar.unicodeScalars {
            if scalar.properties.isEmoji && (scalar.value > 0x2380 || scalar.properties.isEmojiPresentation) {
                return true
            }
        }
        return false
    }
}
