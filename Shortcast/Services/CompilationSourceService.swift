import AVFoundation
import Foundation

struct CompilationSource: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var url: URL
    var start: Double
    var end: Double
    var audioStreamIndex: Int
    var timelineStart: Double = 0
    var duration: Double { end - start }
}
struct CompilationManifest: Codable, Sendable {
    var title: String
    var sources: [CompilationSource]
    var overview: String {
        "Тематична добірка з кількох джерел. Не приписуй усі сцени одному фільму. Джерела і межі у спільному таймлайні:\n" + sources.map { "\($0.title): \(Int($0.timelineStart))–\(Int($0.timelineStart + $0.duration)) с" }.joined(separator: "\n")
    }
    static func load(for video: URL) -> Self? {
        guard let data = try? Data(contentsOf: video.deletingPathExtension().appendingPathExtension("sources.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Produces one verified editing source with an explicit, reversible mapping to each original.
/// Originals are never removed; all temporary media belongs to the new compilation folder.
enum CompilationSourceService {
    static func build(title: String, sources: [CompilationSource], directory: URL) async throws -> URL {
        guard !title.trimmed.isEmpty, sources.count >= 2,
              sources.allSatisfy({ !$0.title.trimmed.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.duration >= 3 }) else {
            throw EssayReleaseError.invalid("Добавьте минимум два источника с названиями и корректными границами от 3 секунд.")
        }
        let folder = directory.appendingPathComponent("films/collection-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("preparing.mp4")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: partial) } }
        let total = sources.reduce(0) { $0 + $1.duration }
        guard total.isFinite, total < Double(Int64.max / 3_000_000) else { throw EssayReleaseError.invalid("Слишком большая длительность подборки.") }
        try FilmLibrary.requireSpace(folder: folder, bytes: Int64(total * 3_000_000))
        let ffmpeg = try await BinaryDownloadService.ensureAvailable(.ffmpeg, workingDirectory: directory)
        var args = ["-hide_banner", "-nostdin", "-v", "error", "-y"]
        var filters: [String] = []
        var mapped = sources
        var cursor = 0.0
        var scoped: [URL] = []
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        for (i, source) in sources.enumerated() {
            if source.url.startAccessingSecurityScopedResource() { scoped.append(source.url) }
            let tracks = await MediaExtractor.inspectAudioTracks(sourceURL: source.url, workingDirectory: directory)
            guard tracks.contains(where: { $0.id == source.audioStreamIndex }) else { throw EssayReleaseError.invalid("Выбранная дорожка отсутствует: " + source.title) }
            // Probe the input through ffprobe when AVFoundation cannot read Matroska.
            let probe = try await BinaryDownloadService.ensureAvailable(.ffprobe, workingDirectory: directory)
            let durationReply = try await ProcessRunner.shared.run(executableURL: probe, arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", source.url.path])
            guard durationReply.isSuccess, let duration = Double(durationReply.standardOutput.trimmed), duration.isFinite, source.end <= duration + 0.05 else { throw EssayReleaseError.invalid("Границы выходят за источник: " + source.title) }
            mapped[i].timelineStart = cursor; cursor += source.duration
            args += ["-ss", String(source.start), "-t", String(source.duration), "-i", source.url.path]
            filters.append("[\(i):v:0]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,setpts=PTS-STARTPTS[v\(i)]")
            filters.append("[\(i):\(source.audioStreamIndex)]aresample=48000,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(i)]")
        }
        filters.append(sources.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(sources.count):v=1:a=1[v][a]")
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]", "-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", partial.path]
        OperationJournal.shared.append("Готовлю общую монтажную основу из \(sources.count) источников · \(Int(total)) с")
        let reply = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: args)
        guard reply.isSuccess else { throw EssayReleaseError.invalid("Не удалось подготовить подборку: " + String(reply.standardError.suffix(500))) }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: partial)
        let actual = try await asset.load(.duration).seconds
        guard abs(actual - total) < max(0.3, Double(sources.count) * 0.1),
              try await asset.loadTracks(withMediaType: .audio).count == 1 else { throw EssayReleaseError.invalid("Подборка не прошла проверку длительности и звука.") }
        let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 320, height: 180)
        for time in [0.2, total / 2, max(0, total - 0.2)] { _ = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) }
        let output = folder.appendingPathComponent("collection.mp4")
        try FileManager.default.moveItem(at: partial, to: output)
        let manifest = CompilationManifest(title: title, sources: mapped)
        try JSONEncoder().encode(manifest).write(to: output.deletingPathExtension().appendingPathExtension("sources.json"), options: .atomic)
        complete = true
        return output
    }
}
