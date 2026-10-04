import Foundation

/// Metadata describing an audio stream extracted from a video container (MP4, MKV, WebM, AVI).
/// Adheres to Single Responsibility Principle (SRP) by encapsulating audio track attributes and display formatting.
struct AudioTrackInfo: Identifiable, Sendable, Equatable, Hashable {
    /// Stream index in the container (e.g. 1 in stream #0:1) used for ffmpeg `-map 0:<id>`.
    let id: Int
    /// 0-based index among audio-only tracks (0 = first audio track).
    let audioIndex: Int
    /// Human-readable title from metadata tags (e.g. "Дубляж", "Line", "Original").
    let title: String?
    /// ISO language code (e.g. "rus", "ru", "eng", "en").
    let language: String?
    /// Audio codec name (e.g. "aac", "ac3", "eac3", "dts", "flac").
    let codec: String
    /// Channel count (e.g. 2 for stereo, 6 for 5.1 surround).
    let channels: Int
    /// Whether this track is marked as default in container disposition.
    let isDefault: Bool
    /// Whether this track is marked as forced.
    let isForced: Bool

    /// Formatted display name for UI selector.
    var displayName: String {
        var components: [String] = []

        // Language flag / name
        let langName = localizedLanguageName
        if !langName.isEmpty {
            components.append(langName)
        }

        // Title if available
        if let title = title, !title.isEmpty {
            components.append("(\(title))")
        } else if langName.isEmpty {
            components.append("Дорожка #\(audioIndex + 1)")
        }

        // Format details: channels + codec
        var details: [String] = []
        if !codec.isEmpty {
            details.append(codec.uppercased())
        }
        if channels > 0 {
            if channels == 1 {
                details.append("Mono")
            } else if channels == 2 {
                details.append("2.0 Stereo")
            } else if channels == 6 {
                details.append("5.1 Surround")
            } else if channels == 8 {
                details.append("7.1 Surround")
            } else {
                details.append("\(channels) ch")
            }
        }
        if isDefault {
            details.append("По умолчанию")
        }

        if !details.isEmpty {
            return "\(components.joined(separator: " ")) · \(details.joined(separator: ", "))"
        }
        return components.joined(separator: " ")
    }

    /// Readable language name with emoji flag.
    var localizedLanguageName: String {
        guard let lang = language?.lowercased().trimmed, !lang.isEmpty else { return "" }
        switch lang {
        case "rus", "ru", "russian":
            return "🇷🇺 Русский"
        case "eng", "en", "english":
            return "🇬🇧 Английский"
        case "fra", "fr", "fre", "french":
            return "🇫🇷 Французский"
        case "deu", "de", "ger", "german":
            return "🇩🇪 Немецкий"
        case "ita", "it", "italian":
            return "🇮🇹 Итальянский"
        case "spa", "es", "spanish":
            return "🇪🇸 Испанский"
        case "jpn", "ja", "japanese":
            return "🇯🇵 Японский"
        case "kor", "ko", "korean":
            return "🇰🇷 Корейский"
        case "zho", "zh", "chi", "chinese":
            return "🇨🇳 Китайский"
        case "ukr", "uk", "ukrainian":
            return "🇺🇦 Украинский"
        case "kaz", "kk", "kazakh":
            return "🇰🇿 Казахский"
        default:
            return lang.uppercased()
        }
    }

    /// Whether this track is likely a Russian dub or Russian voiceover.
    var isRussianVoiceover: Bool {
        let lang = language?.lowercased() ?? ""
        let t = title?.lowercased() ?? ""
        if lang == "rus" || lang == "ru" { return true }
        if t.contains("дубляж") || t.contains("dub") || t.contains("проф") || t.contains("рус") { return true }
        return false
    }
}
