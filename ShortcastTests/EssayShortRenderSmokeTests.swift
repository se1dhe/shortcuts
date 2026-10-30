import AVFoundation
import Foundation
import Testing
@testable import Shortcast

/// Real export of an edited short from synthetic media: no films, models or uploads.
@MainActor
@Suite("Edited short export", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_RENDER_SMOKE"] == "1"))
struct EssayShortRenderSmokeTests {
    @Test("Edited cuts and captions export a playable vertical video plus its cover")
    func exportsEditedShort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let generated = try await ProcessRunner.shared.run(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            arguments: ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "20",
                        "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-pix_fmt", "yuv420p", source.path])
        #expect(generated.isSuccess)
        let concept = ThematicConcept(word: "ВИБІР", tagline: "Ціна вибору",
            philosophicalPremise: "Особистий вибір", suggestedTitle: "Ціна вибору")
        let arc = LongformNarrativeArc(movieTitle: "Тестовий фільм", concept: concept,
            acts: [LongformAct(type: .hook, title: "Вибір", dramaticBeat: "Початок",
                              segments: [.init(start: 0, end: 20)])], summary: "Тест")
        let result = LongformBuildResult(outputURL: directory.appendingPathComponent("essay.mp4"), arc: arc,
            metadata: LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: concept, arc: arc), duration: 20)
        let transcript = Transcript(segments: [TranscriptSegment(start: 3, end: 8, text: "Початкова репліка")], language: "uk")
        var short = EssayShort(id: "short1", angle: "Ціна свободи", hook: "Хто обирає?", title: "Вибір",
            why: "Діалог", payoffQuote: "Це твій вибір", question: "Яка ціна?", segments: [.init(start: 1, end: 16)])
        short.captionEdits = [.init(start: 3, end: 8, original: "Початкова репліка", replacement: "Виправлена репліка")]
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 20)
        let rendered = try await EssayShortRenderer().render(short, sourceURL: source, result: result,
            transcript: transcript, telegramURL: nil, directory: directory)
        let output = try #require(rendered.outputURL), cover = try #require(rendered.coverURL)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 18) < 0.15)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1080, height: 1920))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(rendered.captionEdits == short.captionEdits)
        #expect(!FileManager.default.fileExists(atPath: result.outputURL.path))
    }
}
