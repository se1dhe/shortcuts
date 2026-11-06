import Foundation
import Testing
@testable import Shortcast

@Suite("Targeted scene selection repair")
struct EssaySceneRepairTests {
    func fixture() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/american-psycho-invalid-scene-id.json"), encoding: .utf8)
    }
    func catalogue() -> EssaySceneCatalogue {
        EssaySceneCatalogue(transcript: Transcript(segments: (0..<60).map {
            .init(start: Double($0 * 60), end: Double($0 * 60 + 30), text: "Справжня репліка сцени номер \($0) з оригінального фільму.")
        }, language: "uk"))
    }
    @Test("Actual American Psycho suffix failure repairs only row seven")
    func actualFailure() throws {
        let catalogue = catalogue(), raw = try fixture()
        let repair = try #require(try catalogue.repairNeeded(from: raw))
        #expect(repair.indices == [6, 14])
        #expect(!repair.available.scenes.contains { $0.id == "S0004" })
        let replacement = #"{"replacements":[{"index":7,"id":"S0005","role":"psychology","weight":0.9,"featured":false,"explanation":"Інша реальна сцена для психологічного акту."},{"index":15,"candidate":2,"role":"catharsis","weight":0.9,"featured":false,"explanation":"Додаткова реальна сцена фінального акту."}]}"#
        let patched = try catalogue.applyingRepair(replacement, to: repair)
        let before = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let after = try #require(try JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any])
        for key in ["primaryConcept", "essayPlan", "reasoning"] {
            #expect(NSDictionary(dictionary: [key: before[key]!]).isEqual(to: [key: after[key]!]))
        }
        let oldRows = try #require(before["selection"] as? [[String: Any]])
        let newRows = try #require(after["selection"] as? [[String: Any]])
        for index in oldRows.indices where index != 6 { #expect(NSDictionary(dictionary: oldRows[index]).isEqual(to: newRows[index])) }
        #expect(try catalogue.decodeMoments(from: newRows).count == 15)
        for invalid in [replacement.replacingOccurrences(of: "S0005", with: "S004_alt"),
                        replacement.replacingOccurrences(of: "S0005", with: "S0004"),
                        replacement.replacingOccurrences(of: "S0005", with: "S9999"),
                        replacement.replacingOccurrences(of: "\"index\":7", with: "\"index\":2"),
                        replacement.replacingOccurrences(of: "psychology", with: "form")] {
            #expect(throws: (any Error).self) { try catalogue.applyingRepair(invalid, to: repair) }
        }
    }
}

@Suite("American Psycho live selection recovery", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PSYCHO_REPAIR"] == "1"))
@MainActor
struct AmericanPsychoRepairAcceptanceTests {
    @Test func recoversCurrentDraft() async throws {
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.id.uuidString == "B2A51326-E52C-4E26-8E01-BBED5696BCE5"
        })
        let transcript = try #require(project.transcript)
        let manager = ModelManager(); try await manager.requireDirector(profile: AppSettings().copywriterModel.directorProfile)
        let finder = manager.momentFinder
        let raw = try EssaySceneRepairTests().fixture()
        let concept = try #require(LongformThematicService.parseThematicAnalysis(from: raw)?.primaryConcept)
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let plan = MomentFinderService.essayDigestPlan(movieTitle: project.movieTitle,
            overview: project.tmdbMetadata?.overview ?? "", winner: concept, approvedCandidates: [concept],
            maxKVSize: AppSettings().copywriterModel.directorProfile.sampling.maxKVSize ?? 16384, catalogueMode: true)
        let sampled = MomentFinderService.downsampleChronologically(catalogue.digest, to: plan.digestChars).text
        let shown = catalogue.presented(in: sampled).denselyNumbered()
        let repaired = try #require(try await finder.repairCatalogueSelection(raw, catalogue: shown))
        try EssaySceneEvidence.validate(repaired, transcript: transcript)
        print("PSYCHO_REPAIR scene selection valid: \(repaired.selectedMoments.count) source-bound unique scenes; original theme=\(concept.word)")
        let reviewed = try await finder.reviewThemeAndHook(repaired, candidates: [concept], transcript: transcript)
        let bound = ThematicAnalysisCache.binding(reviewed, to: transcript)
        #expect(ThematicAnalysisCache.isReusable(bound, transcript: transcript))
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = repo.appendingPathComponent("tmp/psycho-recovery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bound).write(to: folder.appendingPathComponent("analysis.json"), options: .atomic)
        var latest = try #require(try await FilmProjectService.shared.listRecentProjects().first { $0.id == project.id })
        guard latest.updatedAt == project.updatedAt, latest.sourceMovieURL == project.sourceMovieURL else {
            print("PSYCHO_REPAIR retained newer project; recovery artifact saved separately"); return
        }
        latest.thematicAnalysis = bound; latest.discoveredConcepts = bound.allConcepts; latest.selectedConcept = bound.primaryConcept
        try await FilmProjectService.shared.saveProject(latest)
        print("PSYCHO_REPAIR accepted and saved: \(bound.primaryConcept.word); hook=\(bound.essayPlan?.selectedHook?.text ?? "")")
    }
}
