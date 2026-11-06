import Testing
import Foundation
@testable import Shortcast

/// Whisper is the only authoritative transcript source, so a subtitle file found
/// next to a video means nothing until its authorship marker proves Shortcast
/// wrote it. These tests pin that gate — and the Codable backward compatibility
/// of `Transcript.provenance` inside `.shortcastproj` archives.
///
/// Hermetic by construction: temp directories only. No WhisperKit is created, no
/// model is downloaded, no network is used, no film is read. Every assertion runs
/// against the pure decision seam (`TranscriptionService.sidecarDecision(for:)`),
/// which is exactly what `transcript(for:)` branches on before deciding whether
/// on-device Whisper has to run.
@Suite("Transcript provenance gate")
@MainActor
struct TranscriptionProvenanceTests {

    /// What a release-group fansub looks like on disk: our exact naming pattern,
    /// someone else's words. (Shape taken from the real Blade Runner 2049 file.)
    private static let fansubSRT = """
    1
    00:00:26,340 --> 00:00:29,180
    Sous-titres par LaVacheSquid

    2
    00:00:30,000 --> 00:00:31,500
    Thank you.

    3
    00:01:00,000 --> 00:01:02,000
    ♪♪

    4
    00:59:10,000 --> 00:59:13,000
    © transcript Emily Beynon

    """

    /// Our own Whisper output, as the on-device path would write it.
    private static let whisperTranscript = Transcript(segments: [
        TranscriptSegment(start: 10.0, end: 13.0, text: "Первая реплика.", words: []),
        TranscriptSegment(start: 20.0, end: 24.0, text: "Вторая реплика.", words: []),
    ], language: "ru", provenance: .whisper)

    // MARK: - Helpers

    private func makeDir(_ name: String = "input") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-provenance-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    /// A stand-in for the 9.8 GB film: the gate never opens it.
    private func makeVideo(in dir: URL, named name: String = "Той_що_біжить_по_лезу_2049_Blade_Runner_2049.mkv") throws -> URL {
        let video = dir.appendingPathComponent(name)
        try Data([0x00]).write(to: video)
        return video
    }

