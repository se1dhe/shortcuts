import Foundation

/// Protocol defining Telegram publishing capabilities, following Interface Segregation and Dependency Inversion.
protocol TelegramPublishingProtocol: Sendable {
    func testConnection(botToken: String, channelId: String) async throws -> (botUsername: String, channelTitle: String)
    func publishMoviePost(clip: ShortClip, botToken: String, channelId: String, compressLargeVideo: Bool) async throws -> Int
    func publishLongformPost(
        result: LongformBuildResult,
        movieTitle: String,
        movie: MovieIdentity?,
        youtubeURL: String?,
        botToken: String,
        channelId: String
    ) async throws -> Int
}

enum TelegramPublishError: LocalizedError {
    case emptyCredentials
    case invalidURL
    case apiError(String)
    case networkError(Error)
    case decodingError
    case fileTooLarge(bytes: Int64)
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .emptyCredentials:
            return "Токен бота или ID канала Telegram не указаны."
        case .invalidURL:
            return "Некорректный адрес запроса к Telegram API."
        case .apiError(let msg):
            return "Ошибка Telegram API: \(msg)"
        case .networkError(let err):
            return "Сетевая ошибка Telegram: \(err.localizedDescription)"
        case .decodingError:
            return "Не удалось разобрать ответ от Telegram API."
        case .fileTooLarge(let bytes):
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return "Видео \(String(format: "%.0f", mb)) МБ превышает лимит Telegram Bot API (48 МБ), а сжатие до 720p не помогло."
        case .compressionFailed:
            return "Не удалось сжать видео до 720p: FFmpeg недоступен или завершился с ошибкой."
        }
    }
}

/// Standalone service for publishing cinema short posts and metadata to a Telegram channel via Bot API.
final class TelegramPublishingService: TelegramPublishingProtocol, Sendable {

    static let shared = TelegramPublishingService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Tests the validity of the bot token and verifies administrator access to the channel.
    func testConnection(botToken: String, channelId: String) async throws -> (botUsername: String, channelTitle: String) {
        let token = botToken.trimmed
        let channel = channelId.trimmed
        guard !token.isEmpty, !channel.isEmpty else {
            throw TelegramPublishError.emptyCredentials
        }

        // 1. Verify Bot Token via getMe
        guard let getMeURL = URL(string: "https://api.telegram.org/bot\(token)/getMe") else {
            throw TelegramPublishError.invalidURL
        }

        let (meData, meResp) = try await session.data(from: getMeURL)
        guard let httpMe = meResp as? HTTPURLResponse, httpMe.statusCode == 200,
              let meJson = try? JSONSerialization.jsonObject(with: meData) as? [String: Any],
              let meOk = meJson["ok"] as? Bool, meOk,
              let meResult = meJson["result"] as? [String: Any],
              let botUsername = meResult["username"] as? String else {
            let desc = parseErrorDescription(from: meData) ?? "Неверный токен бота."
            throw TelegramPublishError.apiError(desc)
        }

        // 2. Verify Channel Access via getChat
        let cleanChannel = channel.hasPrefix("@") ? channel : "@\(channel)"
        guard let encodedChannel = cleanChannel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let getChatURL = URL(string: "https://api.telegram.org/bot\(token)/getChat?chat_id=\(encodedChannel)") else {
            throw TelegramPublishError.invalidURL
        }

        let (chatData, chatResp) = try await session.data(from: getChatURL)
        guard let httpChat = chatResp as? HTTPURLResponse, httpChat.statusCode == 200,
              let chatJson = try? JSONSerialization.jsonObject(with: chatData) as? [String: Any],
              let chatOk = chatJson["ok"] as? Bool, chatOk,
              let chatResult = chatJson["result"] as? [String: Any] else {
            let desc = parseErrorDescription(from: chatData) ?? "Бот не добавлен администратором в канал \(cleanChannel)."
            throw TelegramPublishError.apiError(desc)
        }

        let channelTitle = chatResult["title"] as? String ?? cleanChannel
        return (botUsername: "@\(botUsername)", channelTitle: channelTitle)
    }

