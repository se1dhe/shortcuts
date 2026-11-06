import AVFoundation
import Foundation
import os

enum MediaExtractorError: LocalizedError {
    case noVideoTrack
    case cannotOpenVideo(String)
    case inputConversionFailed(String)
    case audioExportFailed(String)
    case clipExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "That file doesn't contain a video track."
        case .cannotOpenVideo(let detail):
            return "Couldn't open that video file. Copy it to a local folder and try again. \(detail)"
        case .inputConversionFailed(let detail):
            return "Couldn't convert this video to a compatible MP4. \(detail)"
        case .audioExportFailed(let detail):
            return "Couldn't extract the audio track: \(detail)"
        case .clipExportFailed(let detail):
            return "Couldn't cut the clip: \(detail)"
        }
    }
}

/// Validates dropped videos and pulls the audio track into a temp file.
///
/// Frame sampling for the model is handled inside `Gemma4Engine` (it has its
/// own `Gemma4VideoProcessor`). The one thing the model can't do itself is read
/// audio out of a video container, so that is this type's job.
enum MediaExtractor {

    private static let logger = Logger(subsystem: "app.shortcast", category: "MediaExtractor")

    /// Containers such as Matroska are accepted by the picker, but AVFoundation
    /// cannot reliably decode every codec combination they contain. Normalize
    /// them before any AVFoundation or ML code sees the input.
    private static let containersNeedingNormalization: Set<String> = ["mkv", "webm", "avi"]

    static func needsNormalization(_ url: URL) -> Bool {
        containersNeedingNormalization.contains(url.pathExtension.lowercased())
    }

    /// Makes the source readable by AVFoundation without transcoding the whole film
    /// unless the video codec cannot be stream-copied into MP4.
    static func normalizeInputIfNeeded(
        from sourceURL: URL,
        workingDirectory: URL,
        selectedAudioStreamIndex: Int? = nil
    ) async throws -> URL {
        guard needsNormalization(sourceURL) || selectedAudioStreamIndex != nil else { return sourceURL }

        let ffprobe: URL
        do {
            ffprobe = try await BinaryDownloadService.ensureAvailable(.ffprobe, workingDirectory: workingDirectory)
        } catch {
            if needsNormalization(sourceURL) {
                throw MediaExtractorError.inputConversionFailed("FFprobe is required: \(shortError(error))")
            }
            return sourceURL
        }

        let inspectedTracks = await inspectAudioTracks(sourceURL: sourceURL, ffprobe: ffprobe)
        let videoStream = await inspectVideoStream(sourceURL: sourceURL, ffprobe: ffprobe)
        let selectedTrack: AudioTrackInfo?
        let targetAudioMap: String
        if let chosen = selectedAudioStreamIndex {
            targetAudioMap = "0:\(chosen)"
            selectedTrack = inspectedTracks.first(where: { $0.id == chosen })
        } else {
            selectedTrack = pickRecommendedAudioTrack(from: inspectedTracks)
            targetAudioMap = selectedTrack != nil ? "0:\(selectedTrack!.id)" : "0:a:0?"
        }

        let mustFixContainer = needsNormalization(sourceURL)
        let isolatingAudio = inspectedTracks.count > 1 && selectedAudioStreamIndex != nil
        let mustDownmix = (selectedTrack?.channels ?? 2) >= 6
        guard mustFixContainer || isolatingAudio || mustDownmix else { return sourceURL }

        let films = workingDirectory.appendingPathComponent("films", isDirectory: true).standardizedFileURL.path
        let inputDirectory = sourceURL.standardizedFileURL.path.hasPrefix(films + "/")
            ? sourceURL.deletingLastPathComponent()
            : workingDirectory.appendingPathComponent("input", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        } catch {
            throw MediaExtractorError.inputConversionFailed(error.localizedDescription)
        }

        if sourceURL.standardizedFileURL.path.hasPrefix(films + "/") {
            let required = Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try FilmLibrary.requireSpace(folder: inputDirectory, bytes: required > Int64.max / 2 ? Int64.max : required * 2)
        }
        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let baseCleanName = sourceURL.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let streamSuffix = selectedAudioStreamIndex.map { "_a\($0)" } ?? ""
        let deterministicName = "shortcast-normalized-\(baseCleanName.prefix(40))-\(sourceSize)\(streamSuffix).mp4"
        let outputURL = inputDirectory.appendingPathComponent(deterministicName)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            if await isPlayableMP4(outputURL) {
                return outputURL
            }
            try? FileManager.default.removeItem(at: outputURL)
        }

