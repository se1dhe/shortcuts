import Foundation
import CryptoKit

/// One essay, two complementary shorts and their publication receipts.
/// Kept in the project; restarting the app must not enqueue duplicate uploads.
struct EssayRelease: Codable, Sendable, Equatable {
    var essayKey: String
    var shorts: [EssayShort] = []
    var essayYouTubeURL: String?
    var receipts: [String: Receipt] = [:]
    var relatedVideoConfirmed: Set<String> = []
    /// Optional for archives saved before per-release destinations existed.
    var includeTikTok: Bool? = nil
    var wantsTikTok: Bool { includeTikTok ?? true }

    /// A saved plan alone is not a prepared release: both exports must still exist.
    var hasReadyShorts: Bool {
        shorts.count == 2 && shorts.allSatisfy {
            $0.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
    }

    /// Optional discussion posts are excluded; the main release and its comments must be confirmed.
    var isPublished: Bool {
        guard shorts.count == 2 else { return false }
        let keys = ["essay.youtube", "essay.youtube.comment", "telegram.announcement"]
            + shorts.flatMap { short in
                [short.id + ".youtube", short.id + ".youtube.comment"]
                    + (wantsTikTok ? [short.id + ".tiktok"] : [])
            }
        return keys.allSatisfy { receipts[$0]?.state == .published }
    }

    struct Receipt: Codable, Sendable, Equatable {
        enum State: String, Codable, Sendable { case sending, published, needsReview, failed }
        var state: State
        var url: String?
        var message: String
    }

    static func key(for arc: LongformNarrativeArc) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(arc)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    static func youtubeURL(_ value: String) -> String? {
        guard let url = URL(string: value.trimmed), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let id: String?
        if host == "youtu.be" { id = url.pathComponents.dropFirst().first }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) {
            if url.path == "/watch" { id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value }
            else if url.pathComponents.count == 3, ["shorts", "live"].contains(url.pathComponents[1]) { id = url.pathComponents[2] }
            else { id = nil }
        } else { id = nil }
        guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return "https://www.youtube.com/watch?v=" + id
    }

    static func publicationURL(_ value: String, platform: String) -> String? {
        if platform == "youtube" { return youtubeURL(value) }
        guard let url = URL(string: value.trimmed), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        if platform == "tiktok", ["tiktok.com", "www.tiktok.com"].contains(host),
           url.path.range(of: #"^/@[^/]+/video/[0-9]+/?$"#, options: .regularExpression) != nil { return url.absoluteString }
        if platform == "telegram", host == "t.me", url.pathComponents.count >= 3,
           url.lastPathComponent.allSatisfy(\.isNumber) { return url.absoluteString }
        return nil
    }

    static func youtubeCommentURL(_ value: String) -> String? {
        guard let base = youtubeURL(value), let parts = URLComponents(string: value),
              let comment = parts.queryItems?.first(where: { $0.name == "lc" })?.value,
              (5...256).contains(comment.count),
              comment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return base + "&lc=" + comment
    }

    /// Unknown outcome requires a human check, never an automatic second upload.
    mutating func recoverInterruptedPublishing() {
        for key in Array(receipts.keys) where receipts[key]?.state == .sending {
            receipts[key]?.state = .needsReview
            receipts[key]?.message = "Публикация была прервана. Проверьте площадку перед повторной отправкой."
        }
    }
}

struct EssayShort: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var angle: String
    var hook: String
    var title: String
    var why: String
    var payoffQuote: String
    var question: String
    var segments: [TimeSegment]
    var outputURL: URL?
    var coverURL: URL?
    var candidateID: String? = nil
    var selectionModelID: String? = nil
    var captionEdits: [LongformCaptionEdit]? = nil
    /// Source ranges deliberately added from the film transcript rather than copied from the essay.
    var manuallyAddedSegments: [TimeSegment]? = nil
    var duration: Double { segments.reduce(0) { $0 + $1.duration } + 3 }

    func post(platform: SocialPlatform, movieTitle: String, release: EssayRelease, telegramURL: String?) -> PostVariant {
        let film = String(movieTitle.prefix(70))
        let title = String(self.title.prefix(max(8, 90 - film.count - 3))) + " | " + film
            + (platform == .youtube ? " #Shorts" : "")
        let destination: String
        if platform == .youtube {
            destination = "Повне есе — «\(movieTitle)» на каналі «Кадр & Сенс»."
                + (release.essayYouTubeURL.map { "\n" + $0 } ?? "")
        } else {
            destination = "Повне есе про «\(movieTitle)» — на YouTube «Кадр & Сенс»."
                + (release.essayYouTubeURL.map { "\n" + $0 } ?? "")
        }
        let discussion = telegramURL.map { "\nОбговорення: " + $0 } ?? ""
        return PostVariant(platform: platform, hook: title,
            summary: "«\(movieTitle)» — \(angle)\n\n\(question)\n\n\(destination)\(discussion)",
            hashtags: [movieTitle, "Кіноесе", "УкраїнськийДубляж", platform == .youtube ? "Shorts" : "КіноТікТок"]
                .compactMap { LongformMetadataGenerator.hashtag($0).map { String($0.dropFirst()) } },
            pinnedComment: destination + discussion)
    }
}
