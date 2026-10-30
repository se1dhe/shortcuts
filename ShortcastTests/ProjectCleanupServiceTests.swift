import Foundation
import Testing
@testable import Shortcast

@Suite("Project cleanup preserves working media")
struct ProjectCleanupServiceTests {
    @Test("Only app-owned disposable files are deleted, with accurate recursive counts")
    func scopedCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("work"), temp = root.appendingPathComponent("temp")
        func file(_ relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 100).write(to: url)
            return url
        }
        let preserved = try ["work/input/film.mp4", "work/input/shortcast-normalized-film.mp4",
            "work/Exports/film/short.mp4", "work/test_original.mp4", "work/project.shortcastproj",
            "temp/test_other_app.mp4", "temp/other-film.wav"].map(file)
        let removed = try ["work/render-cache/nested/cache.mp4", "work/render-cache/cover.jpg",
                           "temp/shortcast-audio-old.m4a"].map(file)
        let service = ProjectCleanupService(temporaryDirectory: temp, cachesDirectory: nil, minimumAge: 0)
        #expect(await service.calculateRemovableSize(workingDirectory: working) == 300)
        let report = try await service.performDeepClean(workingDirectory: working)
        #expect(report.bytesFreed == 300 && report.filesRemovedCount == 3)
        #expect(preserved.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(removed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Cleanup does not follow a cache symlink or remove recent temporary media")
    func ignoresLinksAndRecentFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work"), originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("film.mp4")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("render-cache"), withDestinationURL: originals)
        let recent = work.appendingPathComponent("shortcast-active.mp4")
        try Data([4, 5, 6]).write(to: recent)
        let service = ProjectCleanupService(temporaryDirectory: work, cachesDirectory: nil)
        #expect(await service.calculateRemovableSize(workingDirectory: work) == 0)
        let report = try await service.performDeepClean(workingDirectory: work)
        #expect(report.filesRemovedCount == 0)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }
}
