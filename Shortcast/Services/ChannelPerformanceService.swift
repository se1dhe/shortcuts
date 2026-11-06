import Foundation

actor ChannelPerformanceService {
    static let shared = ChannelPerformanceService()
    private let cacheURL: URL
    private var running = false
    init(cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Shortcast/channel-performance-v1.json")) {
        self.cacheURL = cacheURL
    }

    func cached() throws -> [ChannelPerformance] {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ChannelPerformance].self, from: Data(contentsOf: cacheURL))
    }

    /// A separate cache prevents a network refresh overwriting project edits or receipts.
    func refresh(targets: [ChannelPerformance.Target], now: Date = Date(), force: Bool = false,
                 fetch: @Sendable (URL) async throws -> String = ChannelPerformanceService.fetchPage) async throws -> [ChannelPerformance] {
        guard !running else { return try cached() }
        running = true
        defer { running = false }
        var reports = try cached()
        for target in targets {
            try Task.checkCancellation()
            let index: Int
            if let existing = reports.firstIndex(where: { $0.id == target.id }) { index = existing }
            else { reports.append(.init(target: target)); index = reports.count - 1 }
            reports[index].target = target
            if !force, let attempt = reports[index].lastAttempt, now.timeIntervalSince(attempt) < 6 * 3600 { continue }
            reports[index].lastAttempt = now
            do {
                let html = try await fetch(target.url)
                let sample = try Self.parse(html, target: target, now: now)
                reports[index].samples.append(sample)
                reports[index].samples = Array(reports[index].samples.suffix(40))
                reports[index].issue = nil
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Never turn missing, private or blocked data into zero views.
                reports[index].issue = "Счётчик недоступен. Последний успешный замер сохранён."
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(reports).write(to: cacheURL, options: .atomic)
        }
        return reports
    }

    nonisolated static func fetchPage(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 8_000_000, let html = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return html
    }

    nonisolated static func parse(_ html: String, target: ChannelPerformance.Target, now: Date) throws -> ChannelPerformance.Sample {
        func integer(_ value: Any?) -> Int? {
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
            guard !text.isEmpty, text.allSatisfy(\.isNumber), let number = Int(text), number >= 0 else { return nil }
            return number
        }
        if target.platform == "youtube", let range = html.range(of: "ytInitialPlayerResponse = "),
           let object = balancedObject(in: html[range.upperBound...]),
           let root = try JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any],
           let details = root["videoDetails"] as? [String: Any], details["videoId"] as? String == target.videoID,
           let views = integer(details["viewCount"]) {
            let micro = (root["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any]
            let date = (micro?["publishDate"] as? String).flatMap { raw in
                ISO8601DateFormatter().date(from: raw.count == 10 ? raw + "T00:00:00Z" : raw)
            }
            return .init(date: now, views: views, publishedAt: date)
        }
        if target.platform == "tiktok",
           let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*\bid=["']__UNIVERSAL_DATA_FOR_REHYDRATION__["'][^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html),
           let root = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any],
           let scope = root["__DEFAULT_SCOPE__"] as? [String: Any], let video = scope["webapp.video-detail"] as? [String: Any],
           let info = video["itemInfo"] as? [String: Any], let item = info["itemStruct"] as? [String: Any],
           item["id"] as? String == target.videoID, let stats = item["stats"] as? [String: Any],
           let views = integer(stats["playCount"]) {
            return .init(date: now, views: views, publishedAt: integer(item["createTime"]).map { Date(timeIntervalSince1970: Double($0)) })
        }
        throw URLError(.cannotParseResponse)
    }

    /// Extract JSON without evaluating page scripts or accepting another video's counters.
    private nonisolated static func balancedObject(in text: Substring) -> Substring? {
        let text = text.drop(while: \.isWhitespace)
        guard text.first == "{" else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in text.indices {
            let char = text[index]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else {
                if char == "\"" { quoted = true }
                else if char == "{" { depth += 1 }
                else if char == "}" { depth -= 1; if depth == 0 { return text[...index] } }
            }
        }
        return nil
    }
}
