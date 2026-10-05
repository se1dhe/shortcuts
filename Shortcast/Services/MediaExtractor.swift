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

    /// Containers such as Matroska are accepted by the picker, but AVFoundation
    /// cannot reliably decode every codec combination they contain. Normalize
    /// them before any AVFoundation or ML code sees the input.
    private static let containersNeedingNormalization: Set<String> = ["mkv", "webm", "avi"]

    static func needsNormalization(_ url: URL) -> Bool {
        containersNeedingNormalization.contains(url.pathExtension.lowercased())
    }

    /// Converts non-Apple video containers into a broadly compatible H.264/AAC
    /// MP4. The first pass uses VideoToolbox; a software H.264 fallback keeps
    /// imports working on Macs where the hardware encoder rejects the source.
    static func normalizeInputIfNeeded(
        from sourceURL: URL,
        workingDirectory: URL,
        selectedAudioStreamIndex: Int? = nil
    ) async throws -> URL {
        // If normalization is not required and no specific audio track was chosen, pass-through.
        // However, if a specific audio stream was chosen from a multi-track container,
        // we MUST normalize to ensure AVFoundation/Whisper isolate that single track.
        guard needsNormalization(sourceURL) || selectedAudioStreamIndex != nil else { return sourceURL }

        let inputDirectory = workingDirectory.appendingPathComponent("input", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        } catch {
            throw MediaExtractorError.inputConversionFailed(error.localizedDescription)
        }

        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let baseCleanName = sourceURL.deletingPathExtension().lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
        let streamSuffix = selectedAudioStreamIndex.map { "_a\($0)" } ?? ""
        let deterministicName = "shortcast-normalized-\(baseCleanName.prefix(40))-\(sourceSize)\(streamSuffix).mp4"
        let outputURL = inputDirectory.appendingPathComponent(deterministicName)

        // 1. Быстрая проверка дискового кэша: если нормализованный MP4 уже существует и читаем, используем мгновенно
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let existingSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if existingSize > 1024 * 1024 {
                let asset = AVURLAsset(url: outputURL)
                if (try? await asset.loadTracks(withMediaType: .video).first) != nil {
                    return outputURL
                }
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

        let ffprobe: URL
        do {
            ffprobe = try await BinaryDownloadService.ensureAvailable(.ffprobe, workingDirectory: workingDirectory)
        } catch {
            throw MediaExtractorError.inputConversionFailed("FFprobe is required: \(shortError(error))")
        }

        let inspectedTracks = await inspectAudioTracks(sourceURL: sourceURL, ffprobe: ffprobe)
        let selectedTrack: AudioTrackInfo?
        let targetAudioMap: String
        if let chosen = selectedAudioStreamIndex {
            targetAudioMap = "0:\(chosen)"
            selectedTrack = inspectedTracks.first(where: { $0.id == chosen })
        } else {
            selectedTrack = pickRecommendedAudioTrack(from: inspectedTracks)
            targetAudioMap = selectedTrack != nil ? "0:\(selectedTrack!.id)" : "0:a:0?"
        }

        // Dialogue Focus: для 5.1/7.1 выделяем чистый центральный канал речи (c2 / FC) на 100%,
        // а фоновую музыку фильма (c0, c1, c4, c5) приглушаем на 80-85%, освобождая место под саундтрек
        let isMultiChannel = (selectedTrack?.channels ?? 2) >= 6
        let audioFilter = isMultiChannel
            ? "pan=stereo|c0=c2+0.18*c0+0.1*c4|c1=c2+0.18*c1+0.1*c5,aresample=async=1:first_pts=0"
            : "pan=stereo|c0=0.7*c0+0.3*c1|c1=0.3*c0+0.7*c1,aresample=async=1:first_pts=0"

        // 2. СВЕРХБЫСТРЫЙ ПАСС: Ремуксинг без перекодирования (-c:v copy).
        // Если видеопоток уже H.264 или HEVC, перепаковка MKV в MP4 занимает 5-10 секунд вместо 20 минут.
        let remuxArguments = [
            "-hide_banner", "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", targetAudioMap,
            "-map_metadata", "-1",
            "-map_chapters", "-1",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "192k",
            "-profile:a", "aac_low",
            "-ar", "48000",
            "-ac", "2",
            "-af", audioFilter,
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            outputURL.path
        ]

        if let _ = try? await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: remuxArguments) {
            let asset = AVURLAsset(url: outputURL)
            let vTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            if !vTracks.isEmpty && !aTracks.isEmpty && fileSize > 1024 * 1024 {
                return outputURL
            }
            try? FileManager.default.removeItem(at: outputURL)
        }

        // 3. FALLBACK ПАСС: Полное перекодирование для нестандартных кодеков (VP9, AV1 и т.д.)
        let commonArguments = [
            "-hide_banner", "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", targetAudioMap,
            "-map_metadata", "-1",
            "-map_chapters", "-1",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-profile:a", "aac_low",
            "-ar", "48000",
            "-ac", "2",
            "-af", audioFilter,
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart"
        ]

        let hardwareArguments = commonArguments + [
            "-c:v", "h264_videotoolbox",
            "-b:v", "16M",
            "-maxrate", "20M",
            "-bufsize", "32M",
            outputURL.path
        ]
        let softwareArguments = commonArguments + [
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "18",
            outputURL.path
        ]

        do {
            _ = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: hardwareArguments)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            do {
                _ = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: softwareArguments)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw MediaExtractorError.inputConversionFailed(shortError(error))
            }
        }

        let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaExtractorError.inputConversionFailed("FFmpeg produced an empty MP4 file.")
        }
        return outputURL
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
    static func extractAudio(from url: URL, maxSeconds: Double? = 35) async throws -> URL? {
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

        if let maxSeconds {
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
    static func cutClip(from url: URL, start: Double, duration: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MediaExtractorError.noVideoTrack }

        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-clip-\(UUID().uuidString).mp4")

        // Try re-encode first (highest quality → H.264/AAC) so downstream
        // operations (VideoOverlayRenderer, VerticalReframer) can always create
        // an AVMutableComposition. VP9/AV1 from YouTube passthrough would fail
        // in those later composition-based exports.
        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue
            }
            export.timeRange = range
            do {
                try await export.export(to: outputURL, as: .mp4)
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                if preset == AVAssetExportPresetPassthrough {
                    throw MediaExtractorError.clipExportFailed(error.localizedDescription)
                }
            }
        }
        throw MediaExtractorError.clipExportFailed("no usable export preset")
    }

    /// Cuts and stitches multiple time ranges from a video into a temporary `.mp4`.
    static func cutAndStitchClip(from url: URL, segments: [CMTimeRange]) async throws -> URL {
        let asset = AVURLAsset(url: url)
        
        let composition = AVMutableComposition()
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        
        let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        compVideoTrack?.preferredTransform = try await videoTrack.load(.preferredTransform)
        
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let compAudioTrack = audioTrack != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        
        var insertTime: CMTime = .zero
        
        for range in segments {
            try compVideoTrack?.insertTimeRange(range, of: videoTrack, at: insertTime)
            if let aTrack = audioTrack {
                try compAudioTrack?.insertTimeRange(range, of: aTrack, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime, range.duration)
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-stitched-\(UUID().uuidString).mp4")
            
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaExtractorError.clipExportFailed("no usable export preset")
        }
        
        do {
            try await export.export(to: outputURL, as: .mp4)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaExtractorError.clipExportFailed(error.localizedDescription)
        }
    }

    /// Public method to inspect all audio tracks in a media file using ffprobe.
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

    /// Selects the most suitable audio track by default (prioritizing Russian dubs).
    static func pickRecommendedAudioTrack(from tracks: [AudioTrackInfo]) -> AudioTrackInfo? {
        guard !tracks.isEmpty else { return nil }

        // 1. Priority to Russian Dubs (contains "дубляж", "dub", "проф")
        for track in tracks {
            let t = (track.title ?? "").lowercased()
            if t.contains("дубляж") || t.contains("dub") || t.contains("dvd") || t.contains("проф") {
                return track
            }
        }

        // 2. Priority to 'rus' or 'ru' language track
        for track in tracks {
            let l = (track.language ?? "").lowercased()
            if l == "rus" || l == "ru" {
                return track
            }
        }

        // 3. Fallback to track flagged as Russian voiceover
        if let rus = tracks.first(where: { $0.isRussianVoiceover }) {
            return rus
        }

        // 4. Fallback to container default track
        if let def = tracks.first(where: { $0.isDefault }) {
            return def
        }

        // 5. First track
        return tracks.first
    }

    private static func determineBestAudioTrack(
        sourceURL: URL,
        ffprobe: URL
    ) async -> String {
        let tracks = await inspectAudioTracks(sourceURL: sourceURL, ffprobe: ffprobe)
        if let best = pickRecommendedAudioTrack(from: tracks) {
            return "0:\(best.id)"
        }
        return "0:a:0?"
    }
}