    private func sidecar(of video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func bytes(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.size] as? NSNumber)?.int64Value)
    }

    private func fileModifiedAt(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    private func setModifiedAt(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func marker(of sidecar: URL) throws -> TranscriptSidecarMarker {
        try #require(TranscriptionService.loadSidecarMarker(
            at: TranscriptionService.sidecarMarkerURL(for: sidecar)))
    }

    private func writeMarker(_ marker: TranscriptSidecarMarker, for sidecar: URL) throws {
        let data = try #require(TranscriptionService.sidecarMarkerData(marker))
        try data.write(to: TranscriptionService.sidecarMarkerURL(for: sidecar), options: .atomic)
    }

    /// The gate as production uses it, pinned to no caches dir so the real caches
    /// folder can never leak into a verdict.
    private func decide(_ video: URL) -> SidecarDecision {
        TranscriptionService.sidecarDecision(for: video, cachesDir: nil)
    }

    // MARK: - The bypass is closed

    @Test("a sidecar with no authorship marker is ignored, so Whisper runs on device")
    func foreignSidecarWithoutMarkerIsIgnored() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir)
        let srt = sidecar(of: video)
        try write(Self.fansubSRT, to: srt)

        // The file is perfectly parseable — that's the point: rejection is about
        // provenance, not about whether the text looks usable.
        let parsed = try #require(TranscriptionService.parseSubtitles(at: srt))
        #expect(parsed.segments.count == 4)
        #expect(parsed.segments.first?.text == "Sous-titres par LaVacheSquid")

        let decision = decide(video)
        #expect(decision == .foreign(url: srt, reason: .missingMarker))
        #expect(decision.isVerified == false)
        #expect(decision.foreignReason == .missingMarker)
        #expect(TranscriptionService.hasSidecar(for: video) == false)
        // Both `.noSidecar` and `.foreign` route to on-device Whisper: that is the
        // seam `transcript(for:)` switches on, so nothing else can be transcribed.
        #expect(decision.expectedTranscriptProvenance == .whisper)

        // Nothing is deleted or edited: the file stays as evidence for the user.
        #expect(FileManager.default.fileExists(atPath: srt.path))
        let onDisk = try String(contentsOf: srt, encoding: .utf8)
        #expect(onDisk == Self.fansubSRT)
        #expect(!FileManager.default.fileExists(
            atPath: TranscriptionService.sidecarMarkerURL(for: srt).path))

        cleanup(dir)
    }

    @Test("our own sidecar with a validating marker is reused as cache")
    func ourSidecarWithMarkerIsReusedAsCache() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "whisper_run.mkv")
        TranscriptionService.saveSidecar(
            transcript: Self.whisperTranscript,
            for: video,
            model: "openai_whisper-large-v3"
        )
        let srt = sidecar(of: video)

        let decision = decide(video)
        #expect(decision == .verified(url: srt, provenance: .cache))
        #expect(decision.isVerified == true)
        #expect(decision.expectedTranscriptProvenance == .cache)
        #expect(TranscriptionService.hasSidecar(for: video) == true)

        // Provenance propagates honestly to the value callers display.
        let fromSidecar = try #require(TranscriptionService.parseSubtitles(at: srt))
        let reused = fromSidecar.withProvenance(.cache)
        #expect(fromSidecar.provenance == .foreign)
        #expect(reused.provenance == .cache)
        #expect(reused.provenance.isOurs == true)
        #expect(reused.segments.count == 2)

        cleanup(dir)
    }

    @Test("the caches fallback sidecar is gated the same way")
    func cachesFallbackIsAlsoGated() throws {
        let input = try makeDir("input")
        let caches = try makeDir("caches")
        let video = input.appendingPathComponent("fallback_film.mkv")
        let fallback = caches.appendingPathComponent("fallback_film.mkv.srt")
        try write(Self.fansubSRT, to: fallback)

        #expect(TranscriptionService.findSidecar(for: video, cachesDir: caches) == fallback)
        #expect(
            TranscriptionService.sidecarDecision(for: video, cachesDir: caches)
                == .foreign(url: fallback, reason: .missingMarker)
        )

        // Same location, our own bytes, our own stamp: now it is trustworthy.
        try write(TranscriptionService.formatAsSRT(transcript: Self.whisperTranscript), to: fallback)
        let stamped = TranscriptionService.writeSidecarMarker(
            forSidecar: fallback,
            transcript: Self.whisperTranscript,
            model: "openai_whisper-large-v3"
        )
        #expect(stamped?.segmentCount == 2)
        #expect(
            TranscriptionService.sidecarDecision(for: video, cachesDir: caches)
                == .verified(url: fallback, provenance: .cache)
        )

        cleanup(input)
        cleanup(caches)
    }

    @Test("a video with no sidecar has nothing to distrust")
    func noSidecarIsNotForeign() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "clean.mkv")

        #expect(decide(video) == .noSidecar)
        #expect(decide(video).sidecarURL == nil)
        #expect(decide(video).foreignReason == nil)
        #expect(decide(video).expectedTranscriptProvenance == .whisper)
        #expect(TranscriptionService.hasSidecar(for: video) == false)

        cleanup(dir)
    }

    // MARK: - Marker mismatches

    @Test("a marker whose recorded size disagrees is rejected")
    func sizeMismatchIsRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "resize.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)

        try write(Self.fansubSRT, to: srt)   // hand-replaced content, different length

        #expect(decide(video) == .foreign(url: srt, reason: .sizeMismatch))

        cleanup(dir)
    }

    @Test("a marker whose checksum disagrees is rejected")
    func checksumMismatchIsRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "swap.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)
        let original = try bytes(of: srt)

        // Exactly the same byte length, different words: only the hash sees it.
        let swapped = String(repeating: "x", count: original.count)
        #expect(Data(swapped.utf8).count == original.count)
        try write(swapped, to: srt)

        #expect(decide(video) == .foreign(url: srt, reason: .checksumMismatch))

        cleanup(dir)
    }

    @Test("a marker whose segment count disagrees with the file is rejected")
    func segmentCountMismatchIsRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "cuedit.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)

        let extraCue = """
        3
        00:00:30,000 --> 00:00:33,000
        Третья реплика, добавленная руками.

        """
        let edited = try bytes(of: srt) + Data(extraCue.utf8)
        try edited.write(to: srt)

        // Re-attest the file honestly in every field except the cue count.
        let old = try marker(of: srt)
        let editedSize = try fileSize(of: srt)
        let editedModified = try fileModifiedAt(of: srt)
        let editedChecksum = TranscriptionService.sha256Hex(of: edited)
        try writeMarker(
            TranscriptSidecarMarker(
                schema: old.schema,
                provenance: old.provenance,
                model: old.model,
                language: old.language,
                segmentCount: 2,
                sourceSizeBytes: editedSize,
                sourceModifiedAt: editedModified,
                sourceChecksumSHA256: editedChecksum,
                writtenAt: old.writtenAt
            ),
            for: srt
        )

        #expect(TranscriptionService.parseSubtitles(at: srt)?.segments.count == 3)
        #expect(decide(video) == .foreign(url: srt, reason: .segmentCountMismatch))

        cleanup(dir)
    }

    @Test("a sidecar touched after its marker was written is rejected")
    func modifiedAfterMarkerIsRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "touch.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)
        let old = try marker(of: srt)
        let size = try fileSize(of: srt)
        let modified = try fileModifiedAt(of: srt)

        // A marker from a build that recorded no hash: timestamps are the guard.
        try writeMarker(
            TranscriptSidecarMarker(
                schema: old.schema,
                provenance: old.provenance,
                model: old.model,
                language: old.language,
                segmentCount: old.segmentCount,
                sourceSizeBytes: size,
                sourceModifiedAt: modified,
                sourceChecksumSHA256: nil,
                writtenAt: old.writtenAt
            ),
            for: srt
        )
        // ...and the subtitle file was saved over afterwards, by hand.
        try setModifiedAt(Date().addingTimeInterval(60), of: srt)

        #expect(decide(video) == .foreign(url: srt, reason: .modifiedAfterMarker))

        cleanup(dir)
    }

    @Test("a marker whose recorded mtime no longer matches is rejected")
    func modifiedAtMismatchIsRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "stale.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)
        let old = try marker(of: srt)
        let size = try fileSize(of: srt)

        try writeMarker(
            TranscriptSidecarMarker(
                schema: old.schema,
                provenance: old.provenance,
                model: old.model,
                language: old.language,
                segmentCount: old.segmentCount,
                sourceSizeBytes: size,
                sourceModifiedAt: Date().addingTimeInterval(-3600),   // hours off
                sourceChecksumSHA256: nil,
                writtenAt: old.writtenAt
            ),
            for: srt
        )

        #expect(decide(video) == .foreign(url: srt, reason: .modifiedAtMismatch))

        cleanup(dir)
    }

    @Test("a marker with neither a hash nor a recorded mtime proves nothing")
    func markerWithoutIntegrityProofIsRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "bare.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)
        let old = try marker(of: srt)
        let size = try fileSize(of: srt)

        try writeMarker(
            TranscriptSidecarMarker(
                schema: old.schema,
                provenance: old.provenance,
                model: old.model,
                language: old.language,
                segmentCount: old.segmentCount,
                sourceSizeBytes: size,
                sourceModifiedAt: nil,
                sourceChecksumSHA256: nil,
                writtenAt: old.writtenAt
            ),
            for: srt
        )

        #expect(decide(video) == .foreign(url: srt, reason: .noIntegrityProof))

        cleanup(dir)
    }

    @Test("garbage, future-schema and foreign markers never vouch for a file")
    func malformedMarkersAreRejected() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "junk.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)
        let old = try marker(of: srt)
        let markerURL = TranscriptionService.sidecarMarkerURL(for: srt)

        try "not json at all".write(to: markerURL, atomically: true, encoding: .utf8)
        #expect(decide(video) == .foreign(url: srt, reason: .unreadableMarker))

        try writeMarker(
            TranscriptSidecarMarker(
                schema: old.schema + 1,
                provenance: .whisper,
                model: old.model,
                language: old.language,
                segmentCount: old.segmentCount,
                sourceSizeBytes: old.sourceSizeBytes,
                sourceModifiedAt: old.sourceModifiedAt,
                sourceChecksumSHA256: old.sourceChecksumSHA256,
                writtenAt: old.writtenAt
            ),
            for: srt
        )
        #expect(decide(video) == .foreign(url: srt, reason: .unsupportedMarkerSchema))

        try writeMarker(
            TranscriptSidecarMarker(
                schema: old.schema,
                provenance: .foreign,
                model: old.model,
                language: old.language,
                segmentCount: old.segmentCount,
                sourceSizeBytes: old.sourceSizeBytes,
                sourceModifiedAt: old.sourceModifiedAt,
                sourceChecksumSHA256: old.sourceChecksumSHA256,
                writtenAt: old.writtenAt
            ),
            for: srt
        )
        #expect(decide(video) == .foreign(url: srt, reason: .markerClaimsForeignProvenance))

        cleanup(dir)
    }

    // MARK: - Marker writing

    @Test("marker writing round-trips and attests the bytes on disk")
    func markerRoundTrip() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "roundtrip.mkv")
        TranscriptionService.saveSidecar(
            transcript: Self.whisperTranscript,
            for: video,
            model: "openai_whisper-large-v3"
        )
        let srt = sidecar(of: video)
        let markerURL = TranscriptionService.sidecarMarkerURL(for: srt)

        #expect(markerURL.lastPathComponent == "roundtrip.srt.shortcast.json")
        // The marker is a sibling of the sidecar it attests, never of the video.
        #expect(markerURL.deletingLastPathComponent().path == srt.deletingLastPathComponent().path)

        let written = try marker(of: srt)
        let actualSize = try fileSize(of: srt)
        let actualBytes = try bytes(of: srt)
        let actualModified = try fileModifiedAt(of: srt)
        let recordedModified = try #require(written.sourceModifiedAt)

        #expect(written.schema == TranscriptSidecarMarker.schemaVersion)
        #expect(written.provenance == .whisper)
        #expect(written.provenance.isOurs == true)
        #expect(written.model == "openai_whisper-large-v3")
        #expect(written.language == "ru")
        #expect(written.segmentCount == 2)
        #expect(written.sourceSizeBytes == actualSize)
        #expect(written.sourceChecksumSHA256 == TranscriptionService.sha256Hex(of: actualBytes))
        // ISO-8601 has second precision, so compare loosely — the gate's tolerance does the same.
        #expect(abs(recordedModified.timeIntervalSince(actualModified)) < 2.0)
        #expect(written.writtenAt.timeIntervalSinceNow <= 1.0)

        // Stable, machine-readable shape, and it decodes back identically.
        let text = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(text.contains("\"schema\" : 1"))
        #expect(text.contains("\"provenance\" : \"whisper\""))
        let decodedAgain = TranscriptionService.sidecarMarker(from: try bytes(of: markerURL))
        #expect(decodedAgain == written)

        cleanup(dir)
    }

    @Test("a transcript we cannot vouch for is never stamped")
    func foreignTranscriptIsNotStamped() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "nostamp.mkv")
        let srt = sidecar(of: video)
        try write(Self.fansubSRT, to: srt)

        let imported = try #require(TranscriptionService.parseSubtitles(at: srt))
        #expect(imported.provenance == .foreign)
        #expect(TranscriptionService.writeSidecarMarker(
            forSidecar: srt, transcript: imported, model: nil) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: TranscriptionService.sidecarMarkerURL(for: srt).path))
        #expect(decide(video) == .foreign(url: srt, reason: .missingMarker))

        cleanup(dir)
    }

    @Test("our own SRT round-trips to the same cues, so the gate never re-transcribes it")
    func ourSidecarRoundTrips() throws {
        let dir = try makeDir()
        let video = try makeVideo(in: dir, named: "roundtrip_cues.mkv")
        TranscriptionService.saveSidecar(transcript: Self.whisperTranscript, for: video, model: nil)
        let srt = sidecar(of: video)

        let reparsed = try #require(TranscriptionService.parseSubtitles(at: srt))
        #expect(reparsed.segments.map(\.text) == ["Первая реплика.", "Вторая реплика."])
        #expect(reparsed.segments.map(\.start) == [10.0, 20.0])
        #expect(reparsed.segments.count == Self.whisperTranscript.segments.count)
        #expect(reparsed.provenance == .foreign)   // parsing alone never claims authorship
        #expect(reparsed.withProvenance(.cache).provenance == .cache)
        #expect(decide(video).isVerified == true)

        cleanup(dir)
    }

    // MARK: - Archive compatibility

    @Test("an old .shortcastproj whose transcript has no provenance key still decodes, as foreign")
    func legacyArchiveDecodesAsForeign() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Verbatim shape of a transcript written before provenance existed.
        let legacyTranscriptJSON = """
        {
          "segments": [
            { "start": 26.34, "end": 29.18, "text": "Sous-titres par LaVacheSquid", "words": [] },
            { "start": 30.0, "end": 31.5, "text": "Thank you.", "words": [] }
          ],
          "language": "en"
        }
        """
        let transcript = try decoder.decode(Transcript.self, from: Data(legacyTranscriptJSON.utf8))
        #expect(transcript.provenance == .foreign)
        #expect(transcript.provenance.isOurs == false)
        #expect(transcript.segments.count == 2)
        #expect(transcript.language == "en")

        // And through the real archive: `FilmProject.transcript` used to be fully
        // synthesized Codable, so a new required key would have thrown here and
        // made every existing project unloadable.
        let legacyProjectJSON = """
        {
          "id": "ED083F8F-DDA9-47B6-B701-ACF61C7D675D",
          "sourceMovieURL": "file:///Users/tester/Movies/blade_runner_2049.mkv",
          "movieFileName": "blade_runner_2049.mkv",
          "movieTitle": "Той, що біжить по лезу 2049",
          "durationSeconds": 10140.0,
          "createdAt": "2026-02-01T12:00:00Z",
          "updatedAt": "2026-02-01T12:00:00Z",
          "transcript": \(legacyTranscriptJSON)
        }
        """
        let project = try decoder.decode(FilmProject.self, from: Data(legacyProjectJSON.utf8))
        #expect(project.transcript?.provenance == .foreign)
        #expect(project.transcript?.segments.count == 2)
        #expect(project.movieTitle == "Той, що біжить по лезу 2049")
    }

    @Test("declared provenance survives an encode/decode round trip")
    func provenanceRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        for provenance in [TranscriptProvenance.whisper, .cache, .foreign] {
            let transcript = Transcript(
                segments: [TranscriptSegment(start: 1.0, end: 2.0, text: "Проверка.", words: [])],
                language: "ru",
                provenance: provenance
            )
            let data = try encoder.encode(transcript)
            let restored = try decoder.decode(Transcript.self, from: data)
            #expect(restored == transcript)
            #expect(restored.provenance == provenance)
            #expect(String(data: data, encoding: .utf8)?.contains("\"provenance\"") == true)
        }
    }

    @Test("an unrecognised or null provenance label is never treated as ours", arguments: [
        "{ \"segments\": [], \"language\": \"en\" }",
        "{ \"segments\": [], \"language\": \"en\", \"provenance\": null }",
        "{ \"segments\": [], \"language\": \"en\", \"provenance\": \"fansub\" }",
        "{ \"segments\": [], \"language\": \"en\", \"provenance\": 7 }",
        "{ \"segments\": [], \"language\": \"en\", \"provenance\": true }",
    ])
    func unknownProvenanceLabelsAreForeign(_ json: String) throws {
        let labelled = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(labelled.provenance == .foreign)
        #expect(labelled.provenance.isOurs == false)
    }

    @Test("a known provenance label is read back as declared")
    func knownProvenanceLabelsAreReadBack() throws {
        func decode(_ json: String) throws -> Transcript {
            try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"segments":[],"provenance":"cache"}"#).provenance == .cache)
        #expect(try decode(#"{"segments":[],"provenance":"whisper"}"#).provenance == .whisper)
        #expect(try decode(#"{"segments":[],"provenance":"foreign"}"#).provenance == .foreign)
        #expect(TranscriptProvenance.foreign.isOurs == false)
        #expect(TranscriptProvenance.whisper.isOurs == true)
        #expect(TranscriptProvenance.cache.isOurs == true)
    }
}

