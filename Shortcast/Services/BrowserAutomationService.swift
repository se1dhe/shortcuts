import Foundation
import os.log

/// Concrete service executing zero-API browser automation uploads via local Node/Playwright scripts.
/// Adheres to Single Responsibility Principle (SRP) and conforms to `BrowserPublishingProtocol`.
final class BrowserAutomationService: BrowserPublishingProtocol, Sendable {

    static let shared = BrowserAutomationService()

    private static let logger = Logger(subsystem: "app.shortcast", category: "BrowserAutomationService")

    private init() {}

    // MARK: - Node & Script Resolution

    static func resolveNodeBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. Поиск в PATH окружения
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.components(separatedBy: ":") where !dir.isEmpty {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("node")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        // 2. Стандартные системные пути macOS
        let standardCandidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        for path in standardCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // 3. Динамический поиск в nvm / fnm / volta
        let managers = [
            home.appendingPathComponent(".nvm/versions/node"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".fnm/current/bin")
        ]
        for baseDir in managers {
            if let subdirs = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) {
                for dir in subdirs {
                    let candidate = dir.appendingPathComponent("bin/node")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
            let direct = baseDir.appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: direct.path) {
                return direct
            }
        }

        return nil
    }

    static func resolveCliScript(workingDirectory: URL? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let potentialLocations: [URL] = [
            // В ресурсах приложения (App Bundle)
            Bundle.main.resourceURL?.appendingPathComponent("scripts/browser-publisher/src/cli.js"),
            Bundle.main.resourceURL?.appendingPathComponent("browser-publisher/src/cli.js"),
            // В Application Support пользователя
            home.appendingPathComponent("Library/Application Support/Shortcast/browser-publisher/src/cli.js"),
            // Относительно рабочего каталога
            workingDirectory?.appendingPathComponent("scripts/browser-publisher/src/cli.js"),
            // Относительно исходников проекта (при разработке)
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/browser-publisher/src/cli.js")
        ].compactMap { $0 }

        for location in potentialLocations {
            if FileManager.default.fileExists(atPath: location.path) {
                return location
            }
        }

        return nil
    }

    // MARK: - BrowserPublishingProtocol

    func checkAuthStatus() async throws -> BrowserAuthStatus {
        guard let nodeBin = Self.resolveNodeBinary() else {
            throw BrowserAutomationError.nodeNotFound
        }
        guard let script = Self.resolveCliScript() else {
            throw BrowserAutomationError.scriptNotFound
        }

        let output = try await runProcess(executableURL: nodeBin, arguments: [script.path, "--check-auth"])

        // Parse JSON output
        for line in output.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String, type == "auth_report",
                  let auth = json["auth"] as? [String: Bool] else {
                continue
            }
            return BrowserAuthStatus(
                tiktok: auth["tiktok"] ?? false,
                instagram: auth["instagram"] ?? false,
                youtube: auth["youtube"] ?? false
            )
        }

