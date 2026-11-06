import Foundation

struct DiscoveredShort: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case discovered, ready, publishing, published, needsReview
        var title: String {
            switch self {
            case .discovered: "Из YouTube"
            case .ready: "Готов к публикации"
            case .publishing: "Публикуется"
            case .published: "Опубликован"
            case .needsReview: "Проверьте TikTok перед повтором"
            }
        }
    }
    var id: String
    var title: String
    var channel: String
    /// Zero means YouTube omitted duration in its Shorts shelf; probe before rendering.
    var duration: Double
    var views: Int
    var film: String
    var status: Status = .discovered
    var watermarkVersion: Int?
    var outputPath: String?
    var publishedURL: String?
    var issue: String?
    var caption: String
    var start: Double = 0
    var end: Double
    var reviewed = false
    var sourceURL: URL { URL(string: "https://www.youtube.com/shorts/\(id)")! }
    var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
    var hasCurrentWatermark: Bool { watermarkVersion == ShortsWatermark.version }
    var canPublish: Bool {
        status == .ready && hasCurrentWatermark && outputPath.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    static func parseSearch(_ output: String, film: String) throws -> [Self] {
        try output.split(separator: "\n").compactMap { line in
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, validID(id),
                  let title = row["title"] as? String else { return nil }
            let duration = row["duration"] as? Double ?? 0
            guard duration == 0 || (duration >= 5 && duration <= 180) else { return nil }
            let lower = title.lowercased()
            let url = row["url"] as? String ?? ""
            guard url.contains("/shorts/") || (duration > 0 && lower.contains("#shorts")) else { return nil }
            let searchable = (title + " " + (row["description"] as? String ?? "")).lowercased().replacingOccurrences(of: "ё", with: "е")
            guard searchable.contains(film.lowercased().replacingOccurrences(of: "ё", with: "е")) else { return nil }
            guard title.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil else { return nil }
            let excluded = ["русский фильм", "российск", "советск", "джентльмены удачи", "джентельмены удачи", "сериал", "трейлер", "обзор фильма", "пересказ"]
            guard !excluded.contains(where: lower.contains) else { return nil }
            return Self(id: id, title: title, channel: row["channel"] as? String ?? row["uploader"] as? String ?? "YouTube",
                        duration: duration, views: row["view_count"] as? Int ?? 0, film: film,
                        caption: "\(film) · \(title)\n#кино #фильмы #эдит #telonyx_cinema", end: duration)
        }
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }

    static func isTargetPublication(_ address: String) -> Bool {
        guard let url = URL(string: address), url.scheme == "https",
              ["www.tiktok.com", "tiktok.com"].contains(url.host?.lowercased() ?? "") else { return false }
        return url.path.range(of: "^/@telonyx_cinema/video/[0-9]+/?$", options: .regularExpression) != nil
    }
}
