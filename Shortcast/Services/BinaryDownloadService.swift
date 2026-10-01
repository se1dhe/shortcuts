import Foundation

enum BinaryDownloadError: LocalizedError {
    case missingWorkingDirectory
    case downloadFailed(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWorkingDirectory:
            return String(localized: "No working directory set. Choose one in Settings first.")
        case .downloadFailed(let detail):
            return String(localized: "Download failed: \(detail)")
        case .extractionFailed(let detail):
            return String(localized: "Extraction failed: \(detail)")
        }
    }
}

/// Manages CLI binaries inside `<workingDirectory>/bin`.
/// Downloads them on demand from verified upstream URLs if they are missing
/// locally and not on the system PATH.
enum BinaryDownloadService {

    // MARK: - Upstream URLs

    private static let ffmpegURL = URL(
        string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64"
    )!
    private static let ffprobeURL = URL(
        string: "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64"
    )!
    private static let rifeURL = URL(
        string: "https://github.com/nihui/rife-ncnn-vulkan/releases/download/20221029/rife-ncnn-vulkan-20221029-macos.zip"
    )!
    private static let realsrURL = URL(
        string: "https://github.com/nihui/realsr-ncnn-vulkan/releases/download/20220728/realsr-ncnn-vulkan-20220728-macos.zip"
    )!

    // MARK: - Binary descriptor

    enum Binary: String, Sendable, CaseIterable {
        case ffmpeg
        case ffprobe
        case rife
        case realsr

        var executableName: String {
            switch self {
            case .ffmpeg:  return "ffmpeg"
            case .ffprobe: return "ffprobe"
            case .rife:    return "rife-ncnn-vulkan"
            case .realsr:  return "realsr-ncnn-vulkan"
            }
        }

        var relativePath: String {
            switch self {
            case .ffmpeg:  return "ffmpeg"
            case .ffprobe: return "ffprobe"
            case .rife:    return "rife-ncnn-vulkan/rife-ncnn-vulkan"
            case .realsr:  return "realsr-ncnn-vulkan/realsr-ncnn-vulkan"
            }
        }
    }

    // MARK: - Public API

    /// Looks for a binary: first in `<workingDirectory>/bin`, then in PATH.
    static func resolveBinary(_ relativePath: String, workingDirectory: URL?) -> URL? {
        if let local = resolveInWorkingDirectory(relativePath, workingDirectory: workingDirectory) {
            return local
        }
        return findExecutableInPATH((relativePath as NSString).lastPathComponent)
    }

    /// Ensures the requested binary exists, downloading it if necessary.
    static func ensureAvailable(
        _ binary: Binary,
        workingDirectory: URL?
    ) async throws -> URL {
        if let existing = resolveBinary(binary.relativePath, workingDirectory: workingDirectory) {
            return existing
        }

        guard let wd = workingDirectory else {
            throw BinaryDownloadError.missingWorkingDirectory
        }

        let bin = wd.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        Self.log("\(binary.rawValue) not found — downloading…")
        switch binary {
        case .ffmpeg:
            return try await installRawBinary(from: ffmpegURL, to: bin, name: "ffmpeg")
        case .ffprobe:
            return try await installRawBinary(from: ffprobeURL, to: bin, name: "ffprobe")
        case .rife:
            return try await installRIFE(to: bin)
        case .realsr:
            return try await installRealSR(to: bin)
        }
    }

    // MARK: - Resolvers

    private static func resolveInWorkingDirectory(
        _ relativePath: String,
        workingDirectory: URL?
    ) -> URL? {
        guard let wd = workingDirectory else { return nil }
        let url = wd.appendingPathComponent("bin").appendingPathComponent(relativePath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func findExecutableInPATH(_ name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Installers

    private static func installRawBinary(from url: URL, to bin: URL, name: String) async throws -> URL {
        let temp = bin.appendingPathComponent("\(name)-download")
        try await downloadFile(from: url, to: temp)
        let dest = bin.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        try makeExecutable(dest)
        Self.log("\(name) installed → \(dest.path)")
        return dest
    }

    private static func installRIFE(to bin: URL) async throws -> URL {
        let zipFile = bin.appendingPathComponent("rife-download.zip")
        let extractDir = bin.appendingPathComponent("rife-ncnn-vulkan")
        try await downloadFile(from: rifeURL, to: zipFile)
        try await unzip(zipFile, into: bin)
        let extracted = bin.appendingPathComponent("rife-ncnn-vulkan-20221029-macos")
        if FileManager.default.fileExists(atPath: extractDir.path) {
            try? FileManager.default.removeItem(at: extractDir)
        }
        try FileManager.default.moveItem(at: extracted, to: extractDir)
        try? FileManager.default.removeItem(at: zipFile)
        let binary = extractDir.appendingPathComponent("rife-ncnn-vulkan")
        try makeExecutable(binary)
        Self.log("rife-ncnn-vulkan installed → \(binary.path)")
        return binary
    }

    private static func installRealSR(to bin: URL) async throws -> URL {
        let zipFile = bin.appendingPathComponent("realsr-download.zip")
        let extractDir = bin.appendingPathComponent("realsr-ncnn-vulkan")
        try await downloadFile(from: realsrURL, to: zipFile)
        try await unzip(zipFile, into: bin)
        let extracted = bin.appendingPathComponent("realsr-ncnn-vulkan-20220728-macos")
        if FileManager.default.fileExists(atPath: extractDir.path) {
            try? FileManager.default.removeItem(at: extractDir)
        }
        try FileManager.default.moveItem(at: extracted, to: extractDir)
        try? FileManager.default.removeItem(at: zipFile)
        let binary = extractDir.appendingPathComponent("realsr-ncnn-vulkan")
        try makeExecutable(binary)
        Self.log("realsr-ncnn-vulkan installed → \(binary.path)")
        return binary
    }

    // MARK: - Helpers

    private static func downloadFile(from url: URL, to destination: URL) async throws {
        let request = URLRequest(url: url)
        let (tmpURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BinaryDownloadError.downloadFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }

    private static func unzip(_ zipFile: URL, into directory: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", "-q", zipFile.path, "-d", directory.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw BinaryDownloadError.extractionFailed(
                "unzip exited with \(task.terminationStatus)")
        }
    }

    private static func makeExecutable(_ url: URL) throws {
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/binary] \(message)\n".utf8))
    }
}
