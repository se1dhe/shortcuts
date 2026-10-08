import Foundation

/// The per-short outcome of a campaign run: which platform URLs came back and
/// any error that stopped this particular clip.
struct ShortCampaignResult: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    var urls: [SocialPlatform: String] = [:]
    var error: String?
}

/// Aggregate result of publishing one campaign: the essay's YouTube link, every
/// short's platform links, and the final Telegram campaign post link.
struct CampaignResult: Sendable, Equatable {
    var essayYouTubeURL: String?
    var shorts: [ShortCampaignResult] = []
    var telegramPostURL: String?

    /// Every resolved platform link across all shorts, in a stable order, used
    /// to build the Telegram campaign post body.
    var collectedShortLinks: [(platform: SocialPlatform, url: String)] {
        var seen = Set<String>()
        var links: [(SocialPlatform, String)] = []
        for short in shorts {
            for platform in SocialPlatform.allCases where platform != .telegram {
                guard let url = short.urls[platform], !url.isEmpty, !seen.contains(url) else { continue }
                seen.insert(url)
                links.append((platform, url))
            }
        }
        return links
    }
}