        let ffmpeg: URL
        do {
            ffmpeg = try await BinaryDownloadService.ensureAvailable(.ffmpeg, workingDirectory: workingDirectory)
        } catch {
            throw MediaExtractorError.inputConversionFailed(
                "FFmpeg is required for \(sourceURL.pathExtension.uppercased()) import: \(shortError(error))")
        }

        let canCopyAudio = !mustDownmix && Self.copyableAudioCodecs.contains(selectedTrack?.codec ?? "")
        let audioFilter: String? = mustDownmix
            ? "pan=stereo|c0=c2|c1=c2,aresample=async=1:first_pts=0"
            : (canCopyAudio ? nil : "aresample=async=1:first_pts=0")

        if videoStream?.canStreamCopyToMP4 != false {
            let copyOK = await runFFmpeg(
                ffmpeg,
                arguments: remuxArguments(
                    source: sourceURL,
                    output: outputURL,
                    audioMap: targetAudioMap,
                    videoTag: videoStream?.videoTag,
                    copyAudio: canCopyAudio,
                    audioFilter: audioFilter
                ),
                outputURL: outputURL
            )
            if copyOK { return outputURL }

            if canCopyAudio {
                let copyVideoEncodeAudio = await runFFmpeg(
                    ffmpeg,
                    arguments: remuxArguments(
                        source: sourceURL,
                        output: outputURL,
                        audioMap: targetAudioMap,
                        videoTag: videoStream?.videoTag,
                        copyAudio: false,
                        audioFilter: audioFilter
                    ),
                    outputURL: outputURL
                )
                if copyVideoEncodeAudio { return outputURL }
            }

            if audioFilter != nil {
                let copyBareOK = await runFFmpeg(
                    ffmpeg,
                    arguments: remuxArguments(
                        source: sourceURL,
                        output: outputURL,
                        audioMap: targetAudioMap,
                        videoTag: videoStream?.videoTag,
                        copyAudio: false,
                        audioFilter: nil
                    ),
                    outputURL: outputURL
                )
                if copyBareOK { return outputURL }
            }
        }

        let downscale = videoStream?.shouldDownscale ?? false
        let hwOK = await runFFmpeg(
            ffmpeg,
            arguments: transcodeArguments(
                source: sourceURL,
                output: outputURL,
                audioMap: targetAudioMap,
                copyAudio: canCopyAudio,
                audioFilter: audioFilter,
                hardware: true,
                hwaccel: true,
                downscale: downscale
            ),
            outputURL: outputURL
        )
        if hwOK { return outputURL }

        let hwNoAccelOK = await runFFmpeg(
            ffmpeg,
            arguments: transcodeArguments(
                source: sourceURL,
                output: outputURL,
                audioMap: targetAudioMap,
                copyAudio: canCopyAudio,
                audioFilter: audioFilter,
                hardware: true,
                hwaccel: false,
                downscale: downscale
            ),
            outputURL: outputURL
        )
        if hwNoAccelOK { return outputURL }

        let swOK = await runFFmpeg(
            ffmpeg,
            arguments: transcodeArguments(
                source: sourceURL,
                output: outputURL,
                audioMap: targetAudioMap,
                copyAudio: canCopyAudio,
                audioFilter: audioFilter,
                hardware: false,
                hwaccel: false,
                downscale: downscale
            ),
            outputURL: outputURL
        )
        if swOK { return outputURL }

