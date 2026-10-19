import Foundation
import NaturalLanguage
import Observation
import CryptoKit
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
}

/// Who produced a transcript. Whisper is the only authoritative source in this
/// app, so anything we cannot *prove* we authored ourselves is `foreign` —
/// fansub `.srt` files sitting next to a video are indistinguishable from our
/// own output by name alone, so provenance is carried on the model, not inferred
/// from file naming.
enum TranscriptProvenance: String, Codable, Sendable, Equatable {
    /// Produced on this device by our own Whisper run.
    case whisper
    /// Our own sidecar we previously wrote and just verified via its authorship
    /// marker (`TranscriptSidecarMarker`).
    case cache
    /// A sidecar we did not author, a legacy archive with no recorded provenance,
    /// or anything else of unknown origin. Never authoritative.
    case foreign

    /// Only files this app provably produced are trusted for reuse.
    var isOurs: Bool { self != .foreign }
}

/// A full transcript with timestamps. Fed to the Director to pick moments, and
/// sliced per clip to ground each caption in what's actually said there.
struct Transcript: Codable, Sendable, Equatable {
    let segments: [TranscriptSegment]
    let language: String?
    /// Where the text came from. Defaults to `foreign`: constructing a transcript
    /// without declaring its source must not silently claim Whisper authorship.
    let provenance: TranscriptProvenance

    init(
        segments: [TranscriptSegment],
        language: String?,
        provenance: TranscriptProvenance = .foreign
    ) {
        self.segments = segments
        self.language = language
        self.provenance = provenance
    }

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Same text, declared source. Used once a sidecar's provenance has been
    /// settled by the marker gate (`sidecarDecision(for:)` → `.cache`).
    func withProvenance(_ provenance: TranscriptProvenance) -> Transcript {
        Transcript(segments: segments, language: language, provenance: provenance)
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

    enum CodingKeys: String, CodingKey {
        case segments, language, provenance
    }

    /// Hand-written for ONE reason: `Transcript` is stored inside every
    /// `.shortcastproj` archive, and archives written before provenance existed
    /// have no `provenance` key. A synthesized non-optional field would make
    /// those archives throw — so absent/unknown decodes as `.foreign`, never as
    /// "it's ours".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        segments = try container.decode([TranscriptSegment].self, forKey: .segments)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        // `try?` also swallows an unrecognised case value (a newer app version
        // writing "fansub" or similar) — an unverifiable label is foreign.
        provenance = (try? container.decode(TranscriptProvenance.self, forKey: .provenance)) ?? .foreign
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(provenance, forKey: .provenance)
    }
}

/// Machine-readable proof of authorship, written next to every subtitle sidecar
/// Shortcast itself produced.
///
/// Path convention: `<sidecar>.shortcast.json` — e.g.
/// `movie.mkv` → `movie.srt` → `movie.srt.shortcast.json`
/// (the caches fallback `…/Caches/<name>.mkv.srt` gets `…/<name>.mkv.srt.shortcast.json`).
///
/// Naming alone proves nothing: our own Whisper output is written as
/// `<video>.srt`, exactly the pattern a release-group fansub uses. So a sidecar
/// is only reused when this file exists, decodes and still matches the bytes on
/// disk. Absent marker ⇒ foreign file ⇒ Whisper runs.
struct TranscriptSidecarMarker: Codable, Sendable, Equatable {
    /// Bump when the shape changes. Markers on a different schema are rejected
    /// rather than trusted.
    static let schemaVersion = 1

    let schema: Int
    /// `.whisper` when written, `.cache` when the same file is read back later.
    let provenance: TranscriptProvenance
    /// Whisper variant that produced the text, e.g. `openai_whisper-large-v3`.
    let model: String?
    let language: String?
    let segmentCount: Int
    let sourceSizeBytes: Int64
    let sourceModifiedAt: Date?
    let sourceChecksumSHA256: String?
    let writtenAt: Date
}

/// Why a subtitle file next to a video cannot be trusted. Stable `rawValue` for
/// log lines and provenance badges.
enum ForeignSidecarReason: String, Codable, Sendable, Equatable, CaseIterable {
    case missingMarker
    case unreadableMarker
    case unsupportedMarkerSchema
    case markerClaimsForeignProvenance
    case sidecarUnreadable
    case sizeMismatch
    case checksumMismatch
    case modifiedAfterMarker
    case modifiedAtMismatch
    case noIntegrityProof
    case segmentCountMismatch
    case emptySidecar
}

