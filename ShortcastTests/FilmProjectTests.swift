import Testing
import Foundation
@testable import Shortcast

@Suite("FilmProject Tests")
struct FilmProjectTests {

    @Test("Project serialization and deserialization preserves full state")
    func testSerialization() throws {
        let testURL = URL(fileURLWithPath: "/tmp/interstellar.mp4")
        let concept = ThematicConcept(
            word: "ТЕРПЕНИЕ",
            tagline: "Испытание расстоянием и временем",
            philosophicalPremise: "Идеально раскрывает лейтмотив Купера через жертву временем",
            suggestedTitle: "Почему время — самое безжалостное измерение",
            accentColorHex: "#F5D020"
        )

        let candidate = ClipCandidate(
            start: 120.0,
            end: 175.0,
            why: "Кульминационный диалог о гравитации",
            hook: "Он понял это только спустя 20 лет...",
            overlay: "Тайная комната"
        )

        let project = FilmProject(
            sourceMovieURL: testURL,
            movieFileName: "interstellar.mp4",
            movieTitle: "Интерстеллар",
            movieYear: "2014",
            durationSeconds: 10140.0,
            discoveredConcepts: [concept],
            selectedConcept: concept,
            candidates: [candidate]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(FilmProject.self, from: data)

        #expect(restored.movieTitle == "Интерстеллар")
        #expect(restored.movieYear == "2014")
        #expect(restored.discoveredConcepts.count == 1)
        #expect(restored.discoveredConcepts.first?.word == "ТЕРПЕНИЕ")
        #expect(restored.candidates.count == 1)
        #expect(restored.candidates.first?.hook == "Он понял это только спустя 20 лет...")
    }

    @Test("FilmProjectService can save, load, and delete projects in custom storage")
    func testServiceStorage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = FilmProjectService(storageDirectory: tempDir)

        let testURL = URL(fileURLWithPath: "/movies/whiplash.mkv")
        let project = FilmProject(
            sourceMovieURL: testURL,
            movieFileName: "whiplash.mkv",
            movieTitle: "Одержимость",
            durationSeconds: 6400.0
        )

        try await service.saveProject(project)

        let loaded = try await service.loadProject(for: testURL)
        #expect(loaded != nil)
        #expect(loaded?.movieTitle == "Одержимость")

        let all = try await service.listRecentProjects()
        #expect(all.count == 1)

        try await service.deleteProject(id: project.id)
        let afterDelete = try await service.loadProject(for: testURL)
        #expect(afterDelete == nil)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