/// Explicit source-audio investigation. It never changes the film's transcript,
/// sidecars or project: Whisper receives a unique isolated temporary audio clip.
@Suite("Live Ukrainian ending ASR", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_UK_END"] == "1"))
@MainActor
struct UkrainianEndingASRProbeTests {
    @Test func transcribesOriginalAudioWithForcedUkrainian() async throws {
        let env = ProcessInfo.processInfo.environment
        let archive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shortcast/Projects/117F97CB-226B-490F-A16A-F4B42FFF9718.shortcastproj")
        let archiveBefore = try Data(contentsOf: archive)
        let object = try #require(try JSONSerialization.jsonObject(with: archiveBefore) as? [String: Any])
        let source = try #require(env["SHORTCAST_PROBE_UK_END_SOURCE"] ?? (object["sourceMovieURL"] as? String))
        let sourceURL = source.hasPrefix("file:") ? try #require(URL(string: source)) : URL(fileURLWithPath: source)
        let folder = URL(fileURLWithPath: "/private/tmp/shortcast-uk-end-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appendingPathComponent("source-5610-5627.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: env["SHORTCAST_FFMPEG"] ?? "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", "5610", "-t", "17", "-i", sourceURL.path,
                             "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", clip.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: clip.path))
        let cache = env["SHORTCAST_PROBE_WHISPER_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let transcript = try await TranscriptionService().transcript(for: clip, languageHint: "uk", modelCacheDir: cache)
        #expect(!transcript.segments.isEmpty)
        let encoded = try JSONEncoder().encode(transcript)
        let transcriptObject = try JSONSerialization.jsonObject(with: encoded)
        let report: [String: Any] = [
            "audioClipPath": clip.path, "sourceURL": sourceURL.absoluteString, "sourceStart": 5610,
            "sourceEnd": 5627, "forcedLanguage": "uk", "transcript": transcriptObject
        ]
        let output = URL(fileURLWithPath: "/private/tmp/shortcast-uk-end-transcript.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("Ukrainian ending ASR: \(output.path); source audio: \(clip.path)")
        #expect(try Data(contentsOf: archive) == archiveBefore)
    }
}

@Suite("Ukrainian transcription language")
struct UkrainianTranscriptionLanguageTests {
    private let russianTail = [
        TranscriptSegment(start: 5611, end: 5613, text: "Все хорошо, Трумэн."),
        TranscriptSegment(start: 5613.5, end: 5615, text: "Я понимаю."),
        TranscriptSegment(start: 5616, end: 5619, text: "Я знаю тебя от родины."),
        TranscriptSegment(start: 5620, end: 5623, text: "Я видел, как ты родился.")
    ]
    private let ukrainianTail = [
        TranscriptSegment(start: 5611, end: 5613, text: "Усе гаразд, Трумене."),
        TranscriptSegment(start: 5613.5, end: 5615, text: "Я розумію."),
        TranscriptSegment(start: 5616, end: 5619, text: "Я знаю тебе від народження."),
        TranscriptSegment(start: 5620, end: 5623, text: "Я бачив, як ти народився.")
    ]

    @Test("Local Russian drift is caught despite Ukrainian majority and wrong global metadata")
    func localDrift() throws {
        let majority = (0..<30).map { index in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 5),
                text: "Українською розповідаємо про свободу людини та її право на власне життя.")
        }
        let transcript = Transcript(segments: majority + russianTail, language: "en", provenance: .whisper)
        #expect(transcript.contentLanguage == "uk")
        let drift = TranscriptionService.ukrainianLanguageDrift(in: transcript.segments)
        #expect(drift.count == 1)
        #expect(drift.first?.start == 5611)
        #expect(throws: TranscriptionError.self) {
            try TranscriptionService.validateRequestedLanguage(segments: transcript.segments, requestedLanguage: "uk")
        }
        try TranscriptionService.validateRequestedLanguage(segments: russianTail, requestedLanguage: "ru")
        try TranscriptionService.validateRequestedLanguage(segments: russianTail, requestedLanguage: nil)
    }

    @Test("Neutral shared speech and isolated foreign names are not language drift")
    func sharedPhrasesAndNames() throws {
        for lines in [[TranscriptSegment(start: 10, end: 12, text: "Так. Добре. Мама. Тато.")],
                      [TranscriptSegment(start: 10, end: 14, text: "Це Ед Гарріс, а ось Трумен — ми бачимо його справжню реакцію.")], ukrainianTail] {
            try TranscriptionService.validateRequestedLanguage(segments: lines, requestedLanguage: "uk")
        }
    }

    @Test("A short Russian ending cannot hide behind the preceding Ukrainian line")
    func isolatedRussianEnding() throws {
        let lines = [
            TranscriptSegment(start: 6976, end: 6979, text: "І коли б я не прийшов, він чекає на мене там."),
            TranscriptSegment(start: 6982, end: 6985, text: "И я прокинулся.")
        ]
        #expect(throws: TranscriptionError.self) {
            try TranscriptionService.validateRenderedCaptions(lines,
                ranges: [.init(start: 6970, end: 6987)], requestedLanguage: "uk")
        }
        let corrected = [lines[0], TranscriptSegment(start: 6982, end: 6985, text: "І я прокинувся.")]
        try TranscriptionService.validateRenderedCaptions(corrected,
            ranges: [.init(start: 6970, end: 6987)], requestedLanguage: "uk")
        try TranscriptionService.validateRequestedLanguage(segments: [
            .init(start: 10, end: 12, text: "Я так думаю."),
            .init(start: 14, end: 17, text: "Мама була вдома.")
        ], requestedLanguage: "uk")
    }

    @Test("Rendered caption gate checks only selected corrected text, not unused raw ASR")
    func selectedAndCorrectedCaptions() throws {
        let raw = ukrainianTail.map { TranscriptSegment(start: $0.start - 100, end: $0.end - 100, text: $0.text) } + russianTail
        #expect(throws: TranscriptionError.self) {
            try TranscriptionService.validateRenderedCaptions(raw, ranges: [.init(start: 5596, end: 5627)], requestedLanguage: "uk")
        }
        try TranscriptionService.validateRenderedCaptions(raw, ranges: [.init(start: 5500, end: 5525)], requestedLanguage: "uk")
        let edits = zip(russianTail, ukrainianTail).map {
            LongformCaptionEdit(start: $0.start, end: $0.end, original: $0.text, replacement: $1.text)
        }
        let corrected = LongformEditorialSupport.captions(raw, edits: edits)
        try TranscriptionService.validateRenderedCaptions(corrected, ranges: [.init(start: 5596, end: 5627)], requestedLanguage: "uk")
        #expect(raw.suffix(4).map(\.text) == russianTail.map(\.text))
    }
}

