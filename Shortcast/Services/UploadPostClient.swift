import Foundation

enum UploadPostError: LocalizedError {
    case notConfigured
    case rateLimited(count: Int?, limit: Int?)
    case http(status: Int, body: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Upload-Post API key and profile name in Settings first."
        case .rateLimited(let count, let limit):
            if let count, let limit {
                return "Upload-Post monthly limit reached (\(count)/\(limit))."
            }
            return "Upload-Post monthly upload limit reached."
        case .http(let status, let body):
            return "Upload-Post returned HTTP \(status). \(body)"
        case .transport(let detail):
            return detail
        }
    }
}

/// Thin client for the Upload-Post REST API. Publishes one video to TikTok,
/// Instagram Reels and YouTube Shorts in a single multipart request.
struct UploadPostClient: Sendable {

    let apiKey: String
    let profileName: String

    private static let base = URL(string: "https://api.upload-post.com")!

    enum PlatformOutcome: Sendable, Equatable {
        case success(url: String?)
        /// Accepted by Upload-Post but still processing / scheduled.
        case submitted
        case failure(String)
    }

    struct PublishReport: Sendable {
        var outcomes: [SocialPlatform: PlatformOutcome]
        var requestID: String?
        var rawResponse: String
    }

    // MARK: - Connection check

