import Foundation

/// RichMessage HTML, including an explicit local cover attachment. Source text
/// is escaped before formatting; URLs are real publication receipts only.
struct EssayRichPost: Sendable {
    let title: String
    let body: String
    let quote: String
    let question: String
    let hashtags: String
    let youtubeURL: String
    let coverURL: URL?

    static func make(result: LongformBuildResult, release: EssayRelease, discussion: Bool) throws -> EssayRichPost {
        guard let url = release.essayYouTubeURL.flatMap(EssayRelease.youtubeURL) else {
            throw EssayReleaseError.invalid("Сначала опубликуйте эссе или сохраните его точную ссылку YouTube.")
        }
        let question = release.shorts.last?.question ?? result.arc.hookText ?? "Яка думка фільму залишилася з вами?"
        let body = discussion
            ? (release.shorts.last?.angle ?? result.arc.thesis ?? result.arc.concept.philosophicalPremise)
            : (result.arc.thesis ?? result.arc.concept.philosophicalPremise)
        let subject = discussion ? (release.shorts.last?.angle ?? "продовжуємо розмову")
            : (result.arc.publicationTitle ?? result.arc.concept.suggestedTitle)
        return EssayRichPost(title: "«\(result.arc.movieTitle)» — " + subject,
            body: String(body.prefix(900)), quote: String((result.arc.hookText ?? result.arc.concept.tagline).prefix(240)),
            question: String(question.prefix(240)), hashtags: result.metadata.hashtagText,
            youtubeURL: url, coverURL: result.thumbnailURL)
    }

    var html: String {
        (coverURL == nil ? "" : "<img src=\"tg://photo?id=cover\"/>")
        + "<h2>\(Self.escape(title))</h2>"
        + "<blockquote>\(Self.escape(quote))</blockquote>"
        + "<p>\(Self.escape(body))</p><hr/>"
        + "<p><b>Обговорімо</b><br/>\(Self.escape(question))</p>"
        + "<tg-button-row><tg-button type=\"url\" style=\"primary\" url=\"\(Self.escape(youtubeURL))\">Дивитися повне есе ↗</tg-button></tg-button-row>"
        + "<footer>Кадр &amp; Сенс · \(Self.escape(hashtags))</footer>"
    }

    var richMessage: [String: Any] {
        var message: [String: Any] = ["html": html]
        if coverURL != nil { message["media"] = [["id": "cover", "media": ["type": "photo", "media": "attach://cover"]]] }
        return message
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension TelegramPublishingService {
    func publishRichPost(_ post: EssayRichPost, botToken: String, channelId: String) async throws -> Int {
        let token = botToken.trimmed, channel = channelId.trimmed
        guard !token.isEmpty, !channel.isEmpty else { throw TelegramPublishError.emptyCredentials }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendRichMessage") else { throw TelegramPublishError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        let boundary = "EssayRich-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let rich = try JSONSerialization.data(withJSONObject: post.richMessage, options: [.sortedKeys])
        var body = Data()
        func field(_ name: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(data); body.append(Data("\r\n".utf8))
        }
        let destination = channel.hasPrefix("-") || channel.hasPrefix("@") ? channel : "@" + channel
        field("chat_id", Data(destination.utf8)); field("rich_message", rich)
        if let cover = post.coverURL {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"cover\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(try Data(contentsOf: cover)); body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8)); request.httpBody = body
        // No automatic plain-message fallback after an uncertain send: that can
        // duplicate a post that Telegram already accepted.
        let (data, response) = try await session.data(for: request)
        return try parseMessageID(from: data, response: response)
    }
}
