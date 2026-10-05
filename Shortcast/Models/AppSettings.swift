import Foundation
import Observation
import SwiftUI

enum MovieShortsSearchDefaults {
    static let queryText = [
        "нарезка из фильма дубляж",
        "сцена из фильма русская озвучка",
        "зарубежный фильм на русском нарезка",
        "момент из сериала дубляж",
        "нарезка сериал русская озвучка",
        "movie clip русская озвучка",
    ].joined(separator: "\n")

    static var queries: [String] {
        queryText
            .components(separatedBy: .newlines)
            .map(\.trimmed)
            .filter { !$0.isEmpty }
    }
}

/// User configuration: Upload-Post credentials and content-style preferences.
///
/// Everything (including the API key) lives in `UserDefaults`. The key used to
/// sit in the Keychain, but every dev rebuild changes the app's code signature,
/// so macOS re-prompted on each launch — for a 100% local/offline tool the
/// plist is a fine home. Held as an `@Observable` so views update on change.
@MainActor
@Observable
final class AppSettings {

    /// Which model finds the moments and writes each clip's captions. Two of the
    /// options (Gemma 4 12B, Qwen 3.5 9B) are text models that double as the
    /// "Director" and write captions inline in the same pass; the third (Gemma 4
    /// E4B) is a multimodal copywriter that watches each clip separately.
    enum CopywriterModel: String, CaseIterable, Identifiable, Sendable {
        case qwen35_9b = "qwen"
        case gemma12B = "gemma12b"
        case gemmaE4B = "gemma"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .qwen35_9b: "Qwen 3.5 9B (Рекомендуется · 4x быстрее)"
            case .gemma12B:  "Gemma 4 12B"
            case .gemmaE4B:  "Gemma 4 E4B · 4-bit"
            }
        }

        var tagline: LocalizedStringKey {
            switch self {
            case .qwen35_9b: "Finds the moments AND writes all three captions in one pass — ultra-fast Metal SDPA acceleration, top Russian storytelling, one model."
            case .gemma12B:  "Finds the moments AND writes all three captions in one pass — cinematic style, one model, keeps the spoken language."
            case .gemmaE4B:  "Watches each clip (frames + audio) and captions it in a separate pass per clip."
            }
        }

        /// The text model that finds the moments. The two inline options are
        /// their own Director; the clip-watching option still needs a Director,
        /// for which we use the fast default (Qwen 3.5 9B).
        var directorProfile: ChatModelProfile {
            switch self {
            case .qwen35_9b, .gemmaE4B: .qwen35_9b
            case .gemma12B:             .gemma12B
            }
        }

        /// True when the Director writes the captions in the same pass (so no
        /// separate per-clip captioning step runs).
        var usesInlineCaptions: Bool {
            switch self {
            case .gemma12B, .qwen35_9b: true
            case .gemmaE4B:             false
            }
        }

        /// True for the multimodal Gemma E4B path that watches each clip — the
        /// only option that loads a second model alongside the Director.
        var watchesClips: Bool { self == .gemmaE4B }
    }

    /// Upload-Post API key. Mirrored to `UserDefaults` on every change.
    var apiKey: String {
        didSet { persistAPIKey() }
    }

    /// TMDB API key for movie metadata lookup in Cinema preset (stored in UserDefaults).
    var tmdbAPIKey: String {
        didSet {
            defaults.set(tmdbAPIKey.trimmed, forKey: Keys.tmdbApiKey)
        }
    }

    /// YouTube Data API v3 key for searching Shorts and uploading essays (stored in UserDefaults).
    var youtubeAPIKey: String {
        didSet {
            defaults.set(youtubeAPIKey.trimmed, forKey: Keys.youtubeApiKey)
        }
    }

    /// Path to a Netscape-format cookies.txt file exported from a browser
    /// (e.g. via `yt-dlp --cookies-from-browser safari --cookies ~/Desktop/cookies.txt
    /// --skip-download https://youtube.com`). Needed for age-restricted videos.
    var youtubeCookiesPath: String {
        didSet { defaults.set(youtubeCookiesPath, forKey: Keys.youtubeCookies) }
    }

    /// Telegram Bot Token for posting to Telegram channel (stored in UserDefaults).
    var telegramBotToken: String {
        didSet {
            defaults.set(telegramBotToken.trimmed, forKey: Keys.telegramBotToken)
        }
    }

    /// Telegram Channel ID/username (e.g. "@telonyx_club").
    var telegramChannelId: String {
        didSet { defaults.set(telegramChannelId, forKey: Keys.telegramChannelId) }
    }

    /// Whether to automatically post movie cards to Telegram on publish.
    var autoPostToTelegram: Bool {
        didSet { defaults.set(autoPostToTelegram, forKey: Keys.autoPostToTelegram) }
    }

    /// Upload-Post profile name (from "Manage Users" — NOT a social handle).
    var profileName: String {
        didSet { defaults.set(profileName, forKey: Keys.profile) }
    }

    /// Optional caption language override (e.g. "English", "es"). Empty = match
    /// the language spoken in the video.
    var languageOverride: String {
        didSet { defaults.set(languageOverride, forKey: Keys.language) }
    }

    /// Optional examples of the user's own captions, fed to the model as style.
    var styleExamples: String {
        didSet { defaults.set(styleExamples, forKey: Keys.style) }
    }

    /// When true, TikTok uploads land in the inbox as a draft instead of
    /// publishing directly (`post_mode=MEDIA_UPLOAD`). On by default.
    var tiktokAsDraft: Bool {
        didSet { defaults.set(tiktokAsDraft, forKey: Keys.tiktokDraft) }
    }

    /// The Copywriter model used to caption generated shorts.
    var copywriterModel: CopywriterModel {
        didSet { defaults.set(copywriterModel.rawValue, forKey: Keys.copywriter) }
    }

    /// Default for burning an AI text hook into the top of each generated short.
    /// Per-clip toggles can override this.
    var burnHookOverlay: Bool {
        didSet { defaults.set(burnHookOverlay, forKey: Keys.burnHook) }
    }

    /// Default for reframing a horizontal (16:9) clip to vertical 9:16, tracking
    /// the speaker with Vision. Only applies to clips that are actually
    /// landscape; per-clip toggles can override this.
    var reframeToVertical: Bool {
        didSet { defaults.set(reframeToVertical, forKey: Keys.reframe) }
    }

    /// When false the transcription step is skipped entirely. Subtitles will be
    /// unavailable, but the editor opens immediately after the download.
    /// Default: true.
    var transcriptionEnabled: Bool {
        didSet { defaults.set(transcriptionEnabled, forKey: Keys.transcriptionEnabled) }
    }

    /// Default for burning transcript subtitles into every generated short.
    var burnSubtitles: Bool {
        didSet { defaults.set(burnSubtitles, forKey: Keys.burnSubtitles) }
    }

    /// Default for applying Anti-Copyright & TikTok Shield protection to generated shorts.
    var antiCopyrightEnabled: Bool {
        didSet { defaults.set(antiCopyrightEnabled, forKey: Keys.antiCopyrightEnabled) }
    }

    /// Default Anti-Copyright protection preset.
    var antiCopyrightPreset: AntiCopyrightPreset {
        didSet { defaults.set(antiCopyrightPreset.rawValue, forKey: Keys.antiCopyrightPreset) }
    }

    /// Default for showing a watermark on shorts. Per-clip toggle can override.
    var watermarkEnabled: Bool {
        didSet { defaults.set(watermarkEnabled, forKey: Keys.watermark) }
    }

    /// Default for showing a watermark on the full single-video export.
    var watermarkFullVideoEnabled: Bool {
        didSet { defaults.set(watermarkFullVideoEnabled, forKey: Keys.watermarkFullVideo) }
    }

    /// The text burned into each clip (e.g. \@"username").
    var watermarkText: String {
        didSet { defaults.set(watermarkText, forKey: Keys.watermarkText) }
    }

    /// Watermark appearance config (position, opacity, size, animation).
    var watermarkAppearance: WatermarkAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(watermarkAppearance) {
                defaults.set(data, forKey: Keys.watermarkAppearance)
            }
        }
    }

    /// Default for burning the 1win partner promo banner at the top of each short.
    var promoOverlayEnabled: Bool {
        didSet { defaults.set(promoOverlayEnabled, forKey: Keys.promoOverlay) }
    }

    /// Partner promo code shown in the animated banner (e.g. affiliate code).
    var promoCode: String {
        didSet { defaults.set(promoCode, forKey: Keys.promoCode) }
    }

    /// Seconds the promo banner stays before retracting. 0 = half the video (default).
    var promoDurationSeconds: Double {
        didSet { defaults.set(promoDurationSeconds, forKey: Keys.promoDuration) }
    }

    /// Text-ad mode: the post description becomes a catchy @RedQueenSecurity_Bot promo
    /// (only the movie name is looked up, no scene caption) and the bot hashtag is added.
    var textAdEnabled: Bool {
        didSet { defaults.set(textAdEnabled, forKey: Keys.textAd) }
    }

    /// Subtitle appearance config (colour, border, size, position, animation).
    var subtitleAppearance: SubtitleAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(subtitleAppearance) {
                defaults.set(data, forKey: Keys.subtitleAppearance)
            }
        }
    }

    /// Default style + size of the burned-in text hook.
    var hookAppearance: HookAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(hookAppearance) {
                defaults.set(data, forKey: Keys.hookAppearance)
            }
        }
    }

    /// Preferred genre focus for cinema moment finding: auto (TMDB), drama, or comedy.
    var cinemaGenreMode: CinemaGenreMode {
        didSet { defaults.set(cinemaGenreMode.rawValue, forKey: Keys.cinemaGenreMode) }
    }

    /// Выбранный формат видео: шортсы (1:1 / 9:16) или длинный метр (16:9 YouTube).
    var selectedOutputFormat: CinemaOutputFormat {
        didSet { defaults.set(selectedOutputFormat.rawValue, forKey: Keys.selectedOutputFormat) }
    }

    /// Minimum YouTube video length in minutes (default 30).
    var youtubeMinDurationMinutes: Int {
        didSet { defaults.set(youtubeMinDurationMinutes, forKey: Keys.youtubeMin) }
    }

    /// Maximum YouTube video length in minutes (default 120).
    var youtubeMaxDurationMinutes: Int {
        didSet { defaults.set(youtubeMaxDurationMinutes, forKey: Keys.youtubeMax) }
    }

    /// Newline-separated YouTube search queries used by the Movie Shorts tab.
    var movieShortsSearchQueries: String {
        didSet { defaults.set(movieShortsSearchQueries, forKey: Keys.movieShortsSearchQueries) }
    }

    /// Set of YouTube video IDs that have already been processed in the Movie Clips mode.
    var processedMovieClipIDs: Set<String> {
        get {
            let array = defaults.array(forKey: Keys.processedMovieClipIDs) as? [String] ?? []
            return Set(array)
        }
        set {
            defaults.set(Array(newValue), forKey: Keys.processedMovieClipIDs)
        }
    }

    /// History of YouTube videos that were processed, captioned, and ready.
    var processedVideoHistory: [ProcessedVideoRecord] {
        get {
            guard let data = defaults.data(forKey: Keys.processedVideoHistory) else { return [] }
            return (try? JSONDecoder().decode([ProcessedVideoRecord].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.processedVideoHistory)
            }
        }
    }



    /// User-selected folder for custom background music. Uses a security-scoped bookmark.
    var customMusicDirectory: URL? {
        didSet {
            if let url = customMusicDirectory {
                let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(data, forKey: Keys.customMusicDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.customMusicDirectoryBookmark)
            }
        }
    }
    
    /// Human-readable path of the custom music directory.
    var customMusicDirectoryLabel: String {
        customMusicDirectory?.path(percentEncoded: false) ?? String(localized: "None")
    }

    /// User-selected output folder for downloads and exports. Uses a security-scoped
    /// bookmark so the app keeps access across launches. nil → use temp directory.
    var outputDirectory: URL? {
        get {
            guard let data = defaults.data(forKey: Keys.outputDirectoryBookmark) else { return nil }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            else { return nil }
            if isStale, let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(newData, forKey: Keys.outputDirectoryBookmark)
            }
            return url
        }
        set {
            if let url = newValue {
                let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(data, forKey: Keys.outputDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.outputDirectoryBookmark)
            }
        }
    }

    /// Human-readable path of the output directory (or "Temporary folder").
    var outputDirectoryLabel: String {
        outputDirectory?.path(percentEncoded: false) ?? String(localized: "Temporary folder (system)")
    }

    /// App's working directory — where input files are copied before processing
    /// so every consumer (AVAsset, Gemma4VideoProcessor) has unrestricted access.
    /// Falls back to the system temp directory when nil.
    var workingDirectory: URL? {
        get {
            guard let data = defaults.data(forKey: Keys.workingDirectoryBookmark) else { return nil }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            else { return nil }
            if isStale, let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(newData, forKey: Keys.workingDirectoryBookmark)
            }
            return url
        }
        set {
            if let url = newValue {
                let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(data, forKey: Keys.workingDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.workingDirectoryBookmark)
            }
        }
    }

    /// Human-readable path of the working directory (or "System temporary folder").
    var workingDirectoryLabel: String {
        workingDirectory?.path(percentEncoded: false) ?? String(localized: "System temporary folder")
    }

    /// Whether the working directory has been chosen and its bookmark is still
    /// valid (not stale). Used by the first-launch flow.
    var hasWorkingDirectory: Bool {
        workingDirectory != nil
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        self.tmdbAPIKey = defaults.string(forKey: Keys.tmdbApiKey) ?? ""
        self.youtubeAPIKey = defaults.string(forKey: Keys.youtubeApiKey) ?? ""
        self.youtubeCookiesPath = defaults.string(forKey: Keys.youtubeCookies) ?? ""
        self.telegramBotToken = defaults.string(forKey: Keys.telegramBotToken) ?? ""

        self.telegramChannelId = defaults.string(forKey: Keys.telegramChannelId) ?? "@telonyx_club"
        self.autoPostToTelegram = defaults.object(forKey: Keys.autoPostToTelegram) as? Bool ?? true
        self.profileName = defaults.string(forKey: Keys.profile) ?? ""
        self.languageOverride = defaults.string(forKey: Keys.language) ?? ""
        self.styleExamples = defaults.string(forKey: Keys.style) ?? ""
        // Defaults to true on first launch (no stored value yet).
        self.tiktokAsDraft = defaults.object(forKey: Keys.tiktokDraft) as? Bool ?? true
        // Default to Qwen 3.5 9B: hardware-accelerated Metal SDPA, top-tier Russian/multilingual
        // reasoning and structured JSON generation in a single pass (4x faster than Gemma 12B).
        let modelMigrated = defaults.bool(forKey: "shortcast.defaultModelGemma12BMigrated")
        if !modelMigrated {
            self.copywriterModel = .gemma12B
            defaults.set(CopywriterModel.gemma12B.rawValue, forKey: Keys.copywriter)
            defaults.set(true, forKey: "shortcast.defaultModelGemma12BMigrated")
        } else {
            self.copywriterModel = defaults.string(forKey: Keys.copywriter)
                .flatMap(CopywriterModel.init) ?? .gemma12B
        }
        // Default on — the user opted into the hook-overlay feature.
        self.burnHookOverlay = defaults.object(forKey: Keys.burnHook) as? Bool ?? true
        // Default on — horizontal clips should become vertical shorts.
        self.reframeToVertical = defaults.object(forKey: Keys.reframe) as? Bool ?? true
        // Default on — transcription runs unless the user disables it.
        self.transcriptionEnabled = defaults.object(forKey: Keys.transcriptionEnabled) as? Bool ?? true
        // Default on — burn subtitles from the transcript.
        self.burnSubtitles = defaults.object(forKey: Keys.burnSubtitles) as? Bool ?? true
        // Default on — TikTok Shield & Anti-Copyright protection.
        self.antiCopyrightEnabled = defaults.object(forKey: Keys.antiCopyrightEnabled) as? Bool ?? true
        let rawPreset = defaults.string(forKey: Keys.antiCopyrightPreset) ?? AntiCopyrightPreset.tikTokShield.rawValue
        self.antiCopyrightPreset = AntiCopyrightPreset(rawValue: rawPreset) ?? .tikTokShield
        // Default on — the user opted into the watermark feature.
        self.watermarkEnabled = defaults.object(forKey: Keys.watermark) as? Bool ?? true
        // Default on for full video too.
        self.watermarkFullVideoEnabled = defaults.object(forKey: Keys.watermarkFullVideo) as? Bool ?? true
        // Default watermark text.
        self.watermarkText = defaults.string(forKey: Keys.watermarkText) ?? "@shortcast"
        self.watermarkAppearance = (defaults.data(forKey: Keys.watermarkAppearance)
            .flatMap { try? JSONDecoder().decode(WatermarkAppearance.self, from: $0) })
            ?? .default
        self.promoOverlayEnabled = defaults.object(forKey: Keys.promoOverlay) as? Bool ?? false
        self.promoCode = defaults.string(forKey: Keys.promoCode) ?? PromoOverlayConfig.default.promoCode
        self.promoDurationSeconds = defaults.object(forKey: Keys.promoDuration) as? Double ?? 0
        self.textAdEnabled = defaults.object(forKey: Keys.textAd) as? Bool ?? false
        self.subtitleAppearance = (defaults.data(forKey: Keys.subtitleAppearance)
            .flatMap { try? JSONDecoder().decode(SubtitleAppearance.self, from: $0) })
            ?? .cinemaPremium
        self.hookAppearance = (defaults.data(forKey: Keys.hookAppearance)
            .flatMap { try? JSONDecoder().decode(HookAppearance.self, from: $0) })
            ?? .default
        let rawGenre = defaults.string(forKey: Keys.cinemaGenreMode) ?? CinemaGenreMode.auto.rawValue
        self.cinemaGenreMode = CinemaGenreMode(rawValue: rawGenre) ?? .auto
        let rawFormat = defaults.string(forKey: Keys.selectedOutputFormat) ?? CinemaOutputFormat.shortSquare.rawValue
        self.selectedOutputFormat = CinemaOutputFormat(rawValue: rawFormat) ?? .shortSquare
        self.youtubeMinDurationMinutes = defaults.object(forKey: Keys.youtubeMin) as? Int ?? 30
        self.youtubeMaxDurationMinutes = defaults.object(forKey: Keys.youtubeMax) as? Int ?? 120
        self.movieShortsSearchQueries = defaults.string(forKey: Keys.movieShortsSearchQueries)
            ?? MovieShortsSearchDefaults.queryText
            
        // Initialize customMusicDirectory from bookmark
        if let data = defaults.data(forKey: Keys.customMusicDirectoryBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                self.customMusicDirectory = url
                if isStale, let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(newData, forKey: Keys.customMusicDirectoryBookmark)
                }
            }
        }
    }

    /// True once the app has enough to publish.
    var isConfigured: Bool {
        !apiKey.trimmed.isEmpty && !profileName.trimmed.isEmpty
    }

    private func persistAPIKey() {
        defaults.set(apiKey.trimmed, forKey: Keys.apiKey)
    }

    private enum Keys {
        static let apiKey      = "shortcast.apiKey"
        static let tmdbApiKey  = "shortcast.tmdbApiKey"
        static let youtubeApiKey = "shortcast.youtubeApiKey"
        static let youtubeCookies = "shortcast.youtubeCookiesPath"
        static let telegramBotToken = "shortcast.telegramBotToken"
        static let telegramChannelId = "shortcast.telegramChannelId"
        static let autoPostToTelegram = "shortcast.autoPostToTelegram"
        static let profile     = "shortcast.profileName"
        static let language    = "shortcast.languageOverride"
        static let style       = "shortcast.styleExamples"
        static let tiktokDraft = "shortcast.tiktokAsDraft"
        static let copywriter  = "shortcast.copywriterModel"
        static let burnHook    = "shortcast.burnHookOverlay"
        static let reframe     = "shortcast.reframeToVertical"
        static let cinemaGenreMode = "shortcast.cinemaGenreMode"
        static let selectedOutputFormat = "shortcast.selectedOutputFormat"
        static let outputDirectoryBookmark = "shortcast.outputDirectoryBookmark"
        static let transcriptionEnabled = "shortcast.transcriptionEnabled"
        static let burnSubtitles = "shortcast.burnSubtitles"
        static let antiCopyrightEnabled = "shortcast.antiCopyrightEnabled"
        static let antiCopyrightPreset  = "shortcast.antiCopyrightPreset"
        static let subtitleAppearance = "shortcast.subtitleAppearance"
        static let hookAppearance = "shortcast.hookAppearance"
        static let workingDirectoryBookmark = "shortcast.workingDirectoryBookmark"
        static let watermark = "shortcast.watermarkEnabled"
        static let watermarkFullVideo = "shortcast.watermarkFullVideoEnabled"
        static let watermarkText = "shortcast.watermarkText"
        static let watermarkAppearance = "shortcast.watermarkAppearance"
        static let promoOverlay = "shortcast.promoOverlayEnabled"
        static let promoCode = "shortcast.promoCode"
        static let promoDuration = "shortcast.promoDurationSeconds"
        static let textAd = "shortcast.textAdEnabled"
        static let youtubeMin = "shortcast.youtubeMinDuration"
        static let youtubeMax = "shortcast.youtubeMaxDuration"
        static let movieShortsSearchQueries = "shortcast.movieShortsSearchQueries"
        static let processedMovieClipIDs = "shortcast.processedMovieClipIDs"
        static let processedVideoHistory = "shortcast.processedVideoHistory"
        static let customMusicDirectoryBookmark = "shortcast.customMusicDirectoryBookmark"
        // Longform Cinema Audio & Shield Settings
        static let longformColdOpen = "shortcast.longform.coldOpenEnabled"
        static let longformDialogueFocus = "shortcast.longform.dialogueFocusEnabled"
        static let longformMusicDucking = "shortcast.longform.originalMusicDucking"
        static let longformAmbientMusic = "shortcast.longform.ambientMusicEnabled"
        static let longformDucking = "shortcast.longform.duckingEnabled"
        static let longformPresetIndex = "shortcast.longform.selectedPresetIndex"
        static let longformCustomAudioPath = "shortcast.longform.customAudioPath"
        static let longformAmbientVolume = "shortcast.longform.ambientVolume"
        static let longformAntiCopyright = "shortcast.longform.antiCopyrightEnabled"
        static let longformAntiCopyrightPreset = "shortcast.longform.antiCopyrightPreset"
        /// Old Keychain account, read once to migrate into UserDefaults.
        static let legacyApiKey = "upload-post-api-key"
    }
}
