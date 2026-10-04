import Foundation

/// Protocol defining Telegram publishing capabilities, following Interface Segregation and Dependency Inversion.
protocol TelegramPublishingProtocol: Sendable {
    func testConnection(botToken: String, channelId: String) async throws -> (botUsername: String, channelTitle: String)
    func publishMoviePost(clip: ShortClip, botToken: String, channelId: String) async throws -> Int
    func publishLongformPost(
        result: LongformBuildResult,
        movieTitle: String,
        movie: MovieIdentity?,
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

    var errorDescription: String? {
        switch self {
        case .emptyCredentials:
            "Токен бота или ID канала Telegram не указаны."
        case .invalidURL:
            "Некорректный адрес запроса к Telegram API."
        case .apiError(let msg):
            "Ошибка Telegram API: \(msg)"
        case .networkError(let err):
            "Сетевая ошибка Telegram: \(err.localizedDescription)"
        case .decodingError:
            "Не удалось разобрать ответ от Telegram API."
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
    @MainActor
    func publishMoviePost(clip: ShortClip, botToken: String, channelId: String) async throws -> Int {
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

        // 2. If a video clip exists, send video directly; otherwise send photo or message
        if let videoURL = clip.clipJob?.url, FileManager.default.fileExists(atPath: videoURL.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
            // Bot API direct upload limit is 50MB
            if fileSize > 0 && fileSize < 48 * 1024 * 1024 {
                return try await sendVideoMultipart(
                    videoURL: videoURL,
                    caption: caption,
                    botToken: token,
                    channelId: cleanChannel)
            }
        }

        // Fallback: Send message via JSON
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
        botToken: String,
        channelId: String
    ) async throws -> Int {
        let token = botToken.trimmed
        let channel = channelId.trimmed
        guard !token.isEmpty, !channel.isEmpty else {
            throw TelegramPublishError.emptyCredentials
        }

        let cleanChannel = channel.hasPrefix("@") ? channel : "@\(channel)"

        var text = "🎬 «\(movieTitle)»"
        if let year = movie?.year, !year.isEmpty {
            text += " (\(year))"
        }
        text += " — Кино-эссе\n\n"
        text += "🔥 Лейтмотив: «\(result.arc.concept.word.uppercased())»\n"
        text += "💡 «\(result.arc.concept.tagline)»\n\n"
        text += "📖 \(result.arc.concept.philosophicalPremise)\n\n"
        text += "▶️ Премьера на YouTube:\n«\(result.metadata.title)»\n\n"
        
        if let imdb = movie?.imdbRating, !imdb.isEmpty {
            text += "⭐ Рейтинг IMDb: \(imdb)\n"
        }
        text += "🍿 Канал: \(cleanChannel)"

        if text.count > 4096 {
            text = String(text.prefix(4090)) + "..."
        }

        return try await sendMessageJSON(
            text: text,
            botToken: token,
            channelId: cleanChannel
        )
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
            "text": text
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

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