        return BrowserAuthStatus()
    }

    func openLoginSession() async throws -> BrowserAuthStatus {
        guard let nodeBin = Self.resolveNodeBinary() else {
            throw BrowserAutomationError.nodeNotFound
        }
        guard let script = Self.resolveCliScript() else {
            throw BrowserAutomationError.scriptNotFound
        }

        Self.logger.notice("Opening interactive browser login session...")
        let output = try await runProcess(executableURL: nodeBin, arguments: [script.path, "--login"])

        for line in output.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String, type == "auth_report",
                  let auth = json["auth"] as? [String: Bool] else {
                continue
            }
            return BrowserAuthStatus(
                tiktok: auth["tiktok"] ?? false,
                instagram: auth["instagram"] ?? false,
                youtube: auth["youtube"] ?? false
            )
        }

        return try await checkAuthStatus()
    }

    func publish(job: BrowserUploadJob) -> AsyncThrowingStream<BrowserPublishEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let nodeBin = Self.resolveNodeBinary() else {
                        throw BrowserAutomationError.nodeNotFound
                    }
                    guard let script = Self.resolveCliScript() else {
                        throw BrowserAutomationError.scriptNotFound
                    }

                    // Write job payload to temp file
                    let tempJobURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("browser-job-\(UUID().uuidString).json")
                    let jobData = try JSONEncoder().encode(job)
                    try jobData.write(to: tempJobURL)
                    defer { try? FileManager.default.removeItem(at: tempJobURL) }

                    let process = Process()
                    process.executableURL = nodeBin
                    process.arguments = [script.path, "--upload", "--job", tempJobURL.path]

                    // Inherit user environment so PATH and libraries match
                    var env = ProcessInfo.processInfo.environment
                    if let nvmPath = Self.resolveNodeBinary()?.deletingLastPathComponent().path {
                        let existingPath = env["PATH"] ?? ""
                        env["PATH"] = "\(nvmPath):\(existingPath)"
                    }
                    process.environment = env

                    let stdoutPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stdoutPipe

                    let handle = stdoutPipe.fileHandleForReading

                    continuation.onTermination = { @Sendable _ in
                        if process.isRunning {
                            process.terminate()
                        }
                    }

                    continuation.yield(.progress(platform: nil, message: "Запуск автоматизации браузера..."))

                    try process.run()

                    var buffer = Data()
                    var lastErrorMessage: String?

                    for try await byteChunk in handle.bytes {
                        if byteChunk == 10 { // Newline '\n'
                            if let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                                if let err = Self.parseLine(line, continuation: continuation) {
                                    lastErrorMessage = err
                                }
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byteChunk)
                        }
                    }

                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                        if let err = Self.parseLine(line, continuation: continuation) {
                            lastErrorMessage = err
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        continuation.finish(throwing: BrowserAutomationError.processFailed(code: process.terminationStatus, message: lastErrorMessage))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Internal Helpers

    private func runProcess(executableURL: URL, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let nvmPath = executableURL.deletingLastPathComponent().path as String? {
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = "\(nvmPath):\(existingPath)"
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private static func parseLine(
        _ line: String,
        continuation: AsyncThrowingStream<BrowserPublishEvent, Error>.Continuation
    ) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            if line.localizedCaseInsensitiveContains("error") || line.localizedCaseInsensitiveContains("failed") {
                continuation.yield(.progress(platform: nil, message: "⚠️ \(line)"))
                return line
            }
            continuation.yield(.progress(platform: nil, message: line))
            return nil
        }

        switch type {
        case "progress":
            let platform = json["platform"] as? String
            let message = json["message"] as? String ?? ""
            continuation.yield(.progress(platform: platform, message: message))
            return nil

        case "captcha_detected":
            let platform = json["platform"] as? String ?? "tiktok"
            let message = json["message"] as? String ?? "Обнаружена капча!"
            continuation.yield(.captchaDetected(platform: platform, message: message))
            return nil

        case "success":
            let platform = json["platform"] as? String ?? ""
            let message = json["message"] as? String ?? "Опубликовано!"
            let url = json["url"] as? String
            continuation.yield(.success(platform: platform, message: message, url: url))
            return nil

        case "error":
            let platform = json["platform"] as? String ?? ""
            let message = json["message"] as? String ?? "Ошибка публикации"
            continuation.yield(.failure(platform: platform, message: message))
            return message

        case "fatal_error":
            let message = json["message"] as? String ?? "Критическая ошибка браузера"
            continuation.yield(.failure(platform: nil, message: message))
            return message

        case "completed":
            var results: [String: String] = [:]
            if let dict = json["results"] as? [String: [String: String]] {
                for (k, v) in dict {
                    results[k] = v["status"] ?? ""
                }
            }
            continuation.yield(.finished(allResults: results))
            return nil

        default:
            return nil
        }
    }
}

// MARK: - Errors

enum BrowserAutomationError: LocalizedError, Sendable {
    case nodeNotFound
    case scriptNotFound
    case processFailed(code: Int32, message: String? = nil)
    case notAuthenticated(String)

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            return "Node.js не найден. Убедитесь, что Node.js установлен на Mac."
        case .scriptNotFound:
            return "Скрипт автоматизации cli.js не найден."
        case .processFailed(let code, let message):
            if let message, !message.isEmpty {
                return message
            }
            return "Процесс автоматизации завершился с кодом ошибки \(code)."
        case .notAuthenticated(let platform):
            return "Требуется вход в аккаунт \(platform)."
        }
    }
}
