import Foundation

/// Persistent cache for a rendered Short. It prevents an unchanged video from
/// being encoded again when the user previews, downloads and then publishes it.
enum RenderedVideoCache {

    static func fileURL(for key: String, workingDirectory: URL?) -> URL? {
        guard let workingDirectory else { return nil }
        let directory = workingDirectory.appendingPathComponent("render-cache", isDirectory: true)
        return directory.appendingPathComponent("\(key).mp4")
    }

    static func existingFile(for key: String, workingDirectory: URL?) -> URL? {
        guard let url = fileURL(for: key, workingDirectory: workingDirectory),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 1_024
        else { return nil }
        return url
    }

    static func store(_ source: URL, key: String, workingDirectory: URL?) throws -> URL? {
        guard let destination = fileURL(for: key, workingDirectory: workingDirectory) else { return nil }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        prune(in: directory)
        return destination
    }

    /// Completely removes the render-cache directory.
    static func clearAll(workingDirectory: URL?) {
        guard let workingDirectory else { return }
        let directory = workingDirectory.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Keep the cache bounded: a recent set of renders is useful for immediate
    /// export/publish retries, while unbounded video files quietly consume disk.
    private static func prune(in directory: URL, maximumFiles: Int = 24) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        let cachedVideos = files.filter {
            $0.pathExtension.lowercased() == "mp4"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard cachedVideos.count > maximumFiles else { return }
        let oldestFirst = cachedVideos.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        for url in oldestFirst.prefix(cachedVideos.count - maximumFiles) {
            try? manager.removeItem(at: url)
        }
    }

    /// Stable lightweight hash; it is only a cache key, not a security digest.
    static func key(for payload: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in payload.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
