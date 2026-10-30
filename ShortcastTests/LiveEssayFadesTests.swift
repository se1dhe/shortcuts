import AVFoundation
import Foundation
import Testing
@testable import Shortcast

private struct RetainedEssayCover: LongformThumbnailGeneratingProtocol {
    let cover: ReviewedThumbnail
    func generateThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment], concept: ThematicConcept,
                           movieTitle: String, outputURL: URL) async throws -> URL { cover.url }
    func generateReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment], concept: ThematicConcept,
                                   movieTitle: String, outputURL: URL) async throws -> ReviewedThumbnail { cover }
}

/// Explicit local QA only: renders an existing approved arc without a new model
/// selection. Adoption is a separate explicit flag and checks for concurrent edits.
@Suite("Live essay fade restoration", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_FADES"] == "1"))
@MainActor
struct LiveEssayFadesTests {
    @Test func preservesCurrentCorrectionsAndRestoresSceneFades() async throws {
        let env = ProcessInfo.processInfo.environment
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club") && $0.longformResult != nil
        })
        let original = try #require(project.longformResult)
        let transcript = try #require(project.transcript)
        let coverURL = try #require(original.thumbnailURL)
        let source = URL(fileURLWithPath: try #require(env["SHORTCAST_FADES_SOURCE"]))
        let projectURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shortcast/Projects/\(project.id.uuidString).shortcastproj")
        let archiveBefore = try Data(contentsOf: projectURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: original.outputURL.path)
        let edits = try #require(original.arc.captionEdits)
        #expect(!edits.isEmpty)
        let coordinator = LongformPipelineCoordinator(thumbnailGenerator: RetainedEssayCover(
            cover: ReviewedThumbnail(url: coverURL, subject: original.thumbnailSubject)))
        let updated = try await coordinator.buildLongformVideo(sourceURL: source,
            movieTitle: original.arc.movieTitle, transcript: transcript, concept: original.arc.concept,
            selectedMoments: [], audioSettings: original.audioSettings ?? LongformAudioSettings(),
            existingArc: original.arc,
            workingDirectory: original.outputURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            channelLogoEnabled: true, progressHandler: { fraction, step in
                print("FADES_PROBE \(Int(fraction * 100))% \(step)")
            })
        #expect(updated.arc == original.arc)
        #expect(updated.arc.captionEdits == edits)
        #expect(updated.thumbnailURL == original.thumbnailURL)
        #expect(updated.audioSettings == original.audioSettings)
        #expect(abs(updated.duration - original.duration) < 0.04)
        #expect(updated.validationResult?.hasIssues == false)
        let originalAfter = try FileManager.default.attributesOfItem(atPath: original.outputURL.path)
        #expect(originalAttributes[.size] as? Int == originalAfter[.size] as? Int)
        #expect(originalAttributes[.modificationDate] as? Date == originalAfter[.modificationDate] as? Date)
        let timeline = LongformTimeline(arc: updated.arc, coldOpenEnabled: updated.audioSettings?.coldOpenEnabled ?? true)
        let cutTimes = timeline.placements.dropFirst().filter { !$0.isInterAct }.map(\.start)
        #expect(!cutTimes.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-restored-fades-result.json"), options: .atomic)
        try encoder.encode(cutTimes).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-restored-fades-cuts.json"), options: .atomic)
        if env["SHORTCAST_ADOPT_FADES"] == "1" {
            // No intervening subtitle, theme or packaging edit may be overwritten.
            #expect(try Data(contentsOf: projectURL) == archiveBefore)
            guard try Data(contentsOf: projectURL) == archiveBefore else { return }
            try archiveBefore.write(to: URL(fileURLWithPath: "/private/tmp/shortcast-before-restored-fades.shortcastproj"), options: .atomic)
            let filmKey = project.tmdbMetadata.map { "movie:\($0.id)" }
                ?? "title:" + SubtitleCorrectionMemory.key(original.arc.movieTitle).lowercased()
            try SubtitleCorrectionStore.shared.update {
                $0.importEdits(edits, filmKey: filmKey, language: transcript.language?.lowercased() ?? "uk")
            }
            var adopted = project
            adopted.longformResult = updated
            try await FilmProjectService.shared.saveProject(adopted)
        }
        print("FADES_PROBE output=\(updated.outputURL.path) edits=\(edits.count) cuts=\(cutTimes.count)")
    }
}
