import Foundation
import NaturalLanguage
import Observation
@preconcurrency import WhisperKit

// WordTimestamp is defined in Shortcast/Models/WordTimestamp.swift

/// One spoken segment with its time range, in seconds.
struct TranscriptSegment: Codable, Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let words: [WordTimestamp]

    init(start: Double, end: Double, text: String, words: [WordTimestamp] = []) {
        self.start = start
        self.end = end
        self.text = text.cleanedTranscriptText
        self.words = words
    }

    /// Returns word-level timestamps, or synthesizes character-proportional word timestamps
    /// across `[start, end]` when `words` is empty (e.g., loaded from a legacy `.srt`).
    func resolvedWords() -> [WordTimestamp] {
        let validWords = words.filter {
            !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end >= $0.start
        }
        if !validWords.isEmpty {
            return validWords
        }
        return Self.synthesizeProportionalWords(text: text, start: start, end: end)
    }

    static func hasTerminalPunctuation(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return false }
        if lastChar == "!" || lastChar == "?" || lastChar == "…" {
            return true
        }
        if lastChar == "." {
            if trimmed.hasSuffix("...") { return true }
            let withoutDot = trimmed.dropLast()
            if let prevChar = withoutDot.last, prevChar.isNumber {
                return false
            }
            let lower = trimmed.lowercased()
            let abbrevs = ["т.д.", "т.п.", "др.", "пр.", "г.", "ул.", "ст.", "руб.", "коп.", "etc.", "e.g.", "i.e.", "mr.", "mrs.", "dr."]
            if abbrevs.contains(lower) {
                return false
            }
            return true
        }
        return false
    }

    static func hasMinorPunctuation(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return false }
        return lastChar == "," || lastChar == ";" || lastChar == ":" || lastChar == "—"
    }

    static func synthesizeProportionalWords(text: String, start: Double, end: Double) -> [WordTimestamp] {
        let clean = text
            .replacingOccurrences(of: "<yellow>", with: "")
            .replacingOccurrences(of: "</yellow>", with: "")
            .replacingOccurrences(of: "<red>", with: "")
            .replacingOccurrences(of: "</red>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, end > start else { return [] }
        let tokens = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let weights = tokens.map { max(Double($0.count), 2.0) }
        let totalWeight = max(weights.reduce(0.0, +), 1.0)
        let totalDuration = end - start

        // Подсчитываем пунктуационные паузы между словами
        var numTerminalBreaks = 0
        var numMinorBreaks = 0
        for (idx, token) in tokens.enumerated() {
            guard idx < tokens.count - 1 else { continue }
            if hasTerminalPunctuation(token) {
                numTerminalBreaks += 1
            } else if hasMinorPunctuation(token) {
                numMinorBreaks += 1
            }
        }
        let hasLeadingPause = clean.hasPrefix("...") || clean.hasPrefix("…")

        // Вычисляем бюджет пауз: оставляем достаточно времени на речь (минимум 0.22с на слово или 55% хронометража)
        let minSpeechDuration = Double(tokens.count) * 0.22
        let maxPauseBudget = max(0.0, totalDuration - max(minSpeechDuration, totalDuration * 0.55))
        let desiredTotalPause = (Double(numTerminalBreaks) * 0.85) + (Double(numMinorBreaks) * 0.25) + (hasLeadingPause ? 0.40 : 0.0)

        let actualTotalPause = min(desiredTotalPause, maxPauseBudget)
        let pauseScale = desiredTotalPause > 0 ? (actualTotalPause / desiredTotalPause) : 0.0
        let terminalPause = 0.85 * pauseScale
        let minorPause = 0.25 * pauseScale
        let leadingPause = hasLeadingPause ? (0.40 * pauseScale) : 0.0

        let speechDuration = max(0.1, totalDuration - actualTotalPause)
        var current = start + leadingPause
        var result: [WordTimestamp] = []
        result.reserveCapacity(tokens.count)

        for (idx, token) in tokens.enumerated() {
            let isLast = (idx == tokens.count - 1)
            let dur = speechDuration * (weights[idx] / totalWeight)
            let wEnd = isLast ? end : min(end, current + dur)
            result.append(WordTimestamp(word: token, start: current, end: max(current, wEnd)))

            if !isLast {
                var pause = 0.0
                if hasTerminalPunctuation(token) {
                    pause = terminalPause
                } else if hasMinorPunctuation(token) {
                    pause = minorPause
                }
                current = min(end, wEnd + pause)
            } else {
                current = end
            }
        }
        return result
    }

    /// Slices the segment to `[windowStart, windowEnd]` and shifts timestamps to `timelineOffset`.
    /// When a segment straddles a cut boundary, only the words spoken within `[windowStart, windowEnd]`
    /// are kept, preventing earlier/later sentences from bleeding across scene cuts.
    func sliced(windowStart: Double, windowEnd: Double, timelineOffset: Double = 0.0) -> TranscriptSegment? {
        let windowDuration = windowEnd - windowStart
        guard windowDuration > 0, end > windowStart, start < windowEnd else { return nil }

        let isClipped = (start < windowStart - 0.05) || (end > windowEnd + 0.05)
        let allWords = resolvedWords()

        if !isClipped {
            let shiftedWords: [WordTimestamp] = allWords.compactMap { w in
                let wStart = w.start - windowStart
                let wEnd = w.end - windowStart
                guard wEnd > 0 && wStart < windowDuration else { return nil }
                return WordTimestamp(
                    word: w.word,
                    start: max(0.0, wStart) + timelineOffset,
                    end: min(windowDuration, wEnd) + timelineOffset
                )
            }
            let sStart = max(0.0, start - windowStart) + timelineOffset
            let sEnd = min(windowDuration, end - windowStart) + timelineOffset
            guard sEnd > sStart else { return nil }
            return TranscriptSegment(
                start: sStart,
                end: sEnd,
                text: text.trimmed,
                words: shiftedWords
            )
        }

        // Segment straddles a cut boundary: keep only words whose active interval overlaps the window
        let keptWords = allWords.filter { w in
            let overlapStart = max(w.start, windowStart)
            let overlapEnd = min(w.end, windowEnd)
            let wordDur = max(w.end - w.start, 0.01)
            let overlap = overlapEnd - overlapStart
            return overlap > 0.03 || (overlap / wordDur) >= 0.4
        }
        guard !keptWords.isEmpty else { return nil }

        let shiftedWords: [WordTimestamp] = keptWords.map { w in
            WordTimestamp(
                word: w.word,
                start: max(0.0, w.start - windowStart) + timelineOffset,
                end: min(windowDuration, w.end - windowStart) + timelineOffset
            )
        }
        let sStart = shiftedWords.first?.start ?? (max(0.0, start - windowStart) + timelineOffset)
        let rawEnd = shiftedWords.last?.end ?? (min(windowDuration, end - windowStart) + timelineOffset)
        let sEnd = min(timelineOffset + windowDuration, max(sStart + 0.25, rawEnd))
        guard sEnd > sStart else { return nil }

        let slicedText = (keptWords.count < allWords.count)
            ? keptWords.map(\.word).joined(separator: " ")
            : text.trimmed

        return TranscriptSegment(
            start: sStart,
            end: sEnd,
            text: slicedText,
            words: shiftedWords
        )
    }
}

