import Foundation
import SwiftUI

/// The three social networks Shortcast publishes to.
enum SocialPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiktok
    case instagram
    case youtube
    case telegram

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .tiktok:    "TikTok"
        case .instagram: "Instagram Reels"
        case .youtube:   "YouTube Shorts"
        case .telegram:  "Telegram"
        }
    }

    /// Value expected by the Upload-Post `platform[]` form field.
    var uploadPostID: String { rawValue }

    /// SF Symbol used on the result card header.
    var symbolName: String {
        switch self {
        case .tiktok:    "music.note"
        case .instagram: "camera"
        case .youtube:   "play.rectangle.fill"
        case .telegram:  "paperplane.fill"
        }
    }

    /// Brand-ish accent as an sRGB hex string; the view turns it into a Color.
    var tintHex: String {
        switch self {
        case .tiktok:    "FF2D55"
        case .instagram: "C13584"
        case .youtube:   "FF0000"
        case .telegram:  "2AABEE"
        }
    }
}

/// One platform's proposed post. Edited in place by the user before publishing.
struct PostVariant: Identifiable, Codable, Sendable, Equatable {
    var platform: SocialPlatform
    /// Short title / scroll-stopping hook.
    var hook: String
    /// Body copy / caption.
    var summary: String
    /// Hashtags WITHOUT the leading `#` (normalized on parse).
    var hashtags: [String]

    /// Pinned comment for this platform (1win promo, generated from a template
    /// with the user's promo code). Editable before publishing.
    var pinnedComment: String

    var id: SocialPlatform { platform }

    /// Hashtags rendered as a single `#a #b #c` line.
    var hashtagLine: String {
        hashtags
            .map { $0.hasPrefix("#") ? $0 : "#\($0)" }
            .joined(separator: " ")
    }

    /// Combined description and hashtags: `summary` + `\n\n` + `hashtagLine` (if tags are present).
    var fullDescriptionWithTags: String {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTags = hashtagLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSummary.isEmpty {
            return trimmedTags
        }
        if trimmedTags.isEmpty {
            return trimmedSummary
        }
        return "\(trimmedSummary)\n\n\(trimmedTags)"
    }

    /// Updates `summary` and `hashtags` from a single combined text block.
    /// The trailing run of `#`-prefixed tags is parsed into `hashtags`, while the preceding text becomes `summary`.
    mutating func updateFromCombinedDescription(_ text: String) {
        let (parsedSummary, parsedTags) = Self.parseCombinedDescription(text)
        self.summary = parsedSummary
        self.hashtags = parsedTags
    }

    /// Splits combined text into (summary, hashtags). The trailing block of `#`-prefixed tokens
    /// becomes the hashtag list; everything before it is the summary/description.
    static func parseCombinedDescription(_ text: String) -> (summary: String, hashtags: [String]) {
        let pattern = "(\\s*#[^\\s#]\\S*)+\\s*$"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let parsedSummary = String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = text[range.lowerBound...]
            .split(whereSeparator: { " \n\t,".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }
        return (parsedSummary, tags)
    }
}

/// Full result of one on-device generation pass.
struct GenerationResult: Sendable, Equatable {
    var variants: [PostVariant]
    /// Language the model wrote in (BCP-47-ish, e.g. "es", "en"). Informational.
    var detectedLanguage: String?

    func variant(for platform: SocialPlatform) -> PostVariant? {
        variants.first { $0.platform == platform }
    }
}
