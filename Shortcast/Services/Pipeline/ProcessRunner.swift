import Foundation

/// Protocol for safely executing command-line processes (DIP/SRP).
public protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public var isSuccess: Bool { exitCode == 0 }
}

public enum ProcessRunnerError: LocalizedError, Sendable {
    case executionFailed(exitCode: Int32, errorOutput: String)
    case processNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .executionFailed(let code, let error):
            return "Command failed with exit code \(code): \(error)"
        case .processNotFound(let url):
            return "Executable not found at path: \(url.path)"
        }
    }
}

/// Thread-safe process executor that prevents UNIX Pipe deadlocks by reading streams concurrently.
///
/// Captured stdout/stderr are capped. Long ffmpeg encodes can emit gigabytes of
/// stats on a pipe; buffering that in the parent process is what ballooned RAM.
public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    public static let shared = ProcessRunner()

    /// Enough for ffprobe JSON; anything larger is discarded from the head.
    private static let maxStdoutBytes = 2 * 1024 * 1024
    /// Keep the tail so the actual ffmpeg error line survives.
    private static let maxStderrBytes = 256 * 1024

    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessRunnerError.processNotFound(executableURL)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment = environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutLimit = Self.maxStdoutBytes
        let stderrLimit = Self.maxStderrBytes
        let stdoutTask = Task.detached {
            Self.collect(handle: stdoutPipe.fileHandleForReading, limit: stdoutLimit, keepTail: false)
        }
        let stderrTask = Task.detached {
            Self.collect(handle: stderrPipe.fileHandleForReading, limit: stderrLimit, keepTail: true)
        }

        try process.run()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let outData = await stdoutTask.value
        let errData = await stderrTask.value

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        let result = ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: outStr,
            standardError: errStr
        )

        if process.terminationStatus == 0 {
            return result
        } else {
            throw ProcessRunnerError.executionFailed(
                exitCode: process.terminationStatus,
                errorOutput: errStr.isEmpty ? outStr : errStr
            )
        }
    }

    private static func collect(handle: FileHandle, limit: Int, keepTail: Bool) -> Data {
        var buffer = Data()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            if keepTail {
                buffer.append(chunk)
                if buffer.count > limit {
                    buffer = Data(buffer.suffix(limit))
                }
            } else if buffer.count < limit {
                let remaining = limit - buffer.count
                buffer.append(chunk.prefix(remaining))
            }
        }
        return buffer
    }
}
