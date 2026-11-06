import Foundation
import Testing
@testable import Shortcast

/// Explicit real-film acceptance run, using production services and no publication.
@Suite("Drive editorial pilot", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_DRIVE_PILOT"] == "1"))
@MainActor
struct DriveEditorialPilotTests {
    @Test func preparesDrive() async throws {
        let service = FilmProjectService.shared
        var project = try #require(try await service.listRecentProjects().first { $0.id.uuidString == "38875A94-8419-48BE-817A-002B27D9D8EB" })
        let transcript = try #require(project.transcript)
        #expect(FileManager.default.fileExists(atPath: project.sourceMovieURL.path))
        let manager = ModelManager()
        let settings = AppSettings()
        try await manager.requireDirector(profile: .gemma12B)
        let analysis: ThematicAnalysisResult
        if let saved = project.thematicAnalysis, ThematicAnalysisCache.isReusable(saved, transcript: transcript) {
            analysis = saved
        } else {
            analysis = try await LongformThematicService().discoverThematicAnalysis(from: transcript, movieTitle: "Драйв",
                movieOverview: project.tmdbMetadata?.overview, modelManager: manager, directorProfile: .gemma12B)
            project.thematicAnalysis = analysis; project.discoveredConcepts = analysis.allConcepts
            project.selectedConcept = analysis.primaryConcept
            try await service.saveProject(project)
        }
        print("DRIVE_PILOT theme=\(analysis.primaryConcept.word)")
        let gateway = DirectorChatGateway(readiness: { await manager.momentFinder.isReady }, identifier: { "gemma12B" },
            completion: { instructions, prompt, tokens in
                await manager.momentFinder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: tokens)
            })
        var arc: LongformNarrativeArc
        if let draft = project.pendingLongformArc { arc = draft }
        else {
            let built = try await LongformNarrativeDirector().buildArc(from: transcript, concept: analysis.primaryConcept,
                selectedMoments: analysis.selectedMoments, movieTitle: "Драйв", essayPlan: analysis.essayPlan,
                sourceMovieURL: project.sourceMovieURL)
            let reviewed = await LongformEditorialReview(model: gateway).review(arc: built, transcript: transcript, coldOpenEnabled: true)
            arc = reviewed
            project.pendingLongformArc = arc
            try await service.saveProject(project)
        }
        if arc.acts.contains(where: { !$0.effectiveTitleSource.isTrustworthy }) {
            arc = await LongformActTitleService(model: gateway).applyTitles(to: arc, transcript: transcript, movieTitle: "Драйв", progress: nil).arc
            project.pendingLongformArc = arc
            try await service.saveProject(project)
        }
        if let file = ProcessInfo.processInfo.environment["SHORTCAST_DRIVE_EDITORIAL_FILE"] {
            struct Review: Decodable { var editorial: AudienceEditorialPlan; var conclusion, cta: String }
            let review = try JSONDecoder().decode(Review.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            let plan = try AudienceEditorialService.parse(String(decoding: JSONEncoder().encode(review.editorial), as: UTF8.self), arc: arc, transcript: transcript)
            #expect(plan.approvalSource == "assistant-editorial-review" && plan.modelID == nil)
            arc.audienceEditorial = plan; arc.audienceEditorialRequired = true
            arc.publicationTitle = plan.title; arc.hookText = plan.hook; arc.coverText = plan.coverText; arc.viewerPromise = plan.hook
            arc.conclusionText = review.conclusion; arc.ctaText = review.cta
            if project.selectedConcept?.word == arc.concept.word {
                project.pendingLongformArc = arc
                try await service.saveProject(project)
            }
            print("DRIVE_PILOT source=assistant-editorial-review; source quotes validated; not an unattended model approval")
        } else if arc.audienceEditorial == nil {
            arc = try await AudienceEditorialWorkflow.prepare(arc, transcript: transcript, manager: manager, preferred: .qwen35_9b)
            project.pendingLongformArc = arc
            try await service.saveProject(project)
        }
        #expect(LongformTimeline(arc: arc).placements.first?.start == 0)
        print("DRIVE_PILOT title=\(arc.publicationTitle ?? "") hook=\(arc.hookText ?? "")")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let audio = LongformAudioSettings(backgroundMusicURL: root.appendingPathComponent("Music/Kevin MacLeod - Long Note One.mp3"),
            musicVolume: 0.03, duckingEnabled: false, originalMusicDucking: 0.8)
        arc.musicSettings = audio
        let result = try await LongformPipelineCoordinator(
            thumbnailGenerator: LongformPackagingService.makeThumbnailGenerator(modelManager: manager, movie: project.tmdbMetadata),
            discussionURL: LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId),
            support: settings.essaySupport, modelManager: manager
        ).buildLongformVideo(sourceURL: project.sourceMovieURL, movieTitle: "Драйв", transcript: transcript,
            // Re-render the saved approved draft. The user has since analysed
            // another theme; its scene selection must never validate this arc.
            concept: arc.concept, audioSettings: audio, existingArc: arc,
            workingDirectory: root.appendingPathComponent("tmp/drive-pilot"),
            channelLogoEnabled: settings.channelLogoWatermarkEnabled) { fraction, step in
                print("DRIVE_PILOT \(Int(fraction * 100))% \(step)")
            }
        #expect(result.validationResult?.isValid == true)
        // A live user may have selected another theme while this acceptance
        // render was running. Keep the pilot artifact without replacing it.
        let latest = try #require(try await service.listRecentProjects().first { $0.id == project.id })
        if latest.selectedConcept?.word == arc.concept.word {
            project = latest
            project.longformResult = result; project.pendingLongformArc = nil
            try await service.saveProject(project)
        } else { print("DRIVE_PILOT retained current project selection; pilot saved separately") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: root.appendingPathComponent("tmp/drive-pilot-result.json"), options: .atomic)
        print("DRIVE_PILOT result=\(result.outputURL.path)")
    }
}

@Suite("Drive local editorial acceptance", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_DRIVE_LOCAL_EDITORIAL"] == "1"))
@MainActor
struct DriveLocalEditorialAcceptanceTests {
    @Test func writesFromSelectedDialogue() async throws {
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.id.uuidString == "38875A94-8419-48BE-817A-002B27D9D8EB"
        })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pilot = try JSONDecoder().decode(LongformBuildResult.self,
            from: Data(contentsOf: root.appendingPathComponent("tmp/drive-pilot-result.json")))
        var arc = pilot.arc
        arc.audienceEditorial = nil
        let edited = try await AudienceEditorialWorkflow.prepare(arc,
            transcript: try #require(project.transcript), manager: ModelManager(),
            preferred: AppSettings().copywriterModel.directorProfile)
        let plan = try #require(edited.audienceEditorial)
        #expect(plan.approvalSource == "local-model")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: root.appendingPathComponent("tmp/drive-pilot/local-editorial.json"), options: .atomic)
        print("DRIVE_LOCAL_EDITORIAL accepted title=\(plan.title) hook=\(plan.hook)")
    }
}
