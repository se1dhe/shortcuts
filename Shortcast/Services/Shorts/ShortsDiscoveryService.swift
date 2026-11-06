import Foundation

struct ShortsDiscoveryService: Sendable {
    static let films = ["Бойцовский клуб", "Джентльмены", "Драйв", "Интерстеллар", "Джон Уик", "Криминальное чтиво", "Леон", "Темный рыцарь", "Одержимость", "Американский психопат", "Гладиатор", "Начало"]

    static func downloader() throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let binary = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent("yt-dlp") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ShortsError.message("Для поиска и загрузки нужен yt-dlp. Установите: brew install yt-dlp")
        }
        return binary
    }

    func discover(films: [String], category: String) async throws -> [DiscoveredShort] {
        var cards: [DiscoveredShort] = []
        for film in films {
          let topic = category == "сильные диалоги" ? "диалог" : category == "культовые сцены" ? "сцена" : "эдит"
          for query in ["\(film) \(topic)", film] {
            var search = URLComponents(string: "https://www.youtube.com/results")!
            search.queryItems = [
                URLQueryItem(name: "search_query", value: query),
                URLQueryItem(name: "sp", value: "EgIQBQ=="), // YouTube's Shorts filter
                URLQueryItem(name: "hl", value: "ru")
            ]
            var request = URLRequest(url: search.url!, timeoutInterval: 30)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
                throw ShortsError.message("YouTube не вернул подборку. Попробуйте позже.")
            }
            let found = try Self.parseSearchPage(html, film: film)
            cards += found
            if !found.isEmpty { break }
          }
        }
        var ids = Set<String>()
        return cards.filter { ids.insert($0.id).inserted }.sorted { $0.views > $1.views }
    }

    /// Shorts shelves currently use gridShelfViewModel, which older yt-dlp skips.
    /// Read only explicit Shorts lockups, never arbitrary video recommendations.
    static func parseSearchPage(_ html: String, film: String) throws -> [DiscoveredShort] {
        guard let marker = html.range(of: "var ytInitialData = ") ?? html.range(of: "window[\"ytInitialData\"] = ") else {
            throw ShortsError.message("Не найдены карточки YouTube. Возможно, требуется согласие или изменился формат страницы.")
        }
        let bytes = Array(html[marker.upperBound...].utf8)
        var depth = 0, quoted = false, escaped = false
        var end: Int?
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 { end = index + 1; break }
            }
        }
        guard let end else { throw ShortsError.message("Неполный ответ YouTube.") }
        let root = try JSONSerialization.jsonObject(with: Data(bytes.prefix(end)))
        var rows: [[String: Any]] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                if let short = object["shortsLockupViewModel"] as? [String: Any],
                   let onTap = short["onTap"] as? [String: Any],
                   let command = onTap["innertubeCommand"] as? [String: Any],
                   let endpoint = command["reelWatchEndpoint"] as? [String: Any],
                   let id = endpoint["videoId"] as? String,
                   let overlay = short["overlayMetadata"] as? [String: Any],
                   let primary = overlay["primaryText"] as? [String: Any], let title = primary["content"] as? String {
                    let stats = (overlay["secondaryText"] as? [String: Any])?["content"] as? String ?? ""
                    rows.append(["id": id, "title": title, "url": "https://www.youtube.com/shorts/\(id)", "view_count": viewCount(stats)])
                    return
                }
                for child in object.values { walk(child) }
            } else if let array = value as? [Any] { for child in array { walk(child) } }
        }
        walk(root)
        let lines = try rows.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
        return try DiscoveredShort.parseSearch(lines, film: film)
    }

    static func viewCount(_ text: String) -> Int {
        let lower = text.lowercased()
        guard let range = lower.range(of: "[0-9][0-9 .,\u{00a0}\u{202f}]*", options: .regularExpression) else { return 0 }
        let number = lower[range].filter { $0.isNumber || $0 == "," || $0 == "." }.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(number), value.isFinite, value >= 0 else { return 0 }
        let multiplier: Double = lower.contains("млн") || lower.contains("million") || (lower.range(of: "[0-9]\\s*m(?:\\s|$)", options: .regularExpression) != nil) ? 1_000_000 :
            (lower.contains("тыс") || (lower.range(of: "[0-9]\\s*k(?:\\s|$)", options: .regularExpression) != nil) || lower.contains("thousand") ? 1_000 : 1)
        return Int(min(value * multiplier, 1_000_000_000_000))
    }

    func render(_ card: DiscoveredShort, directory: URL, watermark: URL) async throws -> (url: URL, sourceDuration: Double) {
        guard DiscoveredShort.validID(card.id), card.start.isFinite, card.end.isFinite,
              card.start >= 0,
              (card.duration == 0 && card.start == 0 && card.end == 0) || (card.end <= card.duration && card.end - card.start >= 3) else {
            throw ShortsError.message("Выберите отрезок не короче 3 секунд в пределах ролика.")
        }
        guard let ffmpeg = BinaryUtilities.resolveFFmpegBinary(workingDirectory: nil),
              let probe = BinaryUtilities.resolveFFprobeBinary(workingDirectory: nil) else {
            throw ShortsError.message("Для обработки нужны ffmpeg и ffprobe.")
        }
        let job = directory.appendingPathComponent("media/\(card.id)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let template = job.appendingPathComponent("source.%(ext)s")
        let download = try await ProcessRunner.shared.run(executableURL: Self.downloader(), arguments: [
            "--ignore-config", "--no-playlist", "--write-info-json", "--no-progress", "--socket-timeout", "30", "--retries", "2",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "-f", "bv[height<=1920]+ba[language^=ru]/b[height<=1920][language^=ru]/bv[height<=1920]+ba/b[height<=1920]", "--merge-output-format", "mp4",
            "--print", "after_move:filepath", "-o", template.path, "--", card.sourceURL.absoluteString
        ])
        guard let path = download.standardOutput.split(separator: "\n").last.map(String.init),
              path.hasPrefix(job.path + "/"), FileManager.default.fileExists(atPath: path) else {
            throw ShortsError.message("YouTube не вернул видеофайл.")
        }
        let metadata = try await ProcessRunner.shared.run(executableURL: probe, arguments: [
            "-v", "error", "-show_streams", "-show_format", "-of", "json", path
        ])
        let infoData = try Data(contentsOf: job.appendingPathComponent("source.info.json"))
        let info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any] ?? [:]
        let formats = info["requested_formats"] as? [[String: Any]] ?? []
        let audio = formats.first { ($0["acodec"] as? String).map { $0 != "none" } == true }
        // MP4 mergers can label an untagged Russian Opus stream as "eng".
        // Use the selected YouTube track's language, rather than that container default.
        let language = audio?["language"] as? String ?? info["language"] as? String ?? "und"
        let sourceDuration = try Self.validateSource(Data(metadata.standardOutput.utf8), end: card.end, audioLanguage: language)
        let end = card.end == 0 ? sourceDuration : card.end
        let output = job.appendingPathComponent("telonyx-\(card.id).mp4")
        _ = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-ss", String(card.start), "-i", path, "-framerate", String(ShortsWatermark.frameRate), "-i", watermark.path,
            "-filter_complex", ShortsWatermark.filter,
            "-map", "[v]", "-map", "0:a:0", "-t", String(end - card.start),
            "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path
        ])
        guard FileManager.default.fileExists(atPath: output.path) else { throw ShortsError.message("Файл после обработки не найден.") }
        // Keep only the branded export; source remains available on YouTube.
        try? FileManager.default.removeItem(atPath: path)
        return (output, sourceDuration)
    }

    @discardableResult
    static func validateSource(_ data: Data, end: Double, audioLanguage: String? = nil) throws -> Double {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let w = video["width"] as? Int, let h = video["height"] as? Int, h > w,
              let format = root["format"] as? [String: Any],
              let seconds = Double(format["duration"] as? String ?? ""), seconds.isFinite, seconds >= 3, seconds <= 180, seconds + 0.1 >= end,
              let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw ShortsError.message("Нужен вертикальный ролик со звуком длительностью до 3 минут.")
        }
        let language = (audioLanguage ?? (audio["tags"] as? [String: String])?["language"])?.lowercased()
        if let language, !["ru", "rus", "und"].contains(language) {
            throw ShortsError.message("Звуковая дорожка помечена как \(language), нужен русский язык.")
        }
        return seconds
    }
}

enum ShortsError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