extension UkrainianTranscriptionLanguageTests {
    @Test("Requested Ukrainian cache rejects unknown or mismatched metadata and Russian chunks stamped uk")
    func requestedLanguageCacheGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcast-uk-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("movie.mp4")
        let sidecar = video.deletingPathExtension().appendingPathExtension("srt")
        for language in [nil, "en", "uk"] as [String?] {
            let transcript = Transcript(segments: russianTail, language: language, provenance: .whisper)
            TranscriptionService.saveSidecar(transcript: transcript, for: video, model: "test")
            let decision = TranscriptionService.sidecarDecision(forSidecar: sidecar, requestedLanguage: "uk")
            if case .foreign(_, .languageMismatch) = decision {} else {
                Issue.record("Russian/unknown/mismatched cached transcript was accepted for Ukrainian decoding")
            }
        }
        let good = Transcript(segments: ukrainianTail, language: "uk", provenance: .whisper)
        TranscriptionService.saveSidecar(transcript: good, for: video, model: "test")
        #expect(TranscriptionService.sidecarDecision(forSidecar: sidecar, requestedLanguage: "uk").isVerified)
        let russian = Transcript(segments: russianTail, language: "ru", provenance: .whisper)
        TranscriptionService.saveSidecar(transcript: russian, for: video, model: "test")
        #expect(TranscriptionService.sidecarDecision(forSidecar: sidecar, requestedLanguage: "ru").isVerified)
    }
}


