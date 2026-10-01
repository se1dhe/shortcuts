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
public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    public static let shared = ProcessRunner()

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

        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
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
}
