import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Shortcast

@Suite("Essay publication packaging")
struct LongformPackagingTests {
    private func result() -> LongformBuildResult {
        let concept = ThematicConcept(word: "СПОЖИВАЧ", tagline: "Ціна відмови від речей",
            philosophicalPremise: "Залежність від речей змінює ідентичність", suggestedTitle: "Ціна виходу з системи споживання", source: .llm)
        let acts = LongformActType.canonicalAnalyticOrder.enumerated().map { index, role in
            LongformAct(type: role, title: "Рішення героя", dramaticBeat: "Вибір має наслідки",
                segments: [TimeSegment(start: Double(index * 80), end: Double(index * 80 + 60))])
        }
        var arc = LongformNarrativeArc(id: "packaging", movieTitle: "Бійцівський клуб", concept: concept,
            acts: acts, summary: "Відмова від речей стає саморуйнуванням", mood: "dramatic")
        arc.hookText = "Чи вільний ти, якщо залежиш від речей?"
        arc.thesis = "Герой відмовляється від матеріальних цінностей і втрачає соціальні зв'язки."
        arc.ctaText = "Яку ціну свободи ти готовий заплатити?"
        return LongformBuildResult(outputURL: URL(fileURLWithPath: "/private/tmp/packaging-video.mp4"), arc: arc,
            metadata: LongformYouTubeMetadata(title: "old", description: "old", tags: [], pinnedComment: "old"), duration: 308)
    }

    @Test("Every publication text identifies the film and this essay; hashtags are paste-ready")
    func filmAndMeaning() {
        let r = result()
        let m = LongformMetadataGenerator.generate(movieTitle: r.arc.movieTitle, concept: r.arc.concept, arc: r.arc)
        #expect(m.title == "Ціна виходу з системи споживання | Бійцівський клуб")
        for text in [m.title, m.description, m.pinnedComment] { #expect(text.contains("Бійцівський клуб")) }
        #expect(m.description.contains(r.arc.thesis!))
        #expect(m.description.contains(r.arc.hookText!))
        #expect(!m.description.contains("Іноді ілюзія"))
        #expect(!m.tags.contains("самообман"))
        #expect(m.hashtags.contains("#Бійцівськийклуб"))
        #expect(m.hashtags.allSatisfy { $0.hasPrefix("#") && !$0.contains(" ") && !$0.contains(",") })
        #expect(m.description.hasSuffix(m.hashtagText))
        #expect(m.tags.allSatisfy { !$0.hasPrefix("#") })
    }

    @Test("The title budget reserves the actual film name and never duplicates it")
    func titleBudget() {
        let film = "Бійцівський клуб"
        let long = LongformMetadataGenerator.publicationTitle(essay: String(repeating: "Українська думка ", count: 15), film: film)
        #expect(long.count <= 100)
        #expect(long.hasSuffix(film))
        let already = "Бійцівський клуб: ціна свободи"
        #expect(LongformMetadataGenerator.publicationTitle(essay: already, film: film) == already)
        #expect(LongformMetadataGenerator.hashtag("#Зв’язок людей — 2026!") == "#Звязоклюдей2026")
        #expect(LongformMetadataGenerator.hashtag("123") == nil)
    }

    @Test("UTF-8 description limits preserve film identity, chapters and hashtags")
    func descriptionBudget() {
        var arc = result().arc
        arc.thesis = String(repeating: "Матеріальні цінності змінюють героя. ", count: 500)
        let m = LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc)
        #expect(m.description.utf8.count <= 5_000)
        #expect(m.description.contains("Бійцівський клуб"))
        #expect(m.description.contains("Таймкоди:"))
        #expect(m.description.hasSuffix(m.hashtagText))
    }

    @Test("Legacy metadata decodes with usable hashtag tokens")
    func compatibility() throws {
        let raw = #"{"title":"old","description":"old","tags":["Бійцівський клуб","сенс фільму"],"pinnedComment":"old"}"#
        let decoded = try JSONDecoder().decode(LongformYouTubeMetadata.self, from: Data(raw.utf8))
        #expect(decoded.hashtagText == "#Бійцівськийклуб #сенсфільму")
    }

