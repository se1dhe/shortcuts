import Foundation

public struct CleanupReport: Sendable {
    public let bytesFreed: Int64
    public let filesRemovedCount: Int
    public var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

public protocol ProjectCleanupServiceProtocol: Sendable {
    func calculateRemovableSize(workingDirectory: URL?) async -> Int64
    func performDeepClean(workingDirectory: URL?) async throws -> CleanupReport
}

/// Only app-owned disposable caches. Input media, exports, projects, downloaded
/// models and browser login state are never cleanup targets.
public final class ProjectCleanupService: ProjectCleanupServiceProtocol, Sendable {
    public static let shared = ProjectCleanupService()
    private let temporaryDirectory: URL
    private let cachesDirectory: URL?
    private let minimumAge: TimeInterval

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                minimumAge: TimeInterval = 86400) {
        self.temporaryDirectory = temporaryDirectory
        self.cachesDirectory = cachesDirectory
        self.minimumAge = minimumAge
    }

    private func targets(workingDirectory: URL?) -> [URL] {
        var result: [URL] = []
        if let directory = workingDirectory {
            // The old standalone clip renderer's cache; no current project uses it.
            result.append(directory.appendingPathComponent("render-cache", isDirectory: true))
        }
        if let cachesDirectory {
            result.append(cachesDirectory.appendingPathComponent("app.shortcast.Shortcast/com.apple.e5rt.e5bundlecache", isDirectory: true))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        for file in files {
            guard file.lastPathComponent.hasPrefix("shortcast-"),
                  ["mp4", "mov", "wav", "srt", "m4a", "json"].contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, Date().timeIntervalSince(modified) >= minimumAge else { continue }
            result.append(file)
        }
        return result.filter { url in
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
    }

    private func size(_ url: URL) -> (bytes: Int64, files: Int) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return (0, 0) }
        if values.isRegularFile == true { return (Int64(values.fileSize ?? 0), 1) }
        guard values.isDirectory == true else { return (0, 0) }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return contents.reduce((Int64(0), 0)) { total, child in
            let next = size(child)
            return (total.0 + next.bytes, total.1 + next.files)
        }
    }

    public func calculateRemovableSize(workingDirectory: URL?) async -> Int64 {
        let access = workingDirectory?.startAccessingSecurityScopedResource() ?? false
        defer { if access { workingDirectory?.stopAccessingSecurityScopedResource() } }
        return targets(workingDirectory: workingDirectory).reduce(0) { $0 + size($1).bytes }
    }

    public func performDeepClean(workingDirectory: URL?) async throws -> CleanupReport {
        let access = workingDirectory?.startAccessingSecurityScopedResource() ?? false
        defer { if access { workingDirectory?.stopAccessingSecurityScopedResource() } }
        var bytes: Int64 = 0
        var count = 0
        for url in targets(workingDirectory: workingDirectory) where FileManager.default.fileExists(atPath: url.path) {
            let removed = size(url)
            try FileManager.default.removeItem(at: url)
            bytes += removed.bytes; count += removed.files
        }
        return CleanupReport(bytesFreed: bytes, filesRemovedCount: count)
    }
}
