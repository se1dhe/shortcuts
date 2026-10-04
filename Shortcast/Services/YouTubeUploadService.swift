import Foundation
import os.log

/// Протокол сервиса загрузки видео на YouTube (SOLID: Interface Segregation).
public protocol YouTubeUploadServicing: Sendable {
    func uploadVideo(
        videoURL: URL,
        title: String,
        description: String,
        tags: [String],
        isPublic: Bool,
        accessToken: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> String
}

/// Ошибки загрузки на YouTube через Resumable Upload API v3.
public enum YouTubeUploadError: LocalizedError, Sendable {
    case missingToken
    case fileNotFound(URL)
    case initiateFailed(statusCode: Int, message: String)
    case missingSessionURL
    case chunkFailed(statusCode: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Не указан OAuth Access Token для YouTube API."
        case .fileNotFound(let url):
            return "Файл видео не найден: \(url.path)"
        case .initiateFailed(let code, let msg):
            return "Не удалось начать сессию загрузки YouTube (HTTP \(code)): \(msg)"
        case .missingSessionURL:
            return "YouTube API не вернул Location URL сессии загрузки."
        case .chunkFailed(let code, let msg):
            return "Ошибка передачи фрагмента видео (HTTP \(code)): \(msg)"
        case .invalidResponse:
            return "Некорректный ответ от серверов YouTube."
        }
    }
}

/// Реализация протокола YouTube Resumable Upload API v3 (SOLID: Single Responsibility).
/// Загружает видео любого размера чанками (кратно 256 КБ), поддерживая докачку и отчет о прогрессе.
public final class YouTubeUploadService: YouTubeUploadServicing, Sendable {

    public static let shared = YouTubeUploadService()

    private static let logger = Logger(subsystem: "app.shortcast", category: "YouTubeUploadService")

    /// Размер чанка: 8 МБ (Google требует кратность 256 КБ = 262144 байт)
    private let chunkSize: Int = 8 * 1024 * 1024

    public init() {}

    public func uploadVideo(
        videoURL: URL,
        title: String,
        description: String,
        tags: [String],
        isPublic: Bool,
        accessToken: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw YouTubeUploadError.missingToken
        }

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw YouTubeUploadError.fileNotFound(videoURL)
        }

        let fileValues = try videoURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = fileValues.fileSize, fileSize > 0 else {
            throw YouTubeUploadError.fileNotFound(videoURL)
        }

        Self.logger.notice("Starting Resumable Upload to YouTube for \(videoURL.lastPathComponent) (\(fileSize) bytes)")

        // 1. Инициация Resumable Session
        let sessionURL = try await initiateUploadSession(
            title: title,
            description: description,
            tags: tags,
            isPublic: isPublic,
            fileSize: fileSize,
            accessToken: accessToken
        )

        Self.logger.notice("Session URL obtained, uploading chunks...")

        // 2. Чанковая загрузка файла
        let videoId = try await uploadChunks(
            videoURL: videoURL,
            fileSize: fileSize,
            sessionURL: sessionURL,
            onProgress: onProgress
        )

        Self.logger.notice("Upload completed successfully! Video ID: \(videoId)")
        return videoId
    }

    private func initiateUploadSession(
        title: String,
        description: String,
        tags: [String],
        isPublic: Bool,
        fileSize: Int,
        accessToken: String
    ) async throws -> URL {
        let endpoint = URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")

        let metadata: [String: Any] = [
            "snippet": [
                "title": title.prefix(100),
                "description": description.prefix(5000),
                "tags": Array(tags.prefix(30)),
                "categoryId": "24" // Entertainment / Film
            ],
            "status": [
                "privacyStatus": isPublic ? "public" : "unlisted"
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeUploadError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw YouTubeUploadError.initiateFailed(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        guard let locationString = httpResponse.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: locationString) else {
            throw YouTubeUploadError.missingSessionURL
        }

        return sessionURL
    }

    private func uploadChunks(
        videoURL: URL,
        fileSize: Int,
        sessionURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: videoURL)
        defer { try? handle.close() }

        var offset = 0

        while offset < fileSize {
            try Task.checkCancellation()

            let currentChunkLength = min(chunkSize, fileSize - offset)
            try handle.seek(toOffset: UInt64(offset))
            let chunkData = try handle.read(upToCount: currentChunkLength) ?? Data()

            let endByte = offset + chunkData.count - 1

            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(endByte)/\(fileSize)", forHTTPHeaderField: "Content-Range")
            request.setValue(String(chunkData.count), forHTTPHeaderField: "Content-Length")
            request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            request.httpBody = chunkData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw YouTubeUploadError.invalidResponse
            }

            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                // Загрузка завершена! Парсим ответ YouTube Video Resource
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let videoId = json?["id"] as? String {
                    onProgress?(1.0)
                    return videoId
                }
                onProgress?(1.0)
                return "uploaded_video"
            } else if httpResponse.statusCode == 308 {
                // Resume Incomplete — чанк принят, обновляем смещение и прогресс
                offset += chunkData.count
                let fraction = Double(offset) / Double(fileSize)
                onProgress?(fraction)
            } else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw YouTubeUploadError.chunkFailed(statusCode: httpResponse.statusCode, message: errorMsg)
            }
        }

        return "uploaded_video"
    }
}
