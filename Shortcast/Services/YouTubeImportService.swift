import Foundation
import Darwin

struct YouTubeDownloadProgress: Sendable, Equatable {
    let downloadedBytes: Int64

    var label: String {
        "Downloading video… \(ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file))"
    }
}

struct YouTubeSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let channel: String
    let durationSeconds: Double
    let uploadDate: String?
    let webpageURL: URL

    var metadata: String {
        [channel, durationLabel, uploadDateLabel]
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var durationLabel: String {
        let total = Int(durationSeconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var uploadDateLabel: String {
        guard let uploadDate, uploadDate.count == 8 else {
            return String(localized: "Unknown date")
        }
        let year = uploadDate.prefix(4)
        let month = uploadDate.dropFirst(4).prefix(2)
        let day = uploadDate.suffix(2)
        return "\(year)-\(month)-\(day)"
    }

    var sourceMetadata: VideoSourceMetadata {
        VideoSourceMetadata(title: title, description: description, webpageURL: webpageURL)
    }
}

    enum YouTubeImportError: LocalizedError {
        case ytDLPNotFound
        case invalidQuery
        case invalidURL
        case noResults
        case commandFailed(String)
        case downloadedFileMissing
        case downloadedFileMissingDetails(String)
        case noLongResults(minimumMinutes: Int, maximumMinutes: Int)
        case invalidStreamURL
        case cancelled

        var errorDescription: String? {
            switch self {
            case .ytDLPNotFound:
                String(localized: "yt-dlp is not installed. Install it with Homebrew: brew install yt-dlp")
            case .invalidQuery:
                String(localized: "Enter a YouTube search query first.")
            case .invalidURL:
                String(localized: "Enter a direct video URL first.")
            case .noResults:
                String(localized: "No YouTube results found for that query.")
            case .commandFailed(let output):
                output.trimmed.isEmpty ? String(localized: "yt-dlp failed.") : output.trimmed
            case .downloadedFileMissing:
                String(localized: "The video finished downloading, but the output file could not be found.")
            case .downloadedFileMissingDetails(let detail):
                String(localized: "The video finished downloading, but the output file could not be found. \(detail)")
            case .noLongResults(let minimumMinutes, let maximumMinutes):
                String(localized: "No YouTube videos between \(minimumMinutes) and \(maximumMinutes) minutes found for that query.")
            case .invalidStreamURL:
                String(localized: "Could not get video stream URL.")
            case .cancelled:
                String(localized: "Download cancelled.")
            }
        }
    }

actor YouTubeImportService {
    private let fileManager = FileManager.default
    private let searchTimeoutSeconds: TimeInterval = 20

    /// Path to a cookies.txt file in Netscape format, exported from a browser.
    /// When non-empty and pointing to an existing file, `--cookies <path>` is
    /// added to every yt-dlp invocation so age-restricted videos work.
    /// Set this from the view layer before calling download/streamURL methods.
    var cookiesPath: String = ""

    func setCookiesPath(_ path: String) {
        self.cookiesPath = path
    }

    private var activeDownloadPID: Int32?
    private var downloadWasCancelled = false

    /// Stops the currently-running yt-dlp download, if any. Search/metadata
    /// requests are short-lived and deliberately unaffected.
    func cancelDownload() {
        guard let activeDownloadPID else { return }
        downloadWasCancelled = true
        kill(activeDownloadPID, SIGTERM)
    }

    func search(query: String, limit: Int = 8, minDurationMinutes: Int = 30, maxDurationMinutes: Int = 120) async throws -> [YouTubeSearchResult] {
        let cleanQuery = query.trimmed
        guard !cleanQuery.isEmpty else { throw YouTubeImportError.invalidQuery }

        let minimumDurationSeconds = minDurationMinutes * 60
        let maximumDurationSeconds = maxDurationMinutes * 60

        // Ask for more candidates than we show because short videos are common
        // in Lineage 2 searches and are filtered out below.
        let probeLimit = max(limit * 4, 24)
        let output = try await runYTDLP(arguments: [
            "ytsearch\(probeLimit):\(cleanQuery)",
            "--flat-playlist",
            "--print", "%(id)s\t%(title)s\t%(channel|)s\t%(duration_string|)s\t%(duration|0)s\t%(upload_date|)s\t%(webpage_url)s",
            "--socket-timeout", "8",
        ])

        let candidates = output
            .split(whereSeparator: \.isNewline)
            .compactMap { YouTubeVideoMetadata(flatLine: String($0)) }
            .filter {
                $0.durationSeconds >= Double(minimumDurationSeconds)
                && $0.durationSeconds <= Double(maximumDurationSeconds)
            }
            .sorted { lhs, rhs in
                (lhs.uploadDate ?? "") > (rhs.uploadDate ?? "")
            }
            .prefix(limit)

        let enriched = try await enrichMissingDates(Array(candidates))
        let results = enriched
            .sorted { lhs, rhs in
                (lhs.uploadDate ?? "") > (rhs.uploadDate ?? "")
            }
            .compactMap(\.searchResult)

        guard !results.isEmpty else {
            throw YouTubeImportError.noLongResults(
                minimumMinutes: minimumDurationSeconds / 60,
                maximumMinutes: maximumDurationSeconds / 60)
        }
        return results
    }

    func searchMovieClips(limit: Int = 10, excludedIDs: Set<String> = []) async throws -> [YouTubeSearchResult] {
        let queries = [
            "нарезка из фильма shorts",
            "фильм нарезка shorts",
            "сцены из фильмов shorts",
            "русские шортсы фильмы",
            "movie clips shorts russian"
        ]

        var allResults: [YouTubeSearchResult] = []
        let perQueryLimit = max(limit * 3, 24)

        for query in queries.shuffled() {
            let output = try await runYTDLP(arguments: [
                "ytsearch\(perQueryLimit):\(query)",
                "--flat-playlist",
                "--print", "%(id)s\t%(title)s\t%(channel|)s\t%(duration_string|)s\t%(duration|0)s\t%(upload_date|)s\t%(webpage_url)s\t%(original_url)s",
                "--socket-timeout", "8",
            ])

            let candidates = output
                .split(whereSeparator: \.isNewline)
                .compactMap { YouTubeVideoMetadata(flatLine: String($0)) }
                .filter {
                    guard let id = $0.id?.trimmed, !id.isEmpty else { return false }
                    return !excludedIDs.contains(id)
                }
                .filter {
                    let urlString = $0.webpageURL?.trimmed ?? ""
                    let original = $0.originalURL?.trimmed ?? ""
                    return urlString.contains("/shorts/") || original.contains("/shorts/")
                }
                .filter { ($0.duration ?? 0) <= 60 }
                .compactMap(\.searchResult)

            allResults.append(contentsOf: candidates)

            // Deduplicate by ID and trim to limit
            var seen = Set<String>()
            allResults = allResults.filter { seen.insert($0.id).inserted }
            if allResults.count >= limit { break }
        }

        return Array(allResults.prefix(limit))
    }

    private func enrichMissingDates(_ videos: [YouTubeVideoMetadata]) async throws -> [YouTubeVideoMetadata] {
        var enriched: [YouTubeVideoMetadata] = []
        for video in videos {
            guard video.uploadDate?.trimmed.isEmpty != false,
                  let url = video.searchResult?.webpageURL.absoluteString
            else {
                enriched.append(video)
                continue
            }

            do {
                let output = try await runYTDLP(arguments: [
                    url,
                    "--skip-download",
                    "--print", "%(upload_date|)s",
                    "--socket-timeout", "6",
                ], timeout: 8)
                enriched.append(video.withUploadDate(output.trimmed))
            } catch {
                enriched.append(video)
            }
        }
        return enriched
    }

    func download(
        _ result: YouTubeSearchResult,
        outputDirectory: URL? = nil,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void = { _ in }
    ) async throws -> URL {
        try await download(urlString: result.webpageURL.absoluteString,
                           outputDirectory: outputDirectory, progress: progress)
    }

    func sourceMetadata(for result: YouTubeSearchResult) async -> VideoSourceMetadata {
        let fetched = try? await fetchSourceMetadata(urlString: result.webpageURL.absoluteString)
        return VideoSourceMetadata(
            title: fetched?.title.trimmed.isEmpty == false ? fetched!.title : result.title,
            description: fetched?.description.trimmed.isEmpty == false ? fetched!.description : result.description,
            webpageURL: result.webpageURL)
    }

    func sourceMetadata(forDirectURL urlString: String) async -> VideoSourceMetadata {
        let fetched = try? await fetchSourceMetadata(urlString: urlString)
        return VideoSourceMetadata(
            title: fetched?.title ?? "",
            description: fetched?.description ?? "",
            webpageURL: URL(string: urlString))
    }

    /// Downloads the video at `urlString` and returns both the local file URL
    /// and the source metadata (title + description) extracted from the
    /// `.info.json` that yt-dlp writes alongside the video. This avoids
    /// launching a separate yt-dlp process for metadata, which can race with
    /// the download process on the same actor.
    func downloadDirectURLWithMetadata(
        _ urlString: String,
        outputDirectory: URL? = nil,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void = { _ in }
    ) async throws -> (URL, VideoSourceMetadata) {
        let cleanURL = urlString.trimmed
        guard let url = URL(string: cleanURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.trimmed.isEmpty == false
        else {
            throw YouTubeImportError.invalidURL
        }

        let (fileURL, infoJSONURL) = try await downloadWritingInfoJSON(
            urlString: cleanURL, outputDirectory: outputDirectory, progress: progress)
        let metadata = readInfoJSON(at: infoJSONURL, fallbackURLString: cleanURL)
        return (fileURL, metadata)
    }

    /// Returns a direct streaming URL for the video (best ≤720p).
    /// The URL can be fed to AVPlayer for in-app playback without full download.
    func streamURL(for result: YouTubeSearchResult) async throws -> URL {
        var streamArgs: [String] = [
            result.webpageURL.absoluteString,
            "-g",
            "-f", "best[height<=720]",
            "--no-playlist",
            "--socket-timeout", "8",
        ]
        if !cookiesPath.trimmed.isEmpty,
           fileManager.fileExists(atPath: cookiesPath.trimmed) {
            streamArgs.append(contentsOf: ["--cookies", cookiesPath.trimmed])
        }
        let output = try await runYTDLP(arguments: streamArgs, timeout: 15)
        let trimmed = output.trimmed
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            throw YouTubeImportError.invalidStreamURL
        }
        return url
    }

    func downloadDirectURL(
        _ urlString: String,
        outputDirectory: URL? = nil,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void = { _ in }
    ) async throws -> URL {
        let cleanURL = urlString.trimmed
        guard let url = URL(string: cleanURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.trimmed.isEmpty == false
        else {
            throw YouTubeImportError.invalidURL
        }

        return try await download(urlString: cleanURL, outputDirectory: outputDirectory, progress: progress)
    }

    private func download(
        urlString: String,
        outputDirectory: URL? = nil,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void
    ) async throws -> URL {
        let (fileURL, _) = try await downloadWritingInfoJSON(
            urlString: urlString, outputDirectory: outputDirectory, progress: progress)
        return fileURL
    }

    /// Core download implementation. Passes `--write-info-json` so yt-dlp writes
    /// `video.info.json` alongside the video. Returns both the video URL and the
    /// path to the info JSON (which may or may not exist if yt-dlp skipped it).
    private func downloadWritingInfoJSON(
        urlString: String,
        outputDirectory: URL? = nil,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void
    ) async throws -> (URL, URL?) {
        downloadWasCancelled = false
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("ShortGenerator-YouTube", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let outputPath = tempDir.appendingPathComponent("video.mp4").path
        let diagPath = tempDir.appendingPathComponent("_ytdlp_out.txt").path

        var args: [String] = [
            urlString,
            "--no-playlist",
            // Prefer an H.264/mp4 stream (capped at 1080p) so the download merges
            // cleanly AND the H.264 recode step below is almost always skipped —
            // shorts are vertical, so 1080 is plenty and downloads faster.
            "-f", "bv*[ext=mp4][vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*+ba/b",
            // Among matching formats, pick the highest-quality variant: highest
            // resolution (≤1080), then fps, then bitrate, then best audio.
            "-S", "res:1080,fps,vbr,abr",
            "--merge-output-format", "mp4",
            "--concurrent-fragments", "8",
            "--no-progress",
            // Write video metadata (title, description, webpage_url) to a JSON
            // sidecar so we can extract it without a second yt-dlp invocation.
            "--write-info-json",
            "-o", outputPath,
        ]
        // Use a cookies.txt file if the user configured one (for age-restricted
        // videos). Browser cookie extraction via --cookies-from-browser doesn't
        // work from within a macOS app due to sandbox / TCC restrictions.
        if !cookiesPath.trimmed.isEmpty,
           fileManager.fileExists(atPath: cookiesPath.trimmed) {
            args.append(contentsOf: ["--cookies", cookiesPath.trimmed])
        }

        let exitCode = try await runYTDLPWithFiles(
            arguments: args,
            stdoutPath: diagPath,
            timeout: 300,
            progressDirectory: tempDir,
            progress: progress
        )

        if downloadWasCancelled {
            downloadWasCancelled = false
            throw YouTubeImportError.cancelled
        }

        let fileURL = tempDir.appendingPathComponent("video.mp4")
        guard exitCode == 0,
              fileManager.fileExists(atPath: fileURL.path),
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 1024
        else {
            let details = directoryContentsDescription(tempDir)
            let diag = (try? String(contentsOfFile: diagPath, encoding: .utf8)) ?? "(no diag)"
            throw YouTubeImportError.downloadedFileMissingDetails(
                "exit \(exitCode), \(details), output: \(diag)"
            )
        }

        try await recodeToH264IfNeeded(src: fileURL)

        // Locate the info JSON written by yt-dlp ("video.info.json").
        let infoJSONInTemp = tempDir.appendingPathComponent("video.info.json")
        let infoJSONExists = fileManager.fileExists(atPath: infoJSONInTemp.path)

        guard let outputDirectory else {
            return (fileURL, infoJSONExists ? infoJSONInTemp : nil)
        }

        let destDir = outputDirectory
            .appendingPathComponent("ShortGenerator-YouTube", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        let destURL = destDir.appendingPathComponent(fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.moveItem(at: fileURL, to: destURL)

        // Move info JSON alongside the video if present.
        var destInfoJSON: URL? = nil
        if infoJSONExists {
            let destInfo = destDir.appendingPathComponent("video.info.json")
            try? fileManager.moveItem(at: infoJSONInTemp, to: destInfo)
            destInfoJSON = destInfo
        }
        return (destURL, destInfoJSON)
    }

    /// Parses the `.info.json` file written by yt-dlp and returns a
    /// `VideoSourceMetadata`. Falls back to an empty metadata if the file is
    /// missing or unreadable.
    private func readInfoJSON(at url: URL?, fallbackURLString: String) -> VideoSourceMetadata {
        guard let url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(YouTubeSourceMetadata.self, from: data)
        else {
            return VideoSourceMetadata(
                title: "", description: "",
                webpageURL: URL(string: fallbackURLString))
        }
        return VideoSourceMetadata(
            title: json.title?.trimmed ?? "",
            description: json.description?.trimmed ?? "",
            webpageURL: URL(string: json.webpageURL?.trimmed ?? "") ?? URL(string: fallbackURLString))
    }

    private func resolveDownloadedFile(output: String, directory: URL) throws -> URL {
        let printedPaths = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }

        for path in printedPaths {
            let url = URL(fileURLWithPath: path)
            if isUsableVideoFile(url) {
                return url
            }
        }

        if let video = newestDownloadedVideo(in: directory) {
            return video
        }

        let details = directoryContentsDescription(directory)
            + " | yt-dlp output: \(printedPaths.first ?? "(empty)")"
        throw YouTubeImportError.downloadedFileMissingDetails(details)
    }

    private func recodeToH264IfNeeded(src: URL) async throws {
        guard let ffmpeg = findExecutable("ffmpeg") else { return }
        guard let ffprobe = findExecutable("ffprobe") else { return }

        let codec = try? await runProcess(executable: ffprobe, arguments: [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            src.path,
        ], timeout: 10).trimmed.lowercased()

        if codec == "h264" || codec == "avc1" { return }

        let tmpURL = src.deletingLastPathComponent()
            .appendingPathComponent(src.deletingPathExtension().lastPathComponent + "_recoded.mp4")

        // Quality-first recode (only runs for non-H.264 sources like VP9/AV1).
        // `slow` + CRF 18 is near-visually-lossless; High profile + yuv420p keeps
        // it universally playable (TikTok, QuickTime, browsers).
        _ = try await runProcess(executable: ffmpeg, arguments: [
            "-i", src.path,
            "-c:v", "libx264",
            "-preset", "slow",
            "-crf", "18",
            "-profile:v", "high",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-y",
            tmpURL.path,
        ], timeout: 600)

        guard FileManager.default.fileExists(atPath: tmpURL.path) else { return }
        try FileManager.default.removeItem(at: src)
        try FileManager.default.moveItem(at: tmpURL, to: src)
    }

    private func fetchSourceMetadata(urlString: String) async throws -> VideoSourceMetadata {
        var metaArgs: [String] = [
            urlString,
            "--no-playlist",
            "--skip-download",
            "--dump-single-json",
            "--socket-timeout", "8",
        ]
        if !cookiesPath.trimmed.isEmpty,
           fileManager.fileExists(atPath: cookiesPath.trimmed) {
            metaArgs.append(contentsOf: ["--cookies", cookiesPath.trimmed])
        }
        let output = try await runYTDLP(arguments: metaArgs, timeout: 20)

        guard let data = output.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(YouTubeSourceMetadata.self, from: data) else {
            return VideoSourceMetadata(title: "", description: "", webpageURL: URL(string: urlString))
        }
        return VideoSourceMetadata(
            title: metadata.title?.trimmed ?? "",
            description: metadata.description?.trimmed ?? "",
            webpageURL: URL(string: metadata.webpageURL?.trimmed ?? "") ?? URL(string: urlString))
    }

    private func newestDownloadedVideo(in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        return enumerator
            .compactMap { $0 as? URL }
            .filter(isUsableVideoFile)
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }

    private func isUsableVideoFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("._") else { return false }
        guard ["mp4", "mov", "m4v", "webm", "mkv"].contains(url.pathExtension.lowercased()) else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 1024
    }

    private func directoryContentsDescription(_ directory: URL) -> String {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return String(localized: "Download folder: \(directory.path)")
        }
        let files = enumerator
            .compactMap { $0 as? URL }
            .prefix(12)
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return "\(url.lastPathComponent) (\(size) bytes)"
            }
            .joined(separator: ", ")
        return files.isEmpty
            ? String(localized: "Download folder is empty: \(directory.path)")
            : String(localized: "Found: \(files)")
    }

    private func findYTDLP() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw YouTubeImportError.ytDLPNotFound
    }

    private func findExecutable(_ name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func runYTDLP(arguments: [String], timeout: TimeInterval? = nil) async throws -> String {
        let executable = try findYTDLP()
        var fullArguments = ["--no-warnings"]
        if let deno = findExecutable("deno") {
            fullArguments.append(contentsOf: ["--js-runtimes", "deno:\(deno.path)"])
        }
        if let ffmpeg = findExecutable("ffmpeg") {
            fullArguments.append(contentsOf: ["--ffmpeg-location", ffmpeg.path])
        }
        fullArguments.append(contentsOf: arguments)
        return try await runProcess(executable: executable, arguments: fullArguments, timeout: timeout ?? searchTimeoutSeconds)
    }

    private func runYTDLPWithFiles(
        arguments: [String],
        stdoutPath: String,
        timeout: TimeInterval? = nil,
        progressDirectory: URL,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void
    ) async throws -> Int32 {
        let executable = try findYTDLP()
        var fullArguments = ["--no-warnings"]
        if let deno = findExecutable("deno") {
            fullArguments.append(contentsOf: ["--js-runtimes", "deno:\(deno.path)"])
        }
        if let ffmpeg = findExecutable("ffmpeg") {
            fullArguments.append(contentsOf: ["--ffmpeg-location", ffmpeg.path])
        }
        fullArguments.append(contentsOf: arguments)
        return try await runProcessWithFiles(
            executable: executable, arguments: fullArguments, stdoutPath: stdoutPath,
            timeout: timeout ?? searchTimeoutSeconds, progressDirectory: progressDirectory,
            progress: progress)
    }

    private func runProcessWithFiles(
        executable: URL,
        arguments: [String],
        stdoutPath: String,
        timeout: TimeInterval? = nil,
        progressDirectory: URL,
        progress: @escaping @Sendable (YouTubeDownloadProgress) async -> Void
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            let existingPath = environment["PATH"] ?? ""
            let commonPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/opt/homebrew/sbin",
                "/usr/local/sbin",
                "/usr/sbin",
                "/sbin",
            ]
            let existingComponents = existingPath.split(separator: ":").map(String.init)
            let missingPaths = commonPaths.filter { !existingComponents.contains($0) }
            environment["PATH"] = (existingComponents + missingPaths).joined(separator: ":")
            process.environment = environment

            FileManager.default.createFile(atPath: stdoutPath, contents: nil)
            let outHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
            process.standardOutput = outHandle
            process.standardError = outHandle

            try process.run()
            await self.setActiveDownloadPID(process.processIdentifier)
            defer { Task { await self.setActiveDownloadPID(nil) } }
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            var lastReportedBytes: Int64 = -1
            while process.isRunning {
                if let deadline, Date() >= deadline {
                    process.terminate()
                    try? outHandle.close()
                    return process.terminationStatus
                }
                let downloadedBytes = Self.downloadedBytes(in: progressDirectory)
                if downloadedBytes != lastReportedBytes {
                    lastReportedBytes = downloadedBytes
                    await progress(YouTubeDownloadProgress(downloadedBytes: downloadedBytes))
                }
                try await Task.sleep(for: .milliseconds(50))
            }

            try? outHandle.close()
            return process.terminationStatus
        }.value
    }

    private func setActiveDownloadPID(_ pid: Int32?) {
        activeDownloadPID = pid
    }

    nonisolated private static func downloadedBytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) { total, url in
            guard url.lastPathComponent != "_ytdlp_out.txt",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return total }
            return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func runProcess(executable: URL, arguments: [String], timeout: TimeInterval? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            let existingPath = environment["PATH"] ?? ""
            let commonPaths = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/opt/homebrew/sbin",
                "/usr/local/sbin",
                "/usr/sbin",
                "/sbin",
            ]
            let existingComponents = existingPath.split(separator: ":").map(String.init)
            let missingPaths = commonPaths.filter { !existingComponents.contains($0) }
            environment["PATH"] = (existingComponents + missingPaths).joined(separator: ":")
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while process.isRunning {
                if let deadline, Date() >= deadline {
                    process.terminate()
                    throw YouTubeImportError.commandFailed(String(localized: "YouTube search timed out. Try a more specific query."))
                }
                try await Task.sleep(for: .milliseconds(50))
            }

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw YouTubeImportError.commandFailed(errorOutput.isEmpty ? output : errorOutput)
            }
            return output
        }.value
    }
}

