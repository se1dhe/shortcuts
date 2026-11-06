import XCTest
import Foundation
import Testing
@testable import Shortcast

final class AudioTrackSelectionTests: XCTestCase {

    // MARK: - pickRecommendedAudioTrack

    func testUkrainianTrackPriorityOverRussianDub() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: "Дубляж", language: "ukr", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 2, audioIndex: 2, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should prioritize Ukrainian track by language code")
        XCTAssertEqual(chosen?.language, "ukr")
    }

    func testUkrainianTitleMatchWhenNoLanguageCode() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: "Українська озвучка", language: nil, codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should match Ukrainian by title when language code is missing")
    }

    func testBladeRunner2049UkrainianTrackSelection() {
        // Real audio tracks from Blade Runner 2049 (2017) WEB-DL 4K MKV
        let tracks = [
            AudioTrackInfo(
                id: 1,
                audioIndex: 0,
                title: "Ukrainian | DTS | 5.1 | 768 kbps | DUB | LeDoyen",
                language: "ukr",
                codec: "dts",
                channels: 6,
                isDefault: false,
                isForced: false
            ),
            AudioTrackInfo(
                id: 2,
                audioIndex: 1,
                title: "English | E-AC-3 JOC | 5.1 | 640 kbps",
                language: "eng",
                codec: "eac3",
                channels: 6,
                isDefault: true,
                isForced: false
            )
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 1, "Should select Ukrainian track over English default")
        XCTAssertEqual(chosen?.language, "ukr")
        XCTAssertTrue(chosen?.isUkrainianVoiceover == true, "Track should be recognized as Ukrainian voiceover")
    }

    func testFallbackToRussianWhenNoUkrainian() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should fall back to Russian dub when no Ukrainian track")
        XCTAssertEqual(chosen?.language, "rus")
    }

    func testFallbackToContainerDefaultWhenNoDub() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: true, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 1, "Should fall back to container default track")
        XCTAssertTrue(chosen?.isDefault ?? false)
    }

    func testFallbackToFirstTrackWhenNothingMatches() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: nil, language: "fra", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should fall back to first track when nothing matches")
    }

    func testEmptyTrackListReturnsNil() {
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: [])
        XCTAssertNil(chosen, "Empty track list should return nil")
    }

    // MARK: - languageCode(from:)

    @MainActor
    func testLanguageCodeMappingUkrainian() async {
        XCTAssertEqual(TranscriptionService.languageCode(from: "uk"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "ukr"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "українська"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "український"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "Ukrainian"), "uk")
    }

    @MainActor
    func testLanguageCodeMappingRussian() async {
        XCTAssertEqual(TranscriptionService.languageCode(from: "ru"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "rus"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "російська"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "російський"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "Russian"), "ru")
    }

    @MainActor
    func testLanguageCodeMappingOtherLanguages() async {
        XCTAssertEqual(TranscriptionService.languageCode(from: "es"), "es")
        XCTAssertEqual(TranscriptionService.languageCode(from: "Spanish"), "es")
        XCTAssertEqual(TranscriptionService.languageCode(from: "en"), "en")
        XCTAssertEqual(TranscriptionService.languageCode(from: "English"), "en")
    }

    @MainActor
    func testLanguageCodeEmptyReturnsNil() async {
        XCTAssertNil(TranscriptionService.languageCode(from: ""))
        XCTAssertNil(TranscriptionService.languageCode(from: "   "))
    }

    @MainActor
    func testLanguageCodeUnknownReturnsNil() async {
        XCTAssertNil(TranscriptionService.languageCode(from: "klingon"))
        XCTAssertEqual(TranscriptionService.languageCode(from: "xx"), "xx", "2-letter codes are passed through as-is")
    }

    // MARK: - AudioTrackInfo.isUkrainianVoiceover

    func testIsUkrainianVoiceoverByLanguageCode() {
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "ukr", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "uk", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "українська", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
    }

    func testIsUkrainianVoiceoverByTitle() {
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: "Українська озвучка", language: nil, codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: "Ukrainian dub", language: nil, codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
    }

    func testIsUkrainianVoiceoverFalseForRussian() {
        XCTAssertFalse(AudioTrackInfo(id: 0, audioIndex: 0, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertFalse(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "ru", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
    }

}

private enum CleanupSaveFailure: Error { case refused }

@Suite("MKV source cleanup")
struct MKVSourceCleanupTests {
    @Test("A shorter original audio track does not fail at the video tail, but truncated replacement audio does")
    func audioTimelineIsIndependentOfVideoTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let source = root.appendingPathComponent("source.mkv")
        let generated = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=12",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=8",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source.path])
        #expect(generated.isSuccess)
        let output = try await MediaExtractor.normalizeInputIfNeeded(from: source, workingDirectory: root, selectedAudioStreamIndex: 1)
        let project = FilmProject(sourceMovieURL: source, movieFileName: "source", movieTitle: "Film", durationSeconds: 12)
        let broken = root.appendingPathComponent("truncated-audio.mp4")
        let cut = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: [
            "-v", "error", "-i", output.path, "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", broken.path])
        #expect(cut.isSuccess)
        await #expect(throws: (any Error).self) {
            try await MediaExtractor.finishMKVImport(project: project, sourceURL: source, originalURL: nil,
                outputURL: broken, workingDirectory: root, selectedAudioStreamIndex: 1,
                save: { _ in Issue.record("Truncated audio must never authorize source deletion") })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        let adopted = try await MediaExtractor.finishMKVImport(project: project, sourceURL: source, originalURL: nil,
            outputURL: output, workingDirectory: root, selectedAudioStreamIndex: 1, save: { _ in })
        #expect(adopted.sourceMovieURL == output)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Only a verified MP4 with a persisted project allows removal of both MKV copies")
    func verifiesCommitsThenDeletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("working.mkv")
        let original = root.appendingPathComponent("original.mkv")
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let generated = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-t", "12",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", "-c:a", "aac", source.path])
        #expect(generated.isSuccess)
        try FileManager.default.copyItem(at: source, to: original)
        let output = try await MediaExtractor.normalizeInputIfNeeded(from: source, workingDirectory: root, selectedAudioStreamIndex: 2)
        #expect(output.pathExtension == "mp4")
        var project = FilmProject(sourceMovieURL: source, movieFileName: "working", movieTitle: "Фільм",
            durationSeconds: 12, selectedAudioTrackId: 2)
        project.transcript = Transcript(segments: [.init(start: 1, end: 2, text: "Збережена репліка")], language: "uk")
        let service = FilmProjectService(storageDirectory: root.appendingPathComponent("projects"))
        try await service.saveProject(project)

        // A usable but truncated MP4 must never authorize source deletion.
        let partial = root.appendingPathComponent("partial.mp4")
        let shortened = try await ProcessRunner.shared.run(executableURL: ffmpeg,
            arguments: ["-v", "error", "-i", output.path, "-t", "3", "-c", "copy", partial.path])
        #expect(shortened.isSuccess)
        await #expect(throws: (any Error).self) {
            try await MediaExtractor.finishMKVImport(project: project, sourceURL: source, originalURL: original,
                outputURL: partial, workingDirectory: root, selectedAudioStreamIndex: 2,
                save: { _ in Issue.record("A truncated MP4 must not reach project saving") })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: original.path))

        // A silent replacement is also insufficient even when its duration is correct.
        let silent = root.appendingPathComponent("silent.mp4")
        let muted = try await ProcessRunner.shared.run(executableURL: ffmpeg,
            arguments: ["-v", "error", "-i", output.path, "-an", "-c:v", "copy", silent.path])
        #expect(muted.isSuccess)
        await #expect(throws: (any Error).self) {
            try await MediaExtractor.finishMKVImport(project: project, sourceURL: source, originalURL: original,
                outputURL: silent, workingDirectory: root, selectedAudioStreamIndex: 2,
                save: { _ in Issue.record("A silent MP4 must not reach project saving") })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: original.path))

        // Saving fails (e.g. disk full): keep every MKV and the old project binding.
        await #expect(throws: CleanupSaveFailure.self) {
            try await MediaExtractor.finishMKVImport(project: project, sourceURL: source, originalURL: original,
                outputURL: output, workingDirectory: root, selectedAudioStreamIndex: 2,
                save: { _ in throw CleanupSaveFailure.refused })
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try await service.loadProject(for: source)?.sourceMovieURL == source)

        let adopted = try await MediaExtractor.finishMKVImport(project: project, sourceURL: source, originalURL: original,
            outputURL: output, workingDirectory: root, selectedAudioStreamIndex: 2,
            save: { updated in
                #expect(FileManager.default.fileExists(atPath: source.path))
                #expect(FileManager.default.fileExists(atPath: original.path))
                try await service.saveProject(updated)
            })
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(adopted.id == project.id)
        #expect(adopted.selectedAudioTrackId == 1)
        let reopened = try #require(try await service.loadProject(for: output))
        #expect(reopened.id == project.id)
        #expect(reopened.sourceMovieURL == output)
        #expect(reopened.transcript?.segments.first?.text == "Збережена репліка")
    }
}
