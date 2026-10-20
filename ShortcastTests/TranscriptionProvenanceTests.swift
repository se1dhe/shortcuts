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