private struct YouTubeSourceMetadata: Decodable {
    let title: String?
    let description: String?
    let webpageURL: String?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case webpageURL = "webpage_url"
    }
}

private struct YouTubeVideoMetadata: Decodable {
    let id: String?
    let title: String?
    let channel: String?
    let uploader: String?
    let duration: Double?
    let uploadDate: String?
    let webpageURL: String?
    let originalURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case channel
        case uploader
        case duration
        case uploadDate = "upload_date"
        case webpageURL = "webpage_url"
        case originalURL = "original_url"
    }

    init?(flatLine line: String) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 8,
              !fields[0].trimmed.isEmpty,
              !fields[1].trimmed.isEmpty
        else { return nil }

        id = fields[0].trimmed
        title = fields[1].trimmed
        channel = fields[2].trimmed
        uploader = nil
        duration = Double(fields[4].trimmed) ?? Self.durationSeconds(from: fields[3])
        uploadDate = fields[5].trimmed.isEmpty ? nil : fields[5].trimmed
        webpageURL = fields[6].trimmed
        originalURL = fields[7].trimmed.isEmpty ? nil : fields[7].trimmed
    }

    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(Self.self, from: data),
              metadata.searchResult != nil
        else { return nil }
        self = metadata
    }

    private static func durationSeconds(from label: String) -> Double {
        let parts = label
            .split(separator: ":")
            .compactMap { Double($0) }
        switch parts.count {
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2:
            return parts[0] * 60 + parts[1]
        case 1:
            return parts[0]
        default:
            return 0
        }
    }

    func withUploadDate(_ value: String) -> YouTubeVideoMetadata {
        YouTubeVideoMetadata(
            id: id,
            title: title,
            channel: channel,
            uploader: uploader,
            duration: duration,
            uploadDate: value.trimmed.isEmpty ? uploadDate : value.trimmed,
            webpageURL: webpageURL,
            originalURL: originalURL)
    }

    private init(id: String?, title: String?, channel: String?, uploader: String?,
                 duration: Double?, uploadDate: String?, webpageURL: String?, originalURL: String?) {
        self.id = id
        self.title = title
        self.channel = channel
        self.uploader = uploader
        self.duration = duration
        self.uploadDate = uploadDate
        self.webpageURL = webpageURL
        self.originalURL = originalURL
    }

    var durationSeconds: Double {
        duration ?? 0
    }

    var searchResult: YouTubeSearchResult? {
        guard let id = id?.trimmed, !id.isEmpty,
              let title = title?.trimmed, !title.isEmpty
        else { return nil }

        let urlString = webpageURL ?? originalURL ?? "https://www.youtube.com/watch?v=\(id)"
        guard let url = URL(string: urlString) else { return nil }

        return YouTubeSearchResult(
            id: id,
            title: title,
            description: "",
            channel: channel?.trimmed ?? uploader?.trimmed ?? "",
            durationSeconds: durationSeconds,
            uploadDate: uploadDate?.trimmed.isEmpty == false ? uploadDate : nil,
            webpageURL: url)
    }
}
