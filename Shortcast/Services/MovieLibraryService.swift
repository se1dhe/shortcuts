import Foundation
import Observation

/// Lifecycle of a library file's container normalization (MKV/WebM/AVI → MP4).
enum NormalizationStatus: Equatable {
    case pending
    case normalizing(progress: Double)
    case ready(normalizedURL: URL)
    case failed(String)
}

/// One video file discovered in the movie library folder.
struct MovieLibraryItem: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var title: String
    var status: NormalizationStatus
    var needsNormalization: Bool

    /// The URL to hand to the pipeline: the normalized file when available,
    /// otherwise the original (already-compatible) container.
    var processableURL: URL? {
        if case .ready(let normalized) = status { return normalized }
        return nil
    }
}

/// Scans a user-chosen folder of local movies, tracks which files still need
/// container normalization, runs that normalization in the background, and
/// watches the folder for changes.
@MainActor
@Observable
final class MovieLibraryService {

    private(set) var movies: [MovieLibraryItem] = []
    private(set) var isScanning = false
    private(set) var libraryURL: URL?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchFD: CInt = -1
    private var isAccessingLibrary = false
    private var activeNormalizations: [URL: Task<Void, Never>] = [:]
    private var reloadWorkItem: DispatchWorkItem?

    private static let videoExtensions: Set<String> = ["mkv", "mp4", "mov", "avi", "webm", "m4v"]

    // MARK: - Scanning

    /// Re-reads the library folder from settings and rebuilds the item list,
    /// preserving the status of files already normalized this session.
    func refresh(settings: AppSettings) {
        guard let url = settings.movieLibraryURL else {
            stopWatching()
            libraryURL = nil
            movies = []
            return
        }
        libraryURL = url

        beginLibraryAccess(url)
        isScanning = true
        defer { isScanning = false }

        let previous = Dictionary(uniqueKeysWithValues: movies.map { ($0.url, $0) })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []

        var found: [MovieLibraryItem] = []
        for fileURL in contents {
            guard Self.videoExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            if let existing = previous[fileURL], existing.status != .pending {
                found.append(existing)
                continue
            }
            let needs = MediaExtractor.needsNormalization(fileURL)
            found.append(MovieLibraryItem(
                url: fileURL,
                title: Self.title(from: fileURL),
                status: needs ? .pending : .ready(normalizedURL: fileURL),
                needsNormalization: needs))
        }
        movies = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        startWatching(url)
    }

    private static func title(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Normalization

    /// Normalizes every file that still needs it (MKV/WebM/AVI → MP4), two at a time.
    func normalizeAll(settings: AppSettings) {
        for item in movies where item.needsNormalization && item.status == .pending {
            normalize(item, settings: settings)
        }
    }

    /// Normalizes a single item in the background via `MediaExtractor`.
    func normalize(_ item: MovieLibraryItem, settings: AppSettings) {
        guard item.needsNormalization else { return }
        guard activeNormalizations[item.url] == nil else { return }
        guard let workingDirectory = settings.workingDirectory else {
            updateStatus(for: item.url, .failed("Рабочая папка не задана в Настройках."))
            return
        }

        updateStatus(for: item.url, .normalizing(progress: 0))
        let sourceURL = item.url
        let task = Task { [weak self] in
            let beginAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if beginAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let normalized = try await MediaExtractor.normalizeInputIfNeeded(
                    from: sourceURL,
                    workingDirectory: workingDirectory)
                await MainActor.run {
                    self?.updateStatus(for: sourceURL, .ready(normalizedURL: normalized))
                    self?.activeNormalizations[sourceURL] = nil
                }
            } catch {
                await MainActor.run {
                    self?.updateStatus(for: sourceURL, .failed(error.localizedDescription))
                    self?.activeNormalizations[sourceURL] = nil
                }
            }
        }
        activeNormalizations[item.url] = task
    }

    private func updateStatus(for url: URL, _ status: NormalizationStatus) {
        guard let index = movies.firstIndex(where: { $0.url == url }) else { return }
        movies[index].status = status
    }

    // MARK: - Folder watching

    private func beginLibraryAccess(_ url: URL) {
        if isAccessingLibrary { return }
        isAccessingLibrary = url.startAccessingSecurityScopedResource()
    }

    private func startWatching(_ url: URL) {
        stopWatching()
        watchFD = open(url.path(percentEncoded: false), O_EVTONLY)
        guard watchFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.watchFD >= 0 else { return }
            close(self.watchFD)
            self.watchFD = -1
        }
        watcher = source
        source.resume()
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-resolve from settings-free state: reuse the last known URL.
            guard let url = self.libraryURL else { return }
            let previous = Dictionary(uniqueKeysWithValues: self.movies.map { ($0.url, $0) })
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            var found: [MovieLibraryItem] = []
            for fileURL in contents {
                guard Self.videoExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                if let existing = previous[fileURL], existing.status != .pending {
                    found.append(existing)
                    continue
                }
                let needs = MediaExtractor.needsNormalization(fileURL)
                found.append(MovieLibraryItem(
                    url: fileURL,
                    title: Self.title(from: fileURL),
                    status: needs ? .pending : .ready(normalizedURL: fileURL),
                    needsNormalization: needs))
            }
            self.movies = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func stopWatching() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        watcher?.cancel()
        watcher = nil
        // watchFD is closed in the cancel handler.
    }
}