extension UkrainianTranscriptionLanguageTests {
    @Test("Selected caption drift is repaired from audio without changing source or scene timing")
    func focusedCaptionRepair() async throws {
        let source = [
            TranscriptSegment(start: 5969.58, end: 5972.04, text: "Для девчонок первый раз это очень важно."),
            TranscriptSegment(start: 5972.84, end: 5975.28, text: "Це визначає все її сексуальне життя."),
            TranscriptSegment(start: 7000, end: 7003, text: "Это было очень важно для меня.")
        ]
        let repaired = try await TranscriptionService.repairCaptionLanguage(segments: source,
            ranges: [.init(start: 5960, end: 5980)]) { range in
                #expect(range.start == source[0].start && range.end == source[0].end)
                return [.init(start: range.start, end: range.end,
                    text: "Для дівчат перший раз це дуже важливо.")]
            }
        #expect(repaired[0].text == "Для дівчат перший раз це дуже важливо.")
        #expect(repaired[0].start == source[0].start && repaired[0].end == source[0].end)
        #expect(repaired[1] == source[1] && repaired[2] == source[2])
        #expect(source[0].text.contains("девчонок"))
        let edits = LongformEditorialSupport.captionEdits(original: source, updated: repaired)
        #expect(edits.count == 1)
        try TranscriptionService.validateRenderedCaptions(
            LongformEditorialSupport.captions(source, edits: edits), ranges: [.init(start: 5960, end: 5980)], requestedLanguage: "uk")
    }