/// Verdict of the provenance gate — the pure seam `transcript(for:)` branches on
/// and the UI can render as a provenance badge without running anything.
enum SidecarDecision: Sendable, Equatable {
    /// No `.srt`/`.vtt` next to the video at all.
    case noSidecar
    /// Marker validates: the file is ours, reuse it, Whisper never runs.
    case verified(url: URL, provenance: TranscriptProvenance)
    /// Not provably ours: ignore the file entirely and transcribe on device.
    case foreign(url: URL, reason: ForeignSidecarReason)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var sidecarURL: URL? {
        switch self {
        case .noSidecar: return nil
        case .verified(let url, _), .foreign(let url, _): return url
        }
    }

    var foreignReason: ForeignSidecarReason? {
        if case .foreign(_, let reason) = self { return reason }
        return nil
    }

    /// Provenance the resulting `Transcript` will carry if a transcript is
    /// requested for this video right now.
    var expectedTranscriptProvenance: TranscriptProvenance {
        switch self {
        case .verified(_, let provenance): return provenance
        case .noSidecar, .foreign: return .whisper
        }
    }
}

/// The slice of the file system the provenance gate looks at. Injectable so the
/// decision is testable from temp files — no WhisperKit, no model, no film.
protocol SidecarFileReading: Sendable {
    func exists(_ url: URL) -> Bool
    func size(of url: URL) -> Int64?
    func modifiedAt(of url: URL) -> Date?
    func data(from url: URL) -> Data?
}

/// Timestamp slack when a marker carries no content hash: coarse-grained volumes
/// can round mtimes. A genuine hand-edit is seconds-to-hours later, never 2s.
private let sidecarTimestampTolerance: TimeInterval = 2.0

/// Real disk.
struct FileSystemSidecarReader: SidecarFileReading {
    private func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func size(of url: URL) -> Int64? {
        (attributes(url)?[.size] as? NSNumber)?.int64Value
    }

    func modifiedAt(of url: URL) -> Date? {
        attributes(url)?[.modificationDate] as? Date
    }