    /// Calls `GET /api/uploadposts/me`; throws if the key is rejected.
    func checkConnection() async throws {
        guard !apiKey.trimmed.isEmpty else { throw UploadPostError.notConfigured }
        var request = URLRequest(url: Self.base.appending(path: "api/uploadposts/me"))
        request.setValue("Apikey \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session().data(for: request)
        try Self.ensureOK(response, data: data)
    }

    // MARK: - Publish

    func publish(
        videoURL: URL,
        variants: [PostVariant],
        tiktokAsDraft: Bool,
        selectedPlatforms: Set<SocialPlatform>? = nil,
        scheduledDate: Date? = nil
    ) async throws -> PublishReport {

        guard !apiKey.trimmed.isEmpty, !profileName.trimmed.isEmpty else {
            throw UploadPostError.notConfigured
        }

        let byPlatform = Dictionary(uniqueKeysWithValues: variants.map { ($0.platform, $0) })
        let boundary = "Shortcast-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var body: MultipartFileBody
        do {
            body = try MultipartFileBody(boundary: boundary, outputURL: bodyURL)
        } catch {
            throw UploadPostError.transport("Couldn't prepare the upload: \(error.localizedDescription)")
        }

        body.addField("user", profileName)
        body.addField("async_upload", "false")
        let allowed = selectedPlatforms ?? Set(SocialPlatform.allCases)
        for platform in SocialPlatform.allCases where byPlatform[platform] != nil && allowed.contains(platform) && platform != .telegram {
            body.addField("platform[]", platform.uploadPostID)
        }

        // Scheduled publishing: the server queues the post for this instant.
        if let scheduledDate {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]  // UTC, e.g. 2026-12-25T10:00:00Z
            body.addField("scheduled_date", iso.string(from: scheduledDate))
            body.addField("timezone", TimeZone.current.identifier)
        }

        // General fallbacks (also satisfies YouTube's required `title`).
        if let youtube = byPlatform[.youtube] {
            let youtubeTitle = Self.youtubeTitle(from: youtube)
            body.addField("title", youtubeTitle)
            body.addField("description", youtube.summary.sanitizedModelText)
        } else if let any = variants.first {
            body.addField("title", any.hook.sanitizedModelText)
        }

        // Per-platform copy.
        if let tiktok = byPlatform[.tiktok] {
            body.addField("tiktok_title", Self.caption(for: tiktok).sanitizedModelText)
            if tiktokAsDraft { body.addField("post_mode", "MEDIA_UPLOAD") }
            if !tiktok.pinnedComment.trimmed.isEmpty {
                body.addField("tiktok_pinned_comment", tiktok.pinnedComment.sanitizedModelText)
            }
        }
        if let instagram = byPlatform[.instagram] {
            body.addField("instagram_title", Self.caption(for: instagram).sanitizedModelText)
            if !instagram.pinnedComment.trimmed.isEmpty {
                body.addField("instagram_pinned_comment", instagram.pinnedComment.sanitizedModelText)
            }
        }
        if let youtube = byPlatform[.youtube] {
            body.addField("youtube_title", Self.youtubeTitle(from: youtube))
            body.addField("youtube_description", Self.youtubeDescription(youtube).sanitizedModelText)
            if !youtube.pinnedComment.trimmed.isEmpty {
                body.addField("youtube_pinned_comment", youtube.pinnedComment.sanitizedModelText)
            }
        }

        do {
            try body.addFile("video", filename: videoURL.lastPathComponent,
                             contentType: "video/mp4", fileURL: videoURL)
            try body.finish()
        } catch {
            throw UploadPostError.transport("Couldn't prepare the video upload: \(error.localizedDescription)")
        }

        var request = URLRequest(url: Self.base.appending(path: "api/upload"))
        request.httpMethod = "POST"
        request.setValue("Apikey \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let data: Data
        let response: URLResponse
        do {
            // Uploading from a file keeps even a large 4K render out of RAM.
            (data, response) = try await session().upload(for: request, fromFile: bodyURL)
        } catch {
            throw UploadPostError.transport(error.localizedDescription)
        }
        try Self.ensureOK(response, data: data)

        return Self.parseReport(data: data, platforms: Array(byPlatform.keys).filter { $0 != .telegram })
    }

    // MARK: - Caption assembly

    private static func caption(for variant: PostVariant) -> String {
        [variant.hook, variant.summary, variant.hashtagLine]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func youtubeDescription(_ variant: PostVariant) -> String {
        [variant.summary, variant.hashtagLine]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// YouTube Shorts title: prefer the movie title line at the start of the summary
    /// (e.g. "🎬 Меню (2022)"), falling back to the hook only when no title line is present.
    private static func youtubeTitle(from variant: PostVariant) -> String {
        let summaryFirstLine = variant.summary
            .trimmed
            .components(separatedBy: .newlines)
            .first?
            .trimmed ?? ""
        let fallback = variant.hook.trimmed
        guard !summaryFirstLine.isEmpty else { return fallback }
        // Keep the fallback if the first line is just a generic caption start.
        let looksLikeMovieTitle = summaryFirstLine.hasPrefix("🎬") || summaryFirstLine.range(of: #"\(\d{4}\)"#, options: .regularExpression) != nil
        return looksLikeMovieTitle ? summaryFirstLine : fallback
    }

    // MARK: - Response handling

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200...299:
            return
        case 429:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw UploadPostError.rateLimited(
                count: json?["count"] as? Int,
                limit: json?["limit"] as? Int)
        default:
            throw UploadPostError.http(status: http.statusCode, body: String(body.prefix(400)))
        }
    }

    /// Best-effort mapping of the response to a per-platform outcome. The exact
    /// success-response shape varies, so anything unrecognised is reported as
    /// "submitted" with the raw JSON kept for display.
    private static func parseReport(data: Data, platforms: [SocialPlatform]) -> PublishReport {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let requestID = json?["request_id"] as? String ?? json?["job_id"] as? String

        // Look for a per-platform results container.
        let resultsNode: [String: Any]? =
            (json?["results"] as? [String: Any]) ?? json

        var outcomes: [SocialPlatform: PlatformOutcome] = [:]
        for platform in platforms {
            if let entry = resultsNode?[platform.uploadPostID] as? [String: Any] {
                let ok = (entry["success"] as? Bool) ?? (entry["status"] as? String == "success")
                if ok {
                    outcomes[platform] = .success(url: entry["url"] as? String)
                } else {
                    let message = (entry["error"] as? String)
                        ?? (entry["message"] as? String) ?? "Upload failed."
                    outcomes[platform] = .failure(message)
                }
            } else {
                outcomes[platform] = .submitted
            }
        }
        return PublishReport(outcomes: outcomes, requestID: requestID, rawResponse: raw)
    }
}

/// Builds a multipart body on disk. Video bytes are copied in chunks, then
/// URLSession streams the finished file instead of holding the MP4 in memory.
private struct MultipartFileBody {
    let boundary: String
    let outputURL: URL
    private let handle: FileHandle

    init(boundary: String, outputURL: URL) throws {
        self.boundary = boundary
        self.outputURL = outputURL
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: outputURL)
    }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    func addFile(_ name: String, filename: String, contentType: String, fileURL: URL) throws {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        let source = try FileHandle(forReadingFrom: fileURL)
        defer { try? source.close() }
        while true {
            let chunk = try source.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
        }
        append("\r\n")
    }

    func finish() throws {
        append("--\(boundary)--\r\n")
        try handle.close()
    }

    private func append(_ string: String) {
        try? handle.write(contentsOf: Data(string.utf8))
    }
}