    @Test("Failed or empty audio retries cannot clear the language gate", arguments: ["", "Для девчонок первый раз это очень важно."])
    func failedCaptionRepair(text: String) async {
        let source = [TranscriptSegment(start: 5969.58, end: 5972.04, text: "Для девчонок первый раз это очень важно.")]
        await #expect(throws: TranscriptionError.self) {
            try await TranscriptionService.repairCaptionLanguage(segments: source, ranges: [.init(start: 5960, end: 5980)]) { range in
                [.init(start: range.start, end: range.end, text: text)]
            }
        }
    }

    @Test("Word timestamps exclude neighboring dialogue in an audio retry")
    func repairKeepsOnlyWordsInCaption() async throws {
        let source = [TranscriptSegment(start: 10, end: 13, text: "Для девчонок первый раз это очень важно.")]
        let repaired = try await TranscriptionService.repairCaptionLanguage(segments: source, ranges: [.init(start: 9, end: 15)]) { _ in
            [.init(start: 8, end: 15, text: "Попередня репліка. Для дівчат це важливо. Наступна репліка.", words: [
                .init(word: "Попередня репліка.", start: 8, end: 9),
                .init(word: " Для дівчат це важливо.", start: 10, end: 13),
                .init(word: " Наступна репліка.", start: 14, end: 15)
            ])]
        }
        #expect(repaired[0].text == "Для дівчат це важливо.")
    }

    @MainActor
    @Test("Optional saved Leon audio retry uses Whisper, never text translation")
    func savedLeonAudioRepair() async throws {
        guard let path = ProcessInfo.processInfo.environment["SHORTCAST_LEON_AUDIO_REPAIR"] else { return }
        let source = [TranscriptSegment(start: 5969.57958984375, end: 5972.0400390625,
            text: "Для девчонок первый раз это очень важно.")]
        let repaired = try await TranscriptionService().repairUkrainianCaptions(
            sourceURL: URL(fileURLWithPath: path), segments: source, ranges: [.init(start: 5960, end: 5980)])
        #expect(repaired.count == 1)
        #expect(repaired[0].text != source[0].text)
        print("Leon audio caption repair: " + repaired[0].text)
        try JSONEncoder().encode(repaired).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-leon-caption-asr.json"))
    }
}