    @Test("A missing visual confirmation never returns a random face as the cover")
    func noUnverifiedFallback() async throws {
        let generator = LongformThumbnailGenerator()
        await #expect(throws: ThumbnailSelectionError.self) {
            try await generator.generateThumbnail(sourceAsset: AVURLAsset(url: URL(fileURLWithPath: "/private/tmp/absent.mp4")),
                segments: [], concept: result().arc.concept, movieTitle: "Фільм", outputURL: URL(fileURLWithPath: "/private/tmp/no-cover.jpg"))
        }
    }

    @Test("Model frame and actor IDs are bounded; uncertainty is refused")
    func identityGate() {
        let raw = #"{"choices":[{"frame":1,"leadIndex":1,"confidence":0.94},{"frame":2,"leadIndex":2,"confidence":0.5},{"frame":9,"leadIndex":1,"confidence":0.99},{"frame":3,"leadIndex":9,"confidence":1},{"frame":1,"leadIndex":1,"confidence":1}]}"#
        #expect(ThumbnailSubjectVerifier.choices(from: raw, frameCount: 3, leadCount: 2).count == 1)
        #expect(ThumbnailSubjectVerifier.choices(from: raw, frameCount: 0, leadCount: 0).isEmpty)
    }

    @Test("A verified lead outranks a larger unverified face", arguments: [false, true])
    func modelControlsSubject(contradict: Bool) async throws {
        let context = try #require(CGContext(data: nil, width: 80, height: 50, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let candidates = [ThumbnailCandidateFrame(time: 10, image: image, faceBox: CGRect(x: 0.5, y: 0.2, width: 0.3, height: 0.5),
                score: 9999, averageLuminance: 0.3),
            ThumbnailCandidateFrame(time: 30, image: image, faceBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.4),
                score: 100, averageLuminance: 0.3)]
        let gateway = ThumbnailVisionGateway(modelID: "test-vision") { _, prompt in
            if prompt.hasPrefix("These are") {
                return #"{"choices":[{"frame":2,"leadIndex":1,"confidence":0.95}]}"#
            }
            return contradict ? #"{"leadIndex":2,"confidence":0.95}"# : #"{"leadIndex":1,"confidence":0.95}"#
        }
        let reviewer = ThumbnailSubjectVerifier(model: gateway, leadingCast: ["Головний актор", "Інший актор"])
        if contradict {
            await #expect(throws: ThumbnailSelectionError.self) {
                try await reviewer.select(from: candidates, movieTitle: "Фільм")
            }
        } else {
            let (selected, evidence) = try await reviewer.select(from: candidates, movieTitle: "Фільм")
            #expect(selected.time == 30)
            #expect(evidence.leadingCast == ["Головний актор", "Інший актор"])
        }
    }

    @Test("Sampling includes the film beyond the essay and remains bounded")
    func frameCoverage() {
        let times = LongformThumbnailCandidateSelector.candidateTimestamps(segments: [TimeSegment(start: 50, end: 80)], duration: 8_000)
        #expect(times.contains { $0 >= 7_000 })
        #expect(times.contains(65))
        #expect(times.count <= 96)
        #expect(times.allSatisfy { $0 >= 0 && $0 < 8_000 })
        #expect(LongformThumbnailCandidateSelector.candidateTimestamps(segments: [], duration: .nan).isEmpty)
    }

    @Test("Composition keeps the confirmed face inside the photograph pane")
    func faceCrop() {
        let canvas = CGSize(width: 1920, height: 1080)
        let face = CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.4)
        let rect = LongformThumbnailComposer.imageRect(imageSize: canvas, faceBox: face, canvas: canvas)
        let center = CGPoint(x: rect.minX + face.midX * rect.width, y: rect.minY + face.midY * rect.height)
        #expect(center.x > canvas.width * 0.4 && center.x < canvas.width)
        #expect(center.y > 0 && center.y < canvas.height)
    }

    @Test("Updating text retains the exact rendered video, timeline and audio settings")
    func textDoesNotRender() {
        let original = result(), updated = LongformPackagingService.updatingText(result())
        #expect(updated.outputURL == original.outputURL)
        #expect(updated.arc == original.arc)
        #expect(updated.duration == original.duration)
        #expect(updated.audioSettings == original.audioSettings)
        #expect(updated.metadata.title.contains(original.arc.movieTitle))
    }
}

@Suite("Live essay packaging", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_PACKAGING"] == "1"))
@MainActor
struct LiveEssayPackagingTests {
    @Test func refreshesRealEssayWithoutTouchingVideo() async throws {
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club") && $0.longformResult != nil
        })
        let original = try #require(project.longformResult)
        let path = try #require(ProcessInfo.processInfo.environment["SHORTCAST_PACKAGING_SOURCE"])
        let before = try FileManager.default.attributesOfItem(atPath: original.outputURL.path)
        let manager = ModelManager()
        let generator = LongformPackagingService.makeThumbnailGenerator(modelManager: manager, movie: project.tmdbMetadata)
        let updated = try await LongformPackagingService(thumbnailGenerator: generator).refresh(original,
            sourceURL: URL(fileURLWithPath: path))
        #expect(updated.packagingWarning == nil)
        let subject = try #require(updated.thumbnailSubject)
        let leads = Array((project.tmdbMetadata?.characters ?? []).prefix(2))
        #expect(subject.leadingCast == leads)
        let cover = try #require(updated.thumbnailURL)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(updated.outputURL == original.outputURL && updated.arc == original.arc)
        let after = try FileManager.default.attributesOfItem(atPath: original.outputURL.path)
        #expect(before[.size] as? Int == after[.size] as? Int)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-packaging-refreshed-result.json"), options: .atomic)
        print("PACKAGING_PROBE title=\(updated.metadata.title) leadingCast=\(subject.leadingCast.joined(separator: ", ")) time=\(subject.sourceTime)")
        print("PACKAGING_PROBE cover=\(cover.path) hashtags=\(updated.metadata.hashtagText)")
    }
}