    /// Publishes a movie post with poster/video and formatted description to the channel.
    ///
    /// - Parameter compressLargeVideo: when the rendered clip exceeds the Telegram Bot API
    ///   48 MB direct-upload limit, re-encode it to 720p via FFmpeg and upload the smaller
    ///   file. When `false`, a too-large clip throws `.fileTooLarge` instead of silently
    ///   falling back to a text-only post (which would drop the video entirely).
    @MainActor
    func publishMoviePost(clip: ShortClip, botToken: String, channelId: String, compressLargeVideo: Bool = true) async throws -> Int {
        let token = botToken.trimmed
        let channel = channelId.trimmed
        guard !token.isEmpty, !channel.isEmpty else {
            throw TelegramPublishError.emptyCredentials
        }

        let cleanChannel = channel.hasPrefix("@") ? channel : "@\(channel)"

        // 1. Prepare caption and body
        let telegramVariant = clip.variants.first(where: { $0.platform == .telegram })
        var caption = telegramVariant?.summary ?? ""
        if caption.isEmpty {
            let yearPart = clip.detectedMovieYear.isEmpty ? "" : " (\(clip.detectedMovieYear))"
            let title = !clip.detectedMovieTitle.isEmpty ? clip.detectedMovieTitle : clip.displayTitle
            caption = "🎬 «\(title)»\(yearPart)\n\n🍿 Приятного просмотра!\nКанал: \(cleanChannel)"
        }

        // Telegram captions on media cannot exceed 1024 characters
        if caption.count > 1024 {
            caption = String(caption.prefix(1020)) + "..."
        }

        // 2. If a video clip exists, send video directly; otherwise send a text-only message.
        let byteLimit: Int64 = 48 * 1024 * 1024
        if let videoURL = clip.clipJob?.url, FileManager.default.fileExists(atPath: videoURL.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)?.int64Value ?? 0

            if fileSize > 0 && fileSize < byteLimit {
                return try await sendVideoMultipart(
                    videoURL: videoURL,
                    caption: caption,
                    botToken: token,
                    channelId: cleanChannel)
            }

            // Слишком большой файл: сжимаем до 720p вместо молчаливого text-only fallback.
            guard fileSize > 0 else {
                return try await sendMessageJSON(text: caption, botToken: token, channelId: cleanChannel)
            }
            guard compressLargeVideo else {
                throw TelegramPublishError.fileTooLarge(bytes: fileSize)
            }

            let compressedURL = try await compressVideoTo720p(sourceURL: videoURL)
            defer { try? FileManager.default.removeItem(at: compressedURL) }
            let compressedSize = (try? FileManager.default.attributesOfItem(atPath: compressedURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard compressedSize > 0 && compressedSize < byteLimit else {
                throw TelegramPublishError.fileTooLarge(bytes: compressedSize > 0 ? compressedSize : fileSize)
            }
            return try await sendVideoMultipart(
                videoURL: compressedURL,
                caption: caption,
                botToken: token,
                channelId: cleanChannel)
        }

        // Нет видеофайла — отправляем только текст.
        return try await sendMessageJSON(
            text: caption,
            botToken: token,
            channelId: cleanChannel)
    }

    /// Публикует анонс и карточку полнометражного кино-эссе в Telegram-канал
    func publishLongformPost(
        result: LongformBuildResult,
        movieTitle: String,
        movie: MovieIdentity?,
        youtubeURL: String? = nil,
        botToken: String,
        channelId: String
    ) async throws -> Int {
        let token = botToken.trimmed
        let channel = channelId.trimmed
        guard !token.isEmpty, !channel.isEmpty else {
            throw TelegramPublishError.emptyCredentials
        }

        let cleanChannel = channel.hasPrefix("@") ? channel : "@\(channel)"

        let safeMovieTitle = movieTitle.telegramHTMLEscaped
        let safeConceptWord = result.arc.concept.word.uppercased().telegramHTMLEscaped
        let safeTagline = result.arc.concept.tagline.telegramHTMLEscaped
        let safeEssayTitle = result.metadata.title.telegramHTMLEscaped
        let safePremise = result.arc.concept.philosophicalPremise.telegramHTMLEscaped

        let yearText = (movie?.year.isEmpty == false) ? " (\(movie!.year.telegramHTMLEscaped))" : ""
        let header = "🎬 <b>«\(safeMovieTitle)»</b>\(yearText) — Кино-эссе\n\n🔥 Лейтмотив: <b>«\(safeConceptWord)»</b>\n💡 <i>«\(safeTagline)»</i>\n\n"

        var linkPart = "\n\n"
        if let yt = youtubeURL, !yt.isEmpty {
            linkPart += "▶️ Смотреть на YouTube:\n<a href=\"\(yt)\">«\(safeEssayTitle)»</a>\n\n"
        } else {
            linkPart += "▶️ Премьера на YouTube:\n«\(safeEssayTitle)»\n\n"
        }
        if let imdb = movie?.imdbRating, !imdb.isEmpty {
            linkPart += "⭐ Рейтинг IMDb: \(imdb.telegramHTMLEscaped)\n"
        }
        linkPart += "🍿 Канал: \(cleanChannel)"

        // Лимит подписи в Telegram Bot API для sendPhoto: 1024 символа
        let budget = max(50, 960 - header.count - linkPart.count)
        let trimmedPremise: String
        if safePremise.count > budget {
            trimmedPremise = String(safePremise.prefix(budget)) + "..."
        } else {
            trimmedPremise = safePremise
        }

        let fullHTMLCaption = header + "📖 " + trimmedPremise + linkPart

        // Если обложка существует, отправляем пост с авторской 16:9 обложкой (лимит подписи Telegram 1024 символа)
        if let thumbURL = result.thumbnailURL, FileManager.default.fileExists(atPath: thumbURL.path) {
            do {
                return try await sendPhotoMultipart(
                    photoURL: thumbURL,
                    caption: fullHTMLCaption,
                    botToken: token,
                    channelId: cleanChannel
                )
            } catch {
                // Если отправка фото вернула ошибку, переходим к резервной отправке видео/текста
            }
        }

        // Если видеофайл помещается в лимит Telegram Bot API (<= 48 MB), отправляем сам видеофайл
        if FileManager.default.fileExists(atPath: result.outputURL.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if fileSize > 0 && fileSize <= 48 * 1024 * 1024 {
                if let msgId = try? await sendVideoMultipart(
                    videoURL: result.outputURL,
                    caption: fullHTMLCaption,
                    botToken: token,
                    channelId: cleanChannel
                ) {
                    return msgId
                }
            }
        }

        let plainOrTruncatedText = (fullHTMLCaption.count > 4096) ? String(fullHTMLCaption.prefix(4090)) + "..." : fullHTMLCaption

        return try await sendMessageJSON(
            text: plainOrTruncatedText,
            botToken: token,
            channelId: cleanChannel
        )
    }

    // MARK: - Video compression

    /// Re-encodes a video to 720p H.264 so it fits under the Telegram Bot API upload limit.
    /// Returns a temporary file the caller is responsible for deleting.
    private func compressVideoTo720p(sourceURL: URL) async throws -> URL {
        guard let ffmpegURL = resolveFFmpegBinary() else {
            throw TelegramPublishError.compressionFailed
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-720p-\(UUID().uuidString).mp4")
        let arguments = [
            "-y",
            "-i", sourceURL.path,
            "-vf", "scale=-2:min(720\\,ih)",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "26",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            outputURL.path
        ]
        do {
            let result = try await ProcessRunner.shared.run(executableURL: ffmpegURL, arguments: arguments, environment: nil)
            guard result.isSuccess, FileManager.default.fileExists(atPath: outputURL.path) else {
                try? FileManager.default.removeItem(at: outputURL)
                throw TelegramPublishError.compressionFailed
            }
            return outputURL
        } catch let error as TelegramPublishError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw TelegramPublishError.compressionFailed
        }
    }

    private func resolveFFmpegBinary() -> URL? {
        if let bin = BinaryDownloadService.resolveBinary("ffmpeg", workingDirectory: nil) {
            return bin
        }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: - Private API helpers

    private func sendMessageJSON(text: String, botToken: String, channelId: String) async throws -> Int {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else {
            throw TelegramPublishError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "chat_id": channelId,
            "text": text,
            "parse_mode": "HTML"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await session.data(for: request)
        return try parseMessageID(from: data, response: resp)
    }

    private func sendPhotoMultipart(photoURL: URL, caption: String, botToken: String, channelId: String) async throws -> Int {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto") else {
            throw TelegramPublishError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendString(_ str: String) {
            if let d = str.data(using: .utf8) { body.append(d) }
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        appendString("\(channelId)\r\n")

        // parse_mode: HTML
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"parse_mode\"\r\n\r\n")
        appendString("HTML\r\n")

        if !caption.isEmpty {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"caption\"\r\n\r\n")
            appendString("\(caption)\r\n")
        }

        let photoData = try Data(contentsOf: photoURL)
        let filename = photoURL.lastPathComponent
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(photoData)
        appendString("\r\n")
        appendString("--\(boundary)--\r\n")

        request.httpBody = body
        let (data, resp) = try await session.data(for: request)
        return try parseMessageID(from: data, response: resp)
    }

    private func sendVideoMultipart(videoURL: URL, caption: String, botToken: String, channelId: String) async throws -> Int {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendVideo") else {
            throw TelegramPublishError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let tempUploadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-upload-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempUploadURL) }

        FileManager.default.createFile(atPath: tempUploadURL.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: tempUploadURL) else {
            throw TelegramPublishError.networkError(NSError(domain: "Telegram", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать временный файл для выгрузки"]))
        }

        func writeString(_ string: String) {
            if let data = string.data(using: .utf8) {
                fileHandle.write(data)
            }
        }

        // chat_id field
        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        writeString("\(channelId)\r\n")

        // parse_mode field
        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"parse_mode\"\r\n\r\n")
        writeString("HTML\r\n")

        // caption field
        if !caption.isEmpty {
            writeString("--\(boundary)\r\n")
            writeString("Content-Disposition: form-data; name=\"caption\"\r\n\r\n")
            writeString("\(caption)\r\n")
        }

        // video file field
        let safeFilename = videoURL.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"video\"; filename=\"\(safeFilename)\"\r\n")
        writeString("Content-Type: video/mp4\r\n\r\n")

        // Потоково переносим видеофайл чанками по 1 МБ, не забивая RAM
        if let videoReadHandle = try? FileHandle(forReadingFrom: videoURL) {
            defer { try? videoReadHandle.close() }
            while true {
                let chunk = videoReadHandle.readData(ofLength: 1024 * 1024)
                if chunk.isEmpty { break }
                fileHandle.write(chunk)
            }
        }
        writeString("\r\n")
        writeString("--\(boundary)--\r\n")
        try? fileHandle.close()

        let (data, resp) = try await session.upload(for: request, fromFile: tempUploadURL)
        return try parseMessageID(from: data, response: resp)
    }

    private func parseMessageID(from data: Data, response: URLResponse) throws -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let result = json["result"] as? [String: Any],
              let messageId = result["message_id"] as? Int else {
            let desc = parseErrorDescription(from: data) ?? "Не удалось отправить сообщение."
            throw TelegramPublishError.apiError(desc)
        }
        return messageId
    }

    private func parseErrorDescription(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["description"] as? String
    }
}

private extension String {
    var telegramHTMLEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