    func data(from url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

/// Produces a `Transcript` for a long video. Whisper is the only authoritative
/// source: a `.srt`/`.vtt` next to the video is reused ONLY when its authorship
/// marker proves Shortcast wrote it (`TranscriptSidecarMarker`). Everything else
/// — fansub rips, hand-edited files, files of unknown origin — is ignored and
/// the audio is transcribed on device. Container subtitle streams are never read.
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
    /// Variant behind the last on-device run, recorded into the sidecar's
    /// authorship marker so a cached transcript says which model made it.
    private var activeModelVariant: String?

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

    /// Returns a transcript for `videoURL`. A sidecar `.srt`/`.vtt` is reused ONLY
    /// if its authorship marker proves Shortcast wrote it; any other subtitle file
    /// next to the video is ignored and the audio is transcribed on device with
    /// Whisper (the only authoritative source). `languageHint` (e.g. "es",
    /// "Spanish") forces Whisper's decode language; empty = auto-detect.
    /// `modelCacheDir` — if set, WhisperKit downloads its model to this directory
    /// instead of the default `~/Documents/huggingface/`.
    func transcript(for videoURL: URL, languageHint: String = "", modelCacheDir: URL? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        switch Self.sidecarDecision(for: videoURL) {
        case .noSidecar:
            break
        case .verified(let sidecar, let provenance):
            if let parsed = Self.parseSubtitles(at: sidecar) {
                phase = .ready
                Self.log("reusing our own \(provenance.rawValue) sidecar: \(sidecar.lastPathComponent) (\(parsed.segments.count) segments)")
                return parsed.withProvenance(provenance)
            }
            Self.log("marker validated but \(sidecar.lastPathComponent) no longer parses — transcribing on device")
        case .foreign(let sidecar, let reason):
            // The whole point: a file we did not author never becomes the essay's
            // transcript, no matter how convincing its name or its contents look.
            Self.log("FOREIGN transcript file ignored (\(reason.rawValue)): \(sidecar.path) — it is not Shortcast's own Whisper output; transcribing audio on device instead.")
        }
        return try await transcribeOnDevice(videoURL, languageHint: languageHint, modelCacheDir: modelCacheDir, progress: progress)
    }

    /// True when a transcript Shortcast itself wrote already exists — i.e. when
    /// Whisper can be skipped. A foreign sidecar returns false.
    static func hasSidecar(for videoURL: URL) -> Bool {
        sidecarDecision(for: videoURL).isVerified
    }

    // MARK: - Provenance gate (pure, no Whisper, no model, no network)

    /// THE decision seam: may the subtitle file next to `videoURL` be reused, or is
    /// it a foreign file we must ignore? Reads files only — never instantiates
    /// WhisperKit, never touches a video or the network — so it is directly testable
    /// and is what a provenance badge should render.
    nonisolated static func sidecarDecision(
        for videoURL: URL,
        reader: SidecarFileReading = FileSystemSidecarReader(),
        cachesDir: URL? = defaultCachesDir()
    ) -> SidecarDecision {
        guard let sidecar = findSidecar(for: videoURL, reader: reader, cachesDir: cachesDir) else {
            return .noSidecar
        }
        return sidecarDecision(forSidecar: sidecar, reader: reader)
    }

    /// Same verdict for an already-resolved sidecar path.
    nonisolated static func sidecarDecision(
        forSidecar sidecar: URL,
        reader: SidecarFileReading = FileSystemSidecarReader()
    ) -> SidecarDecision {
        let markerURL = sidecarMarkerURL(for: sidecar)
        guard reader.exists(markerURL) else {
            return .foreign(url: sidecar, reason: .missingMarker)
        }
        guard let marker = loadSidecarMarker(at: markerURL, reader: reader) else {
            return .foreign(url: sidecar, reason: .unreadableMarker)
        }
        guard marker.schema == TranscriptSidecarMarker.schemaVersion else {
            return .foreign(url: sidecar, reason: .unsupportedMarkerSchema)
        }
        guard marker.provenance.isOurs else {
            return .foreign(url: sidecar, reason: .markerClaimsForeignProvenance)
        }
        guard let size = reader.size(of: sidecar) else {
            return .foreign(url: sidecar, reason: .sidecarUnreadable)
        }
        guard size == marker.sourceSizeBytes else {
            return .foreign(url: sidecar, reason: .sizeMismatch)
        }
        guard let contents = reader.data(from: sidecar) else {
            return .foreign(url: sidecar, reason: .sidecarUnreadable)
        }
        if let expected = marker.sourceChecksumSHA256 {
            // Content proof first: a matching hash means the bytes are exactly what
            // we wrote, so no later touch can make a foreign file look like ours.
            // A hand-edit changes the bytes and fails here.
            guard sha256Hex(of: contents) == expected else {
                return .foreign(url: sidecar, reason: .checksumMismatch)
            }
        } else {
            // Marker without a hash (older writes): fall back to timestamps, which
            // catch a file saved over after we wrote it.
            guard let modified = reader.modifiedAt(of: sidecar) else {
                return .foreign(url: sidecar, reason: .sidecarUnreadable)
            }
            if let markerWritten = reader.modifiedAt(of: markerURL), modified > markerWritten {
                return .foreign(url: sidecar, reason: .modifiedAfterMarker)
            }
            guard let recorded = marker.sourceModifiedAt else {
                return .foreign(url: sidecar, reason: .noIntegrityProof)
            }
            guard abs(modified.timeIntervalSince(recorded)) <= sidecarTimestampTolerance else {
                return .foreign(url: sidecar, reason: .modifiedAtMismatch)
            }
        }
        // A hand-edited or truncated file can keep a plausible size; the number of
        // cues we wrote must still come out of the parser.
        guard let parsed = parseSubtitles(data: contents) else {
            return .foreign(url: sidecar, reason: .emptySidecar)
        }
        guard parsed.segments.count == marker.segmentCount else {
            return .foreign(url: sidecar, reason: .segmentCountMismatch)
        }
        return .verified(url: sidecar, provenance: .cache)
    }

    /// `<sidecar>.shortcast.json` — the authorship marker for one sidecar.
    nonisolated static func sidecarMarkerURL(for sidecar: URL) -> URL {
        sidecar.deletingLastPathComponent()
            .appendingPathComponent(sidecar.lastPathComponent + ".shortcast.json")
    }

    nonisolated static func loadSidecarMarker(
        at markerURL: URL,
        reader: SidecarFileReading = FileSystemSidecarReader()
    ) -> TranscriptSidecarMarker? {
        guard let data = reader.data(from: markerURL) else { return nil }
        return sidecarMarker(from: data)
    }

    nonisolated static func sidecarMarker(from data: Data) -> TranscriptSidecarMarker? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranscriptSidecarMarker.self, from: data)
    }

    nonisolated static func sidecarMarkerData(_ marker: TranscriptSidecarMarker) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(marker)
    }

    /// Stamp a sidecar we just wrote with its authorship marker. Returns nil (and
    /// writes nothing) for text we can't prove is ours — we never vouch for it.
    @discardableResult
    nonisolated static func writeSidecarMarker(
        forSidecar sidecar: URL,
        transcript: Transcript,
        model: String?,
        reader: SidecarFileReading = FileSystemSidecarReader()
    ) -> TranscriptSidecarMarker? {
        guard transcript.provenance.isOurs else {
            Self.log("refusing to stamp \(sidecar.lastPathComponent): provenance \(transcript.provenance.rawValue) is not ours")
            return nil
        }
        guard let size = reader.size(of: sidecar) else {
            Self.log("no marker written for \(sidecar.lastPathComponent): the sidecar isn't on disk")
            return nil
        }
        let marker = TranscriptSidecarMarker(
            schema: TranscriptSidecarMarker.schemaVersion,
            provenance: transcript.provenance,
            model: model,
            language: transcript.language,
            segmentCount: transcript.segments.count,
            sourceSizeBytes: size,
            sourceModifiedAt: reader.modifiedAt(of: sidecar),
            sourceChecksumSHA256: reader.data(from: sidecar).map { sha256Hex(of: $0) },
            writtenAt: Date()
        )
        guard let data = sidecarMarkerData(marker) else { return nil }
        let markerURL = sidecarMarkerURL(for: sidecar)
        do {
            try data.write(to: markerURL, options: .atomic)
            Self.log("wrote authorship marker \(markerURL.lastPathComponent) (model=\(model ?? "?"), cues=\(marker.segmentCount))")
            return marker
        } catch {
            Self.log("failed to write marker for \(sidecar.lastPathComponent): \(error)")
            return nil
        }
    }

    nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func defaultCachesDir() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    // MARK: - WhisperKit path

    private func transcribeOnDevice(_ videoURL: URL, languageHint: String = "", modelCacheDir: URL? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        // Full audio (no cap) → temp .m4a.
        guard let audioURL = try await MediaExtractor.extractAudio(from: videoURL, maxSeconds: nil) else {
            throw TranscriptionError.noAudio
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        if whisper == nil {
            phase = .downloadingModel(fraction: 0)

            // Point HuggingFace cache to our working directory so the model
            // lands in an accessible location instead of ~/Documents/huggingface/.
            if let cacheDir = modelCacheDir {
                setenv("HUGGINGFACE_HUB_CACHE", cacheDir.path, 1)
            }

            let support = WhisperKit.recommendedModels()
            let variant = Self.preferredVariants.first { support.supported.contains($0) }
                ?? support.default
            activeModelVariant = variant
            Self.log("whisper variant: \(variant) (supported: \(support.supported.joined(separator: ", ")))")
            let folder = try await WhisperKit.download(variant: variant) { @Sendable [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    self?.phase = fraction < 1.0 ? .downloadingModel(fraction: fraction) : .preparingModel
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
        // This is the ONLY place a transcript becomes authoritative: text we ran
        // through Whisper on this device, right now.
        let transcript = Transcript(segments: segments, language: results.first?.language, provenance: .whisper)
        Self.saveSidecar(transcript: transcript, for: videoURL, model: activeModelVariant)
        phase = .ready
        return transcript
    }
    
    nonisolated static func formatAsSRT(transcript: Transcript) -> String {
        var lines: [String] = []
        for (index, segment) in transcript.segments.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(formatSRTTime(segment.start)) --> \(formatSRTTime(segment.end))")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
    
    nonisolated static func formatSRTTime(_ seconds: Double) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hrs, mins, secs, ms)
    }

    /// Writes our transcript as `<video>.srt` **and** its authorship marker
    /// (`<video>.srt.shortcast.json`). The marker is what makes the file reusable:
    /// a bare `.srt` next to a video is a stranger until proven ours.
    nonisolated static func saveSidecar(transcript: Transcript, for videoURL: URL, model: String?) {
        guard transcript.provenance.isOurs else {
            Self.log("not writing a sidecar for \(videoURL.lastPathComponent): provenance \(transcript.provenance.rawValue) is not ours")
            return
        }
        let srtContent = formatAsSRT(transcript: transcript)
        let candidate = videoURL.deletingPathExtension().appendingPathExtension("srt")

        do {
            try srtContent.write(to: candidate, atomically: true, encoding: .utf8)
            Self.log("saved SRT sidecar to \(candidate.path)")
            writeSidecarMarker(forSidecar: candidate, transcript: transcript, model: model)
        } catch {
            Self.log("failed to save sidecar next to video: \(error)")
            // Fallback to cache directory — stamped the same way, or it won't be
            // trusted on the next run either.
            if let caches = defaultCachesDir() {
                let fallback = caches.appendingPathComponent(videoURL.lastPathComponent + ".srt")
                do {
                    try srtContent.write(to: fallback, atomically: true, encoding: .utf8)
                    Self.log("saved SRT to fallback cache: \(fallback.path)")
                    writeSidecarMarker(forSidecar: fallback, transcript: transcript, model: model)
                } catch {
                    Self.log("failed to save SRT to fallback cache: \(error)")
                }
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

    /// Looks for `<basename>.srt` / `<basename>.vtt` next to the video, then the
    /// caches fallback. Finding a file is NOT permission to use it: every caller
    /// must run the video through `sidecarDecision(for:)` first.
    nonisolated static func findSidecar(
        for videoURL: URL,
        reader: SidecarFileReading = FileSystemSidecarReader(),
        cachesDir: URL? = defaultCachesDir()
    ) -> URL? {
        let base = videoURL.deletingPathExtension()
        for ext in ["srt", "vtt"] {
            let candidate = base.appendingPathExtension(ext)
            if reader.exists(candidate) {
                return candidate
            }
        }
        // Check fallback cache
        if let cachesDir {
            let fallback = cachesDir.appendingPathComponent(videoURL.lastPathComponent + ".srt")
            if reader.exists(fallback) {
                return fallback
            }
        }
        return nil
    }

    /// Parses an `.srt` or `.vtt` file into a `Transcript`. Tolerant of both
    /// `,` and `.` millisecond separators and optional cue indices/headers.
    /// The result carries `.foreign` provenance — parsing can't know who wrote the
    /// file, so only `sidecarDecision(for:)` may upgrade it (`.withProvenance(.cache)`).
    nonisolated static func parseSubtitles(at url: URL) -> Transcript? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseSubtitleText(raw)
    }

    /// Same parse over bytes already read — what the provenance gate uses, so it
    /// never hits the disk twice and stays drivable by a fake reader.
    nonisolated static func parseSubtitles(data: Data) -> Transcript? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseSubtitleText(raw)
    }

    nonisolated static func parseSubtitleText(_ raw: String) -> Transcript? {
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
            } else if line.trimmed.isEmpty {
                // A blank line closes a cue block. Without this the next cue's index
                // number leaks into the previous cue's text, so our own sidecar
                // wouldn't round-trip — and a round-trip we can't trust isn't a cache.
                commitSegment()
            } else if currentStart != nil {
                currentTextLines.append(line.trimmed)
            }
        }
        commitSegment()
        
        guard !segments.isEmpty else { return nil }
        return Transcript(segments: segments, language: nil)
    }

    /// Parses `HH:MM:SS,mmm` / `MM:SS.mmm` (cue settings after the time ignored).
    nonisolated static func timecode(_ raw: String) -> Double? {
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
