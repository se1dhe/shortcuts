import Testing
import Foundation
@testable import Shortcast

@Suite("Folder Bookmark Persistence Tests")
@MainActor
struct FolderBookmarkTests {

    private func makeTempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "shortcast-bookmark-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The app is unsandboxed, where `.withSecurityScope` bookmark resolution
    /// throws — every chosen folder used to read back as nil. Plain resolution
    /// of the same data must succeed.
    @Test("Security-scoped bookmark data resolves despite failed scoped attempt")
    func testResolverFallsBackToPlainResolution() throws {
        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        let resolved = AppSettings.resolveFolderBookmark(data)
        #expect(resolved?.url.standardizedFileURL == dir.standardizedFileURL)
    }

    /// Full user-visible contract: pick a folder in settings, relaunch the app
    /// (fresh AppSettings over the same defaults) — the folder must still be there.
    @Test("Chosen folders survive a settings reload")
    func testFolderSurvivesSettingsReload() throws {
        let suiteName = "shortcast-tests.bookmarks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppSettings(defaults: defaults)
        first.movieLibraryURL = dir
        first.workingDirectory = dir
        first.outputDirectory = dir

        let second = AppSettings(defaults: defaults)
        #expect(second.movieLibraryURL?.standardizedFileURL == dir.standardizedFileURL)
        #expect(second.workingDirectory?.standardizedFileURL == dir.standardizedFileURL)
        #expect(second.outputDirectory?.standardizedFileURL == dir.standardizedFileURL)
    }

    /// Clearing a folder (xmark button) must remove the persisted bookmark.
    @Test("Clearing a folder removes its persisted bookmark")
    func testClearingFolderRemovesBookmark() throws {
        let suiteName = "shortcast-tests.bookmarks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dir = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = AppSettings(defaults: defaults)
        settings.movieLibraryURL = dir
        #expect(defaults.data(forKey: "shortcast.movieLibraryBookmark") != nil)
        settings.movieLibraryURL = nil
        #expect(defaults.data(forKey: "shortcast.movieLibraryBookmark") == nil)
        #expect(settings.movieLibraryURL == nil)
    }
}
