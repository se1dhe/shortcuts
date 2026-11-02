import Foundation
import Testing
@testable import Shortcast

@Suite("Saved essay review")
struct SavedEssayReviewTests {
    @Test @MainActor func deletedMediaCanBeReviewedWithoutMutatingTheArchive() throws {
        let source = URL(fileURLWithPath: "/private/tmp/missing-source-\(UUID().uuidString).mp4")
        let concept = ThematicConcept(word: "ВИБІР", tagline: "Ціна свободи", philosophicalPremise: "Вибір має наслідки", suggestedTitle: "Ціна вибору")
        let arc = LongformNarrativeArc(movieTitle: "Фільм", concept: concept,
            acts: [LongformAct(type: .hook, title: "Початок", dramaticBeat: "Вибір", segments: [.init(start: 10, end: 40)])], summary: "Тема")
        let result = LongformBuildResult(outputURL: source.deletingLastPathComponent().appendingPathComponent("missing-export.mp4"), arc: arc,
            metadata: LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: concept, arc: arc), duration: 30)
        let transcript = Transcript(segments: [.init(start: 10, end: 20, text: "Це мій вибір.")], language: "uk")
        let project = FilmProject(sourceMovieURL: source, movieFileName: source.lastPathComponent, movieTitle: "Фільм",
            durationSeconds: 300, selectedAudioTrackId: 2, transcript: transcript, longformResult: result)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(project)
        let workspace = WorkspaceModel()
        #expect(workspace.reviewSavedEssay(project))
        #expect(workspace.phase == .longformResults)
        #expect(workspace.job?.url == source)
        #expect(workspace.job?.durationSeconds == 300)
        #expect(workspace.storedTranscript?.language == "uk")
        #expect(workspace.currentProject?.selectedAudioTrackId == 2)
        #expect(try encoder.encode(workspace.currentProject) == before)
        #expect(!workspace.isBusy)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let emptyProject = FilmProject(sourceMovieURL: source, movieFileName: "missing.mp4", movieTitle: "Other")
        #expect(!workspace.reviewSavedEssay(emptyProject))
        #expect(workspace.currentProject?.id == project.id)
    }
}
