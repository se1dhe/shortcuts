import Foundation
import SwiftUI

/// Publication destinations for an essay release.
enum SocialPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiktok
    case youtube
    case telegram

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .tiktok:    "TikTok"
        case .youtube:   "YouTube Shorts"
        case .telegram:  "Telegram"
        }
    }

    /// SF Symbol used on the result card header.
    var symbolName: String {
        switch self {
        case .tiktok:    "music.note"
        case .youtube:   "play.rectangle.fill"
        case .telegram:  "paperplane.fill"
        }
    }

    /// Brand-ish accent as an sRGB hex string; the view turns it into a Color.
    var tintHex: String {
        switch self {
        case .tiktok:    "FF2D55"
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

    /// Comment linking viewers to the full essay and discussion.
    var pinnedComment: String

    var id: SocialPlatform { platform }

    /// Hashtags rendered as a single `#a #b #c` line.
    var hashtagLine: String {
        hashtags
            .map { $0.hasPrefix("#") ? $0 : "#\($0)" }
            .joined(separator: " ")
    }
}
