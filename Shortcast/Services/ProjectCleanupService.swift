import Foundation

/// Report returned after executing deep clean.
public struct CleanupReport: Sendable, Equatable {
    public let bytesFreed: Int64
    public let filesRemovedCount: Int

    public init(bytesFreed: Int64, filesRemovedCount: Int) {
        self.bytesFreed = bytesFreed
        self.filesRemovedCount = filesRemovedCount
    }

    public var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

/// Interface for project and cache cleanup operations (Interface Segregation & Dependency Inversion).
public protocol ProjectCleanupServiceProtocol: Sendable {
    /// Calculates the total size in bytes of all removable cached and temporary files.
    func calculateRemovableSize(workingDirectory: URL?) async -> Int64

    /// Executes deep cleaning of render cache, temporary video files, orphaned input files,
    /// and Metal/WhisperKit compilation caches.
    func performDeepClean(workingDirectory: URL?) async throws -> CleanupReport
}

/// Service implementing deep project cleanup in accordance with SOLID principles.
public final class ProjectCleanupService: ProjectCleanupServiceProtocol, @unchecked Sendable {

    public static let shared = ProjectCleanupService()

    public init() {}

    // MARK: - Categories of cleanup targets (Open/Closed Principle)

    private struct TargetLocation {
        let url: URL
        let isDirectory: Bool
        let deleteDirectoryItself: Bool
        let patternMatching: ((URL) -> Bool)?
    }

    private func discoverTargets(workingDirectory: URL?) -> [TargetLocation] {
        var targets: [TargetLocation] = []

        // 1. Render cache in working directory
        if let wd = workingDirectory {
            let renderCacheDir = wd.appendingPathComponent("render-cache", isDirectory: true)
            targets.append(TargetLocation(url: renderCacheDir, isDirectory: true, deleteDirectoryItself: false, patternMatching: nil))

            // 2. Input copies in working directory
            let inputDir = wd.appendingPathComponent("input", isDirectory: true)
            targets.append(TargetLocation(url: inputDir, isDirectory: true, deleteDirectoryItself: false, patternMatching: nil))

            // 3. Any intermediate shortcast-* files in working directory root
            targets.append(TargetLocation(url: wd, isDirectory: true, deleteDirectoryItself: false, patternMatching: { url in
                let name = url.lastPathComponent
                return name.hasPrefix("shortcast-") || name.hasPrefix("test_")
            }))
        }

        // 4. Temporary directory intermediate files created by shortcast
        let tempDir = FileManager.default.temporaryDirectory
        targets.append(TargetLocation(url: tempDir, isDirectory: true, deleteDirectoryItself: false, patternMatching: { url in
            let name = url.lastPathComponent
            return (name.hasPrefix("shortcast-") || name.hasPrefix("shortcast_") || name.hasPrefix("test_"))
                && (url.pathExtension.lowercased() == "mp4" || url.pathExtension.lowercased() == "wav" || url.pathExtension.lowercased() == "srt")
        }))

        // 5. WhisperKit Metal e5bundlecache in user Caches directory
        if let userCacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let bundleID = Bundle.main.bundleIdentifier ?? "app.shortcast.Shortcast"
            let e5rtCacheURL = userCacheURL.appendingPathComponent(bundleID).appendingPathComponent("com.apple.e5rt.e5bundlecache")
            targets.append(TargetLocation(url: e5rtCacheURL, isDirectory: true, deleteDirectoryItself: true, patternMatching: nil))
        }

        return targets
    }

    // MARK: - Size calculation

    public func calculateRemovableSize(workingDirectory: URL?) async -> Int64 {
        let targets = discoverTargets(workingDirectory: workingDirectory)
        var totalBytes: Int64 = 0

        let didAccess = workingDirectory?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didAccess {
                workingDirectory?.stopAccessingSecurityScopedResource()
            }
        }

        for target in targets {
            totalBytes += computeTargetSize(target)
        }

        return totalBytes
    }

    private func computeTargetSize(_ target: TargetLocation) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: target.url.path, isDirectory: &isDir) else {
            return 0
        }

        if !isDir.boolValue {
            let values = try? target.url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: target.url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let pattern = target.patternMatching, !pattern(fileURL) {
                continue
            }
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                size += Int64(values.fileSize ?? 0)
            }
        }
        return size
    }

    // MARK: - Deep clean execution

    public func performDeepClean(workingDirectory: URL?) async throws -> CleanupReport {
        let targets = discoverTargets(workingDirectory: workingDirectory)
        var totalBytesFreed: Int64 = 0
        var totalFilesRemoved = 0

        let didAccess = workingDirectory?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didAccess {
                workingDirectory?.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default

        for target in targets {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: target.url.path, isDirectory: &isDir) else {
                continue
            }

            if target.deleteDirectoryItself {
                let size = computeTargetSize(target)
                if (try? fm.removeItem(at: target.url)) != nil {
                    totalBytesFreed += size
                    totalFilesRemoved += 1
                }
            } else if isDir.boolValue {
                guard let contents = try? fm.contentsOfDirectory(
                    at: target.url,
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for fileURL in contents {
                    if let pattern = target.patternMatching, !pattern(fileURL) {
                        continue
                    }
                    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                    let fileSize = Int64(values?.fileSize ?? 0)
                    do {
                        try fm.removeItem(at: fileURL)
                        totalBytesFreed += fileSize
                        totalFilesRemoved += 1
                    } catch {
                        // Continue removing other files even if one is locked
                    }
                }
            }
        }

        return CleanupReport(bytesFreed: totalBytesFreed, filesRemovedCount: totalFilesRemoved)
    }
}
