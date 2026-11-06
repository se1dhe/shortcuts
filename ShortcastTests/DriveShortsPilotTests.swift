import Foundation
import Testing
@testable import Shortcast

@Suite("Drive shorts pilot", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_DRIVE_SHORTS"] == "1"))
@MainActor
struct DriveShortsPilotTests {
    @Test func preparesShorts() async throws {
        let original = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.id.uuidString == "38875A94-8419-48BE-817A-002B27D9D8EB"
        })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var result = try JSONDecoder().decode(LongformBuildResult.self,
            from: Data(contentsOf: root.appendingPathComponent("tmp/drive-pilot-result.json")))
        let manager = ModelManager(), settings = AppSettings()
        if var music = result.arc.musicSettings,
           music.backgroundMusicURL?.lastPathComponent == "Kevin MacLeod - Long Note One.mp3" {
            music.musicSource = "https://incompetech.com/music/royalty-free/index.html?isrc=USUAN1100418"
            music.musicUsageTerms = "Long Note One — Kevin MacLeod (incompetech.com). CC BY 4.0: https://creativecommons.org/licenses/by/4.0/"
            var arc = result.arc; arc.musicSettings = music
            result = LongformPackagingService.updatingText(.init(outputURL: result.outputURL, arc: arc,
                metadata: result.metadata, duration: result.duration, thumbnailURL: result.thumbnailURL,
                validationResult: result.validationResult, audioSettings: music,
                thumbnailSubject: result.thumbnailSubject, packagingWarning: result.packagingWarning))
        }
        if result.thumbnailURL == nil || ProcessInfo.processInfo.environment["SHORTCAST_REFRESH_DRIVE_COVER"] == "1" {
            result = try await LongformPackagingService(thumbnailGenerator:
                LongformPackagingService.makeThumbnailGenerator(modelManager: manager, movie: original.tmdbMetadata))
                .refresh(result, sourceURL: original.sourceMovieURL)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: root.appendingPathComponent("tmp/drive-pilot-result.json"), options: .atomic)
        let pilotID = try #require(UUID(uuidString: "CC18B6AF-0DA2-4599-B95F-E4036F67D34C"))
        var project = try await FilmProjectService.shared.listRecentProjects().first { $0.id == pilotID }
            ?? FilmProject(id: pilotID, sourceMovieURL: original.sourceMovieURL,
                movieFileName: original.movieFileName, movieTitle: "Драйв — редакторський пілот", movieYear: original.movieYear,
                durationSeconds: original.durationSeconds, selectedAudioTrackId: original.selectedAudioTrackId,
                tmdbMetadata: original.tmdbMetadata, transcript: original.transcript,
                scenes: original.scenes, discoveredConcepts: [result.arc.concept], selectedConcept: result.arc.concept)
        if let previous = project.longformResult, let release = project.essayRelease {
            project.essayRelease = release.rebindingUnpublishedPlans(from: previous.arc, to: result.arc) ?? release
        }
        project.longformResult = result
        let existingSceneExports = project.essayRelease?.shorts.filter { !$0.isMontage && $0.hasCurrentRenderStyle }
            .compactMap { short in short.outputURL.map { (short.id, $0) } } ?? []
        let staleMontage = project.essayRelease?.shorts.first { $0.isMontage && !$0.hasCurrentRenderStyle }?.outputURL
        try await FilmProjectService.shared.saveProject(project)
        #expect(project.longformResult?.arc.audienceEditorial != nil)
        let workspace = WorkspaceModel()
        #expect(workspace.reviewSavedEssay(project))
        try await workspace.prepareEssayRelease(modelManager: manager, settings: settings) { print("DRIVE_SHORTS \($0)") }
        let release = try #require(workspace.currentEssayRelease)
        #expect(release.hasReadyShorts && release.hasCurrentShortStyle)
        #expect(release.shorts.count == 3 && release.shorts[2].isMontage)
        #expect(release.shorts[2].montagePlan?.cutTimes?.count == release.shorts[2].segments.count - 1)
        for (id, url) in existingSceneExports {
            #expect(release.shorts.first(where: { $0.id == id })?.outputURL == url)
        }
        if let staleMontage { #expect(release.shorts[2].outputURL != staleMontage) }
        if let edit = release.shorts[2].editPlan {
            #expect(edit.payoffTime > 0 && edit.payoffTime < release.shorts[2].duration)
        }
        #expect(release.receipts.isEmpty)
        try EssayShortCopyEditor.requireDistinctCopy(release.shorts[1], previous: [release.shorts[0]])
        for short in release.shorts { print("DRIVE_SHORTS ready=\(short.outputURL?.path ?? "") hook=\(short.hook) title=\(short.title)") }
    }
}
