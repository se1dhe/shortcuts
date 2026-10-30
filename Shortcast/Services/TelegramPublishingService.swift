import Foundation

/// Protocol defining Telegram publishing capabilities, following Interface Segregation and Dependency Inversion.
protocol TelegramPublishingProtocol: Sendable {
    func testConnection(botToken: String, channelId: String) async throws -> (botUsername: String, channelTitle: String)

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

    let session: URLSession

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

    func parseMessageID(from data: Data, response: URLResponse) throws -> Int {
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