/// A full transcript with timestamps. Fed to the Director to pick moments, and
/// sliced per clip to ground each caption in what's actually said there.
struct Transcript: Codable, Sendable, Equatable {
    let segments: [TranscriptSegment]
    let language: String?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Language inferred from the transcript text itself (BCP-47, e.g. "es").
    /// More reliable than Whisper's 30s auto-detect or a small model's guess —
    /// both of which mislabel (Spanish → "en" / pt-BR). Used to lock the caption
    /// language to what's actually spoken.
    var contentLanguage: String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(fullText)
        return recognizer.dominantLanguage?.rawValue
    }

    /// One `[MM:SS] text` line per segment — gives the Director timestamps to
    /// reason over.
    func srtLike() -> String {
        segments.map { "[\(Int($0.start))s] \($0.text.trimmed)" }
            .joined(separator: "\n")
    }

    /// Returns a copy of the transcript where any segments lacking word-level timestamps
    /// have synthesized punctuation-aware word timestamps populated.
    var withResolvedWordTimestamps: Transcript {
        let hasMissingWords = segments.contains(where: { $0.words.isEmpty })
        guard hasMissingWords else { return self }
        let enriched = segments.map { seg in
            if seg.words.isEmpty {
                return TranscriptSegment(start: seg.start, end: seg.end, text: seg.text, words: seg.resolvedWords())
            }
            return seg
        }
        return Transcript(segments: enriched, language: language)
    }

    /// Concatenated text of segments overlapping `[start, end]`.
    func slice(start: Double, end: Double) -> String {
        segments
            .filter { $0.end > start && $0.start < end }
            .map { $0.text.trimmed }
            .joined(separator: " ")
    }

    private static func mmss(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Produces a `Transcript` for a long video. Prefers an existing `.srt`/`.vtt`
/// sidecar (instant, no download); falls back to on-device WhisperKit only when
/// none is found — so the Whisper model never downloads for users who already
/// have transcripts.
@MainActor
@Observable
final class TranscriptionService {

    enum Phase: Equatable {
        case idle
        case downloadingModel(fraction: Double)
        /// After download: WhisperKit compiles/optimises the model for this Mac.
        /// First run only, slow, and reports no progress — hence a distinct phase
        /// so the UI doesn't sit at a misleading "Downloading 100%".
        case preparingModel
        case transcribing
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var whisper: WhisperKit?

    /// Whisper variants to prefer, best-first; falls back to the device default
    /// (`openai_whisper-base`, which is multilingual). MUST be multilingual —
    /// distil-* models are English-only and turn other languages into phonetic
    /// gibberish, so they are deliberately excluded.
    private static let preferredVariants = [
        // Full large-v3 transcribes Spanish (and other languages) reliably. The
        // turbo variant was faster on paper but mis-decoded non-English audio
        // here, so it's deliberately not preferred.
        "openai_whisper-large-v3",
        "openai_whisper-large-v3_947MB",
        "openai_whisper-small",
    ]

    // MARK: - Public

    /// Returns a transcript for `videoURL`, using a sidecar `.srt`/`.vtt` if one
    /// sits next to it, otherwise transcribing on-device. `languageHint` (e.g.
    /// "es", "Spanish") forces Whisper's decode language; empty = auto-detect.
    /// `modelCacheDir` — if set, WhisperKit downloads its model to this directory
    /// instead of the default `~/Documents/huggingface/`.
    func transcript(for videoURL: URL, languageHint: String = "", modelCacheDir: URL? = nil, correctionsService: TranscriptionCorrectionsService? = TranscriptionCorrectionsService.shared, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        if let sidecar = Self.findSidecar(for: videoURL),
           let parsed = Self.parseSubtitles(at: sidecar) {
            phase = .ready
            return parsed
        }
        if let extracted = await Self.extractEmbeddedSubtitles(for: videoURL),
           let parsed = Self.parseSubtitles(at: extracted) {
            phase = .ready
            return parsed
        }
        return try await transcribeOnDevice(videoURL, languageHint: languageHint, modelCacheDir: modelCacheDir, correctionsService: correctionsService, progress: progress)
    }

    /// True when a usable transcript exists without needing Whisper.
    static func hasSidecar(for videoURL: URL) -> Bool {
        findSidecar(for: videoURL) != nil
    }

    // MARK: - WhisperKit path

    private func transcribeOnDevice(_ videoURL: URL, languageHint: String = "", modelCacheDir: URL? = nil, correctionsService: TranscriptionCorrectionsService? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        // Full audio (no cap) → temp .m4a.
        guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
            throw TranscriptionError.noAudio
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        if whisper == nil {
            phase = .downloadingModel(fraction: 0)

            let support = WhisperKit.recommendedModels()
            let variant = Self.preferredVariants.first { support.supported.contains($0) }
                ?? support.default
            Self.log("whisper variant: \(variant) (supported: \(support.supported.joined(separator: ", ")))")

            let folder: URL
            if let local = Self.findLocalModelFolder(for: variant, modelCacheDir: modelCacheDir) {
                Self.log("using existing local whisper model at \(local.path)")
                folder = local
            } else {
                // Point HuggingFace cache to our working directory only if downloading
                if let cacheDir = modelCacheDir {
                    setenv("HUGGINGFACE_HUB_CACHE", cacheDir.path, 1)
                }

                folder = try await WhisperKit.download(variant: variant) { @Sendable [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self?.phase = fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel
                    }
                }
            }
            // Loading specialises the CoreML model for the chosen compute units.
            // WhisperKit defaults the audio encoder to the Neural Engine, whose
            // specialization of large-v3 is pathologically slow on an M1 Pro
            // (~5 min). Forcing GPU skips that ANE specialization and loads +
            // transcribes far faster, with no first-run stall.
            phase = .preparingModel
            Self.log("preparing/loading model \(variant) on GPU…")
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU)
            whisper = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path, computeOptions: compute, load: true))
            Self.log("model loaded")
        }

        guard let whisper else { throw TranscriptionError.modelUnavailable }

        phase = .transcribing
        // Force language detection (or the user's override) so Spanish audio
        // isn't silently decoded as English. `language` nil + detectLanguage true
        // makes WhisperKit pick the spoken language instead of defaulting to en.
        var options = DecodingOptions()
        options.task = .transcribe
        options.wordTimestamps = true
        if let code = Self.languageCode(from: languageHint) {
            options.language = code
            options.detectLanguage = false
            Self.log("forcing decode language: \(code)")
        } else {
            options.detectLanguage = true
        }

        // Self-learning: bias the decoder toward vocabulary the user previously
        // corrected. WhisperKit 0.18 has no `initialPrompt` string, so we
        // tokenize the prompt ourselves and pass `promptTokens`.
        if let prompt = correctionsService?.buildInitialPrompt(), !prompt.isEmpty,
           let tokens = whisper.tokenizer?.encode(text: prompt), !tokens.isEmpty {
            options.promptTokens = tokens
            Self.log("applying \(tokens.count) correction-prompt tokens")
        }

        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options) { @Sendable state in
            let windowSecs = Double(state.windowId) * 30.0
            progress?(windowSecs)
            return true
        }
        let segments: [TranscriptSegment] = results.flatMap(\.segments).compactMap { seg in
            let text = seg.text.cleanedTranscriptText
            guard !text.isEmpty else { return nil }
            let wordTimings = (seg.words ?? []).map {
                WordTimestamp(word: $0.word, start: Double($0.start), end: Double($0.end))
            }
            return TranscriptSegment(start: Double(seg.start), end: Double(seg.end), text: text, words: wordTimings)
        }
        guard !segments.isEmpty else { throw TranscriptionError.empty }
        Self.log("transcribed \(segments.count) segments, language=\(results.first?.language ?? "?")")
        let transcript = Transcript(segments: segments, language: results.first?.language)
        Self.saveSidecar(transcript: transcript, for: videoURL)
        phase = .ready
        return transcript
    }
    
    private static func formatAsSRT(transcript: Transcript) -> String {
        var lines: [String] = []
        for (index, segment) in transcript.segments.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(formatSRTTime(segment.start)) --> \(formatSRTTime(segment.end))")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
    
    private static func formatSRTTime(_ seconds: Double) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hrs, mins, secs, ms)
    }

    private static func saveSidecar(transcript: Transcript, for videoURL: URL) {
        let srtContent = formatAsSRT(transcript: transcript)
        let candidate = videoURL.deletingPathExtension().appendingPathExtension("srt")
        let jsonCandidate = videoURL.deletingPathExtension().appendingPathExtension("words.json")
        let jsonData = try? JSONEncoder().encode(transcript)
        
        do {
            try srtContent.write(to: candidate, atomically: true, encoding: .utf8)
            if let jsonData {
                try? jsonData.write(to: jsonCandidate, options: .atomic)
            }
            Self.log("saved SRT sidecar (+words.json) to \(candidate.path)")
        } catch {
            Self.log("failed to save sidecar next to video: \(error)")
            // Fallback to cache directory
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let fallback = caches.appendingPathComponent(videoURL.lastPathComponent + ".srt")
                try? srtContent.write(to: fallback, atomically: true, encoding: .utf8)
                if let jsonData {
                    let jsonFallback = caches.appendingPathComponent(videoURL.lastPathComponent + ".words.json")
                    try? jsonData.write(to: jsonFallback, options: .atomic)
                }
                Self.log("saved SRT to fallback cache: \(fallback.path)")
            }
        }
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/transcribe] \(message)\n".utf8))
    }

    /// Maps a user language hint to a Whisper 2-letter code, or nil to auto-detect.
    /// Accepts codes ("es") and common names ("Spanish", "español").
    static func languageCode(from hint: String) -> String? {
        let h = hint.trimmed.lowercased()
        guard !h.isEmpty else { return nil }
        let names: [String: String] = [
            "spanish": "es", "español": "es", "espanol": "es", "castellano": "es",
            "english": "en", "inglés": "en", "ingles": "en",
            "portuguese": "pt", "português": "pt", "portugues": "pt",
            "french": "fr", "français": "fr", "francais": "fr",
            "german": "de", "alemán": "de", "aleman": "de", "deutsch": "de",
            "italian": "it", "italiano": "it",
            "catalan": "ca", "català": "ca",
        ]
        if let mapped = names[h] { return mapped }
        if h.count == 2 { return h }     // already a code
        return nil
    }

    // MARK: - Sidecar discovery + parsing

    /// Looks for `<basename>.srt` / `<basename>.vtt` next to the video.
    private static func findSidecar(for videoURL: URL) -> URL? {
        let base = videoURL.deletingPathExtension()
        for ext in ["srt", "vtt"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Check fallback cache
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let fallback = caches.appendingPathComponent(videoURL.lastPathComponent + ".srt")
            if FileManager.default.fileExists(atPath: fallback.path) {
                return fallback
            }
        }
        return nil
    }

    /// Automatically extracts embedded Russian or primary subtitle tracks from MKV/MP4 files using ffmpeg/ffprobe
    static func extractEmbeddedSubtitles(for videoURL: URL) async -> URL? {
        let ext = videoURL.pathExtension.lowercased()
        guard ["mkv", "mp4", "m4v", "mov", "webm"].contains(ext) else { return nil }

        let srtCandidate = videoURL.deletingPathExtension().appendingPathExtension("srt")
        if FileManager.default.fileExists(atPath: srtCandidate.path) {
            return srtCandidate
        }

        let ffmpeg = BinaryDownloadService.resolveBinary("ffmpeg", workingDirectory: nil)
            ?? URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let ffprobe = BinaryDownloadService.resolveBinary("ffprobe", workingDirectory: nil)
            ?? URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")

        guard FileManager.default.isExecutableFile(atPath: ffprobe.path),
              FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            return nil
        }

        // 1. Проверяем наличие дорожек субтитров через ffprobe
        let probeTask = Process()
        probeTask.executableURL = ffprobe
        probeTask.arguments = [
            "-v", "error",
            "-show_entries", "stream=index,codec_type,codec_name:stream_tags=language,title",
            "-of", "json",
            videoURL.path
        ]
        let probePipe = Pipe()
        probeTask.standardOutput = probePipe
        do {
            try probeTask.run()
            let data = probePipe.fileHandleForReading.readDataToEndOfFile()
            probeTask.waitUntilExit()

            guard probeTask.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = json["streams"] as? [[String: Any]] else {
                return nil
            }

            let subStreams = streams.filter { ($0["codec_type"] as? String) == "subtitle" }
            guard !subStreams.isEmpty else { return nil }

            // Ищем русскую дорожку, отдавая приоритет полной дорожке (без 'forced' в названии)
            let chosenStream = subStreams.first(where: { stream in
                let tags = stream["stream_tags"] as? [String: Any] ?? stream["tags"] as? [String: Any] ?? [:]
                let lang = ((tags["language"] as? String) ?? "").lowercased()
                let title = ((tags["title"] as? String) ?? "").lowercased()
                return (lang == "rus" || lang == "ru") && !title.contains("forced")
            }) ?? subStreams.first(where: { stream in
                let tags = stream["stream_tags"] as? [String: Any] ?? stream["tags"] as? [String: Any] ?? [:]
                let lang = ((tags["language"] as? String) ?? "").lowercased()
                return lang == "rus" || lang == "ru"
            }) ?? subStreams.first(where: { stream in
                let tags = stream["stream_tags"] as? [String: Any] ?? stream["tags"] as? [String: Any] ?? [:]
                let title = ((tags["title"] as? String) ?? "").lowercased()
                return !title.contains("forced")
            }) ?? subStreams.first

            guard let targetStream = chosenStream, let streamIndex = targetStream["index"] as? Int else {
                return nil
            }

            // Извлекаем выбранную дорожку в .srt рядом с видео (или в кэш)
            let targetSRT: URL
            if FileManager.default.isWritableFile(atPath: videoURL.deletingLastPathComponent().path) {
                targetSRT = srtCandidate
            } else if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                targetSRT = caches.appendingPathComponent(videoURL.lastPathComponent + ".srt")
            } else {
                targetSRT = srtCandidate
            }

            let extractTask = Process()
            extractTask.executableURL = ffmpeg
            extractTask.arguments = [
                "-y",
                "-i", videoURL.path,
                "-map", "0:\(streamIndex)",
                "-c:s", "srt",
                targetSRT.path
            ]
            try extractTask.run()
            extractTask.waitUntilExit()

            if extractTask.terminationStatus == 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: targetSRT.path),
               (attrs[.size] as? Int64 ?? 0) > 200 {
                Self.log("extracted embedded subtitles stream \(streamIndex) to \(targetSRT.path)")
                return targetSRT
            }
        } catch {
            Self.log("failed to extract embedded subtitles: \(error)")
        }
        return nil
    }

    /// Looks for a pre-downloaded Whisper CoreML model folder on the local machine
    /// before making any remote network requests.
    static func findLocalModelFolder(for variant: String, modelCacheDir: URL? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var searchRoots: [URL] = [
            home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml"),
            home.appendingPathComponent("Documents/huggingface/models"),
            home.appendingPathComponent("Documents/huggingface"),
            home.appendingPathComponent(".cache/huggingface/hub"),
            home.appendingPathComponent("Library/Caches/huggingface/hub")
        ]
        if let custom = modelCacheDir {
            searchRoots.insert(custom.appendingPathComponent("models/argmaxinc/whisperkit-coreml"), at: 0)
            searchRoots.insert(custom, at: 0)
        }

        for root in searchRoots {
            let direct = root.appendingPathComponent(variant)
            if isValidModelFolder(direct) {
                return direct
            }
            if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for entry in entries where entry.lastPathComponent.contains(variant) {
                    if isValidModelFolder(entry) {
                        return entry
                    }
                }
            }
        }
        return nil
    }

    private static func isValidModelFolder(_ url: URL) -> Bool {
        let encoder = url.appendingPathComponent("AudioEncoder.mlmodelc")
        let decoder = url.appendingPathComponent("TextDecoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) && FileManager.default.fileExists(atPath: decoder.path)
    }

    /// Parses an `.srt` or `.vtt` file into a `Transcript`. Tolerant of both
    /// `,` and `.` millisecond separators and optional cue indices/headers.
    /// If a companion `.words.json` exists with matching segment count, merges word-level timestamps.
    static func parseSubtitles(at url: URL) -> Transcript? {
        let jsonCompanion = url.deletingPathExtension().appendingPathExtension("words.json")
        if let data = try? Data(contentsOf: jsonCompanion),
           let decoded = try? JSONDecoder().decode(Transcript.self, from: data),
           !decoded.segments.isEmpty {
            return decoded
        }

        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var segments: [TranscriptSegment] = []
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        
        var currentStart: Double?
        var currentEnd: Double?
        var currentTextLines: [String] = []
        
        func commitSegment() {
            if let s = currentStart, let e = currentEnd {
                let text = currentTextLines.joined(separator: " ").cleanedTranscriptText
                if !text.isEmpty {
                    segments.append(TranscriptSegment(start: s, end: e, text: text))
                }
            }
            currentStart = nil
            currentEnd = nil
            currentTextLines = []
        }
        
        for line in lines {
            if line.contains("-->") {
                commitSegment()
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2, let s = timecode(parts[0]), let e = timecode(parts[1]) {
                    currentStart = s
                    currentEnd = e
                }
            } else {
                if currentStart != nil {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if !trimmedLine.isEmpty {
                        currentTextLines.append(trimmedLine)
                    }
                }
            }
        }
        commitSegment()
        
        guard !segments.isEmpty else { return nil }
        return Transcript(segments: segments, language: nil)
    }

    /// Parses `HH:MM:SS,mmm` / `MM:SS.mmm` (cue settings after the time ignored).
    static func timecode(_ raw: String) -> Double? {
        let token = raw.trimmed
            .split(separator: " ").first.map(String.init) ?? raw.trimmed
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":").map { Double($0) ?? 0 }
        switch fields.count {
        case 3: return fields[0] * 3600 + fields[1] * 60 + fields[2]
        case 2: return fields[0] * 60 + fields[1]
        case 1: return fields[0]
        default: return nil
        }
    }
}

enum TranscriptionError: LocalizedError {
    case noAudio
    case modelUnavailable
    case empty

    var errorDescription: String? {
        switch self {
        case .noAudio:          return "That video has no audio to transcribe."
        case .modelUnavailable: return "The transcription model couldn't be loaded."
        case .empty:            return "No speech was found in that video."
        }
    }
}