/// Overlay-compatible high-bitrate exporter, replacing `AVAssetExportPresetHighestQuality`
/// (whose bitrate ceiling softens detail and text).
///
/// Two steps, because `AVVideoCompositionCoreAnimationTool` (the overlay burn-in) is only
/// honored by `AVAssetExportSession`, never by `AVAssetReaderVideoCompositionOutput`:
///  1. Export the composition (incl. its animation tool) with the highest-quality preset
///     that honors the animation tool — **HEVC Highest Quality** (visibly better detail
///     retention than H.264 Highest Quality). AVAssetExportSession has no ProRes preset,
///     so this is the best available intermediate.
///  2. Transcode that intermediate to **high-bitrate H.264 mp4** with `AVAssetWriter` — a
///     plain track transcode with no composition, which `AVAssetReader` fully supports —
///     so the deliverable is a widely-compatible H.264 file at ~20 Mbps (1080×1920).
///
/// This lifts the H.264-Highest bitrate ceiling; a fully uncapped single pass would need a
/// custom `AVVideoCompositing` compositor instead of the Core Animation tool.
enum HighBitrateExporter {

    static func export(asset: sending AVAsset,
                       videoComposition: sending AVVideoComposition,
                       to outputURL: URL) async throws {
        let intermediateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-hqmezz-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: intermediateURL) }

        // Step 1 — burn the composition at HEVC Highest Quality (animation tool honored).
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)
        else { throw MediaExtractorError.clipExportFailed("HEVC export session unavailable") }
        export.videoComposition = videoComposition
        
        // Strict AV Sync: Cap export timeRange to min(vDuration, aDuration) to prevent dangling dead frames/silence tails
        let vTrack = try? await asset.loadTracks(withMediaType: .video).first
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let vDur = try? await vTrack?.load(.timeRange).duration
        let aDur = try? await aTrack?.load(.timeRange).duration
        var finalDuration = try await asset.load(.duration)
        if let vDur, let aDur, aDur.seconds > 0.1 {
            finalDuration = CMTimeMinimum(vDur, aDur)
        }
        export.timeRange = CMTimeRange(start: .zero, duration: finalDuration)

        do {
            try await export.export(to: intermediateURL, as: .mov)
        } catch {
            throw MediaExtractorError.clipExportFailed("HEVC pass: \(error.localizedDescription)")
        }

        // Step 2 — transcode intermediate → high-bitrate H.264 mp4.
        try await transcodeToH264(from: intermediateURL, to: outputURL)
    }

    private static func transcodeToH264(from src: URL, to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: src)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let videoOut = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            throw MediaExtractorError.clipExportFailed("reader can't add video output")
        }
        reader.add(videoOut)

        // ProRes frames are already oriented (the composition rendered them upright).
        let size = try await videoTrack.load(.naturalSize)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(abs(size.width).rounded()),
            AVVideoHeightKey: Int(abs(size.height).rounded()),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate(for: size),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            ],
        ]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else {
            throw MediaExtractorError.clipExportFailed("writer can't add video input")
        }
        writer.add(videoIn)

        var audioOut: AVAssetReaderTrackOutput?
        var audioIn: AVAssetWriterInput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            if reader.canAdd(out) {
                reader.add(out); audioOut = out
                let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44_100,
                    AVEncoderBitRateKey: 256_000,
                ])
                inp.expectsMediaDataInRealTime = false
                if writer.canAdd(inp) { writer.add(inp); audioIn = inp }
            }
        }

        guard reader.startReading() else {
            throw MediaExtractorError.clipExportFailed(reader.error?.localizedDescription ?? "reader failed to start")
        }
        guard writer.startWriting() else {
            throw MediaExtractorError.clipExportFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        // AVFoundation reader/writer objects aren't Sendable; they're only ever touched
        // on one queue at a time here, so pass them through @unchecked Sendable boxes.
        let vBox = Unchecked((videoIn, videoOut))
        let aBox: Unchecked<(AVAssetWriterInput, AVAssetReaderTrackOutput)>? =
            (audioIn != nil && audioOut != nil) ? Unchecked((audioIn!, audioOut!)) : nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(vBox.value.0, from: vBox.value.1) }
            if let aBox { group.addTask { await pump(aBox.value.0, from: aBox.value.1) } }
        }

        if reader.status == .failed {
            reader.cancelReading()
            throw MediaExtractorError.clipExportFailed(reader.error?.localizedDescription ?? "read failed")
        }
        let wBox = Unchecked(writer)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wBox.value.finishWriting { cont.resume() }
        }
        if writer.status != .completed {
            throw MediaExtractorError.clipExportFailed(writer.error?.localizedDescription ?? "write failed")
        }
    }

    /// Cinema delivery bitrate: ~38 Mbps for 1080×1920 vertical, minimum 28 Mbps for square 1080×1080
    /// (high-detail cinema target; preserves faces, dark movie shadows, and sharp subtitles).
    private static func targetBitrate(for size: CGSize) -> Int {
        let pixels = max(1, abs(size.width) * abs(size.height))
        let bitrate = 38_000_000.0 * (pixels / (1080.0 * 1920.0))
        return Int(min(50_000_000, max(28_000_000, bitrate)))
    }

    private static func pump(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput) async {
        let box = Unchecked((input, output))
        let lock = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "shortcast.hqexport.pump")
            box.value.0.requestMediaDataWhenReady(on: queue) {
                let input = box.value.0
                let output = box.value.1

                let finish = {
                    let shouldResume = lock.withLock { isDone -> Bool in
                        if isDone { return false }
                        isDone = true
                        return true
                    }
                    if shouldResume {
                        input.markAsFinished()
                        cont.resume()
                    }
                }

                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) {
                            finish()
                            return
                        }
                    } else {
                        finish()
                        return
                    }
                }
            }
        }
    }


    /// Carries a non-Sendable value across a concurrency boundary where we've reasoned it
    /// is used on only one queue at a time.
    private struct Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}