        throw MediaExtractorError.inputConversionFailed("FFmpeg could not produce a playable MP4 from this file.")
    }

    /// Commit the verified replacement before removing either copy of the MKV.
    /// A failed validation/save leaves both sources intact; a deletion failure is recoverable.
    static func finishMKVImport(
        project: FilmProject, sourceURL: URL, originalURL: URL?, outputURL: URL,
        workingDirectory: URL, selectedAudioStreamIndex: Int?,
        save: @Sendable (FilmProject) async throws -> Void
    ) async throws -> FilmProject {
        guard sourceURL.pathExtension.lowercased() == "mkv",
              outputURL.pathExtension.lowercased() == "mp4",
              sourceURL.resolvingSymlinksInPath() != outputURL.resolvingSymlinksInPath() else {
            throw MediaExtractorError.inputConversionFailed("Нельзя заменить исходник этим файлом.")
        }
        OperationJournal.shared.append("Проверяем длительность, видео и звук подготовленного MP4…")
        let probe = try await BinaryDownloadService.ensureAvailable(.ffprobe, workingDirectory: workingDirectory)
        let sourceTracks = await inspectAudioTracks(sourceURL: sourceURL, ffprobe: probe)
        if let selectedAudioStreamIndex, !sourceTracks.contains(where: { $0.id == selectedAudioStreamIndex }) {
            throw MediaExtractorError.inputConversionFailed("Выбранная аудиодорожка отсутствует в исходнике.")
        }
        let probeResult = try await ProcessRunner.shared.run(executableURL: probe,
            arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "json", sourceURL.path])
        guard probeResult.isSuccess, let data = probeResult.standardOutput.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? [String: Any],
              let text = format["duration"] as? String, let sourceDuration = Double(text),
              sourceDuration.isFinite, sourceDuration > 0 else {
            throw MediaExtractorError.inputConversionFailed("Не удалось проверить длительность исходника.")
        }
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let outputTracks = await inspectAudioTracks(sourceURL: outputURL, ffprobe: probe)
        guard duration.isFinite, abs(duration - sourceDuration) <= 2,
              !video.isEmpty, audio.count == 1, outputTracks.count == 1 else {
            throw MediaExtractorError.inputConversionFailed("MP4 неполный либо не содержит единственную выбранную аудиодорожку.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        for time in [min(0.25, duration * 0.1), duration * 0.5, max(0, duration - 0.25)] {
            try Task.checkCancellation()
            _ = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        }
        let chosenTrack = sourceTracks.first { $0.id == selectedAudioStreamIndex }
            ?? pickRecommendedAudioTrack(from: sourceTracks)
        if let chosenTrack, let expected = await audioDuration(sourceURL: sourceURL, streamIndex: chosenTrack.id, ffprobe: probe) {
            let actual = try await audio[0].load(.timeRange).duration.seconds
            guard actual.isFinite, actual + 2 >= expected else {
                throw MediaExtractorError.inputConversionFailed("Звуковая дорожка MP4 обрезана относительно выбранной дорожки MKV.")
            }
        }
        try await validateAudioSamples(asset: asset, track: audio[0])
        var adopted = project
        adopted.sourceMovieURL = outputURL
        adopted.fileSizeBytes = Int64(try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        adopted.selectedAudioTrackId = outputTracks[0].id
        try Task.checkCancellation()
        try await save(adopted)
        OperationJournal.shared.append("MP4 проверен, проект привязан к подготовленной копии.")
        var removedPaths: Set<String> = []
        for url in [sourceURL, originalURL].compactMap({ $0 }) {
            guard url.pathExtension.lowercased() == "mkv",
                  url.resolvingSymlinksInPath() != outputURL.resolvingSymlinksInPath(),
                  removedPaths.insert(url.standardizedFileURL.path).inserted,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try FileManager.default.removeItem(at: url)
                let amount = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                OperationJournal.shared.append("Удалён исходный MKV: \(url.lastPathComponent). Освобождено \(amount).")
                DirectorRunLog.write("MKV cleanup: removed \(url.lastPathComponent), bytes=\(bytes)")
            } catch {
                OperationJournal.shared.append("MP4 готов, но MKV не удалось удалить: \(url.lastPathComponent). \(error.localizedDescription)", level: .warning)
            }
        }
        return adopted
    }

    private static func audioDuration(sourceURL: URL, streamIndex: Int, ffprobe: URL) async -> Double? {
        guard let result = try? await ProcessRunner.shared.run(executableURL: ffprobe,
            arguments: ["-v", "error", "-select_streams", String(streamIndex), "-show_entries",
                        "stream=start_time,duration:stream_tags=DURATION", "-of", "json", sourceURL.path]),
              result.isSuccess, let data = result.standardOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first else { return nil }
        let duration = (stream["duration"] as? String).flatMap(Double.init)
        let tag = (stream["tags"] as? [String: String])?["DURATION"].flatMap(TranscriptionService.timecode)
        let value = duration ?? tag.map { $0 - ((stream["start_time"] as? String).flatMap(Double.init) ?? 0) }
        return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Audio and video can end at different times. Probe the actual audio
    /// timeline, including its beginning, middle and tail, rather than the video tail.
    static func validateAudioSamples(asset: AVURLAsset, track: AVAssetTrack) async throws {
        let range = try await track.load(.timeRange)
        let start = range.start.seconds
        let duration = range.duration.seconds
        guard start.isFinite, duration.isFinite, duration > 0 else {
            throw MediaExtractorError.inputConversionFailed("Пустая звуковая дорожка MP4.")
        }
        for offset in [0.0, duration * 0.5, max(0, duration - 1)] {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaExtractorError.inputConversionFailed("Не удалось проверить звук MP4.") }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start + offset, preferredTimescale: 600),
                duration: CMTime(seconds: min(1, duration - offset), preferredTimescale: 600))
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                  CMSampleBufferGetNumSamples(sample) > 0 else {
                let detail = reader.error?.localizedDescription ?? "нет аудиосэмплов"
                reader.cancelReading()
                throw MediaExtractorError.inputConversionFailed("Не удалось прочитать звук MP4 на \(Int(start + offset)) с: \(detail)")
            }
            reader.cancelReading()
        }
    }

    private static let copyableAudioCodecs: Set<String> = ["aac", "mp3", "ac3"]

    private struct ProbedVideoStream: Sendable {
        let codecName: String
        let width: Int
        let height: Int

        var canStreamCopyToMP4: Bool {
            switch codecName {
            case "h264", "hevc", "mpeg4":
                return true
            default:
                return false
            }
        }

        var videoTag: String? {
            codecName == "hevc" ? "hvc1" : nil
        }

        var shouldDownscale: Bool { height > 1080 || width > 1920 }
    }

    private static let ffmpegQuietPrefix = [
        "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-y"
    ]

    private static func remuxArguments(
        source: URL,
        output: URL,
        audioMap: String,
        videoTag: String?,
        copyAudio: Bool,
        audioFilter: String?
    ) -> [String] {
        var args = ffmpegQuietPrefix + [
            "-i", source.path,
            "-map", "0:v:0",
            "-map", audioMap,
            "-map_metadata", "-1",
            "-map_chapters", "-1",
            "-sn", "-dn",
            "-c:v", "copy"
        ]
        if let videoTag {
            args += ["-tag:v", videoTag]
        }
        args += audioEncodeArguments(copyAudio: copyAudio, audioFilter: audioFilter)
        args += [
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            output.path
        ]
        return args
    }

    private static func transcodeArguments(
        source: URL,
        output: URL,
        audioMap: String,
        copyAudio: Bool,
        audioFilter: String?,
        hardware: Bool,
        hwaccel: Bool,
        downscale: Bool
    ) -> [String] {
        var args: [String] = []
        if hwaccel {
            args += ["-hwaccel", "videotoolbox"]
        }
        args += ffmpegQuietPrefix + [
            "-i", source.path,
            "-map", "0:v:0",
            "-map", audioMap,
            "-map_metadata", "-1",
            "-map_chapters", "-1",
            "-sn", "-dn"
        ]
        if downscale {
            args += ["-vf", "scale=-2:min(1080\\,ih)"]
        }
        args += ["-pix_fmt", "yuv420p"]
        if hardware {
            args += [
                "-c:v", "h264_videotoolbox",
                "-b:v", "8M",
                "-maxrate", "10M",
                "-bufsize", "16M"
            ]
        } else {
            args += [
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "23",
                "-threads", "4"
            ]
        }
        args += audioEncodeArguments(copyAudio: copyAudio, audioFilter: audioFilter)
        args += [
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            output.path
        ]
        return args
    }

    private static func audioEncodeArguments(copyAudio: Bool, audioFilter: String?) -> [String] {
        if copyAudio {
            return ["-c:a", "copy"]
        }
        var args = [
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "48000",
            "-ac", "2"
        ]
        if let audioFilter {
            args += ["-af", audioFilter]
        }
        return args
    }

    private static func runFFmpeg(_ ffmpeg: URL, arguments: [String], outputURL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        do {
            let result = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: arguments)
            guard result.isSuccess else {
                try? FileManager.default.removeItem(at: outputURL)
                return false
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        let playable = await isPlayableMP4(outputURL)
        if !playable {
            try? FileManager.default.removeItem(at: outputURL)
        }
        return playable
    }

    private static func isPlayableMP4(_ url: URL) async -> Bool {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 1024 * 1024 else { return false }
        let asset = AVURLAsset(url: url)
        let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !vTracks.isEmpty, let audio = aTracks.first else { return false }
        do { try await validateAudioSamples(asset: asset, track: audio); return true }
        catch { return false }
    }

    private static func inspectVideoStream(sourceURL: URL, ffprobe: URL) async -> ProbedVideoStream? {
        let args = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,pix_fmt,width,height",
            "-of", "json",
            sourceURL.path
        ]
        guard let result = try? await ProcessRunner.shared.run(executableURL: ffprobe, arguments: args),
              result.isSuccess,
              let data = result.standardOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first
        else {
            return nil
        }
        return ProbedVideoStream(
            codecName: (stream["codec_name"] as? String) ?? "",
            width: (stream["width"] as? Int) ?? 0,
            height: (stream["height"] as? Int) ?? 0
        )
    }

    private static func shortError(_ error: Error) -> String {
        let detail = error.localizedDescription
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(detail.suffix(700))
    }

    /// Builds a `VideoJob` from a dropped file URL, verifying it really is a video.
    static func makeJob(
        from url: URL,
        originalFileName: String? = nil,
        sourceMetadata: VideoSourceMetadata? = nil
    ) async throws -> VideoJob {
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw MediaExtractorError.cannotOpenVideo(error.localizedDescription)
        }
        guard !videoTracks.isEmpty else { throw MediaExtractorError.noVideoTrack }
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw MediaExtractorError.cannotOpenVideo(error.localizedDescription)
        }
        return VideoJob(
            url: url,
            durationSeconds: CMTimeGetSeconds(duration),
            sourceMetadata: sourceMetadata,
            originalFileName: originalFileName)
    }

    /// Extracts the audio track to a temporary `.m4a`. `maxSeconds` caps the
    /// export (default 35s, a little past Gemma's 30s audio window); pass `nil`
    /// to export the full track (used for transcribing a long video). Returns
    /// `nil` if the video has no audio track.
    static func extractAudio(from url: URL, maxSeconds: Double? = 35, range: TimeSegment? = nil) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw MediaExtractorError.audioExportFailed("export session unavailable")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-audio-\(UUID().uuidString).m4a")

        if let range {
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let start = max(0, range.start)
            let end = min(duration, range.end)
            guard start.isFinite, end.isFinite, end > start else { throw MediaExtractorError.audioExportFailed("invalid audio range") }
            export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600))
        } else if let maxSeconds {
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let cap = CMTime(seconds: min(duration, maxSeconds), preferredTimescale: 600)
            export.timeRange = CMTimeRange(start: .zero, duration: cap)
        }

        do {
            try await export.export(to: outputURL, as: .m4a)
        } catch {
            throw MediaExtractorError.audioExportFailed(error.localizedDescription)
        }
        return outputURL
    }

    /// Cuts `[start, start+duration]` out of a video into a temporary `.mp4`.
    /// Tries a passthrough export first (no re-encode → near-instant, original
    /// quality); falls back to a re-encode if the source codec/container can't
    /// passthrough. Keeps the original aspect ratio (9:16 reframing is a future
    /// enhancement). `.mp4` matches the content type Upload-Post expects.
    static func inspectAudioTracks(
        sourceURL: URL,
        workingDirectory: URL
    ) async -> [AudioTrackInfo] {
        guard let ffprobe = try? await BinaryDownloadService.ensureAvailable(.ffprobe, workingDirectory: workingDirectory) else {
            return []
        }
        return await inspectAudioTracks(sourceURL: sourceURL, ffprobe: ffprobe)
    }

    /// Inspects audio streams within a container using an already located ffprobe binary.
    static func inspectAudioTracks(
        sourceURL: URL,
        ffprobe: URL
    ) async -> [AudioTrackInfo] {
        let args = [
            "-v", "error",
            "-show_entries", "stream=index,codec_type,codec_name,channels,disposition:stream_tags=title,language",
            "-of", "json",
            sourceURL.path
        ]
        
        guard let result = try? await ProcessRunner.shared.run(executableURL: ffprobe, arguments: args),
              result.isSuccess,
              let data = result.standardOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return []
        }
        
        let audioStreams = streams.filter { ($0["codec_type"] as? String) == "audio" }
        var resultTracks: [AudioTrackInfo] = []
        
        for (audioIdx, stream) in audioStreams.enumerated() {
            guard let streamIndex = stream["index"] as? Int else { continue }
            let tags = stream["tags"] as? [String: Any]
            let title = tags?["title"] as? String
            let language = tags?["language"] as? String
            let codec = (stream["codec_name"] as? String) ?? "unknown"
            let channels = (stream["channels"] as? Int) ?? 2
            let disposition = stream["disposition"] as? [String: Any]
            let isDefault = (disposition?["default"] as? Int) == 1
            let isForced = (disposition?["forced"] as? Int) == 1
            
            resultTracks.append(AudioTrackInfo(
                id: streamIndex,
                audioIndex: audioIdx,
                title: title,
                language: language,
                codec: codec,
                channels: channels,
                isDefault: isDefault,
                isForced: isForced
            ))
        }
        
        return resultTracks
    }

    /// Selects the most suitable audio track by default (prioritizing Ukrainian dubs).
    static func pickRecommendedAudioTrack(from tracks: [AudioTrackInfo]) -> AudioTrackInfo? {
        guard !tracks.isEmpty else { return nil }

        // 1. Priority to Ukrainian language code (ukr/uk/українська)
        for track in tracks {
            let l = (track.language ?? "").lowercased()
            if l == "ukr" || l == "uk" || l == "українська" || l == "український" {
                logger.info("Обрано українську аудіодоріжку за мовним кодом: \(track.title ?? "без назви", privacy: .public) (\(l, privacy: .public))")
                return track
            }
        }

        // 2. Priority to Ukrainian title match
        for track in tracks {
            let t = (track.title ?? "").lowercased()
            if t.contains("українськ") || t.contains("ukrainian") {
                logger.info("Обрано українську аудіодоріжку за назвою: \(t, privacy: .public)")
                return track
            }
        }

        // 3. Priority to Russian Dubs (contains "дубляж", "dub", "проф") — legacy fallback
        for track in tracks {
            let t = (track.title ?? "").lowercased()
            if t.contains("дубляж") || t.contains("dub") || t.contains("dvd") || t.contains("проф") {
                logger.warning("Українську доріжку не знайдено → використано «\(t, privacy: .public)» (російський дубляж)")
                return track
            }
        }

        // 4. Priority to 'rus' or 'ru' language track
        for track in tracks {
            let l = (track.language ?? "").lowercased()
            if l == "rus" || l == "ru" {
                logger.warning("Українську доріжку не знайдено → використано мову \(l, privacy: .public)")
                return track
            }
        }

        // 5. Fallback to track flagged as Russian voiceover
        if let rus = tracks.first(where: { $0.isRussianVoiceover }) {
            logger.warning("Українську доріжку не знайдено → використано російську озвучку")
            return rus
        }

        // 6. Fallback to container default track
        if let def = tracks.first(where: { $0.isDefault }) {
            logger.warning("Українську доріжку не знайдено → використано дефолтну доріжку контейнера")
            return def
        }

        // 7. First track
        logger.warning("Українську доріжку не знайдено → використано першу доступну доріжку")
        return tracks.first
    }
}
