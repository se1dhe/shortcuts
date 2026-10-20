import Testing
import Foundation
@testable import Shortcast

@Suite("ExportLayout Tests")
struct ExportLayoutTests {

    // MARK: - Slug / directory name

    @Test("Sanitized directory name preserves Cyrillic")
    func testDirectoryNamePreservesCyrillicAndLatin() {
        let cases: [(String, String)] = [
            ("Бегущий по лезвию 2049", "Бегущий по лезвию 2049"),
            ("Субъективность", "Субъективность"),
            ("Револьвер", "Револьвер"),
            ("Interstellar", "Interstellar"),
        ]
        for (input, expected) in cases {
            #expect(ExportLayout.directoryName(for: input) == expected)
        }
    }

    @Test("Sanitized directory name strips forbidden characters")
    func testDirectoryNameStripsForbiddenChars() {
        let cases: [(String, String)] = [
            ("Film: Part 1", "Film Part 1"),
            ("AC/DC Live", "AC DC Live"),
            ("What?", "What"),
            ("He said \"no\"", "He said no"),
            ("path\\to/file", "path to file"),
            ("star**", "star"),
            ("a< b >c", "a b c"),
            ("x|y", "x y"),
        ]
        for (input, expected) in cases {
            #expect(ExportLayout.directoryName(for: input) == expected)
        }
    }

    @Test("Sanitized directory name collapses whitespace")
    func testDirectoryNameCollapsesSpaces() {
        #expect(ExportLayout.directoryName(for: "  Blade   Runner  ") == "Blade Runner")
    }

    @Test("Empty title falls back to Film")
    func testDirectoryNameEmptyFallback() {
        #expect(ExportLayout.directoryName(for: "") == "Фільм")
        #expect(ExportLayout.directoryName(for: "   ") == "Фільм")
    }

    @Test("Ukrainian characters are preserved")
    func testDirectoryNamePreservesUkrainian() {
        let cases: [(String, String)] = [
            ("Тіні забутих предків", "Тіні забутих предків"),
            ("Їжа та напої", "Їжа та напої"),
        ]
        for (input, expected) in cases {
            #expect(ExportLayout.directoryName(for: input) == expected)
        }
    }

    // MARK: - filmDirectory

    @Test("filmDirectory with nil workingDirectory uses temporary ShortcastExports")
    func testFilmDirectoryNilWorkingDirectory() throws {
        let title = "Test Film \(UUID().uuidString.prefix(6))"
        let dir = try ExportLayout.filmDirectory(workingDirectory: nil, movieTitle: title)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }

        #expect(dir.path.contains("ShortcastExports"))
        #expect(dir.path.contains("Exports"))
        #expect(dir.lastPathComponent == ExportLayout.directoryName(for: title))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("filmDirectory creates nested Exports/<title> under working directory")
    func testFilmDirectoryWithWorkingDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutTests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let dir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Бегущий")
        #expect(dir.lastPathComponent == "Бегущий")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "Exports")
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Artifact naming

    @Test("Artifact name follows kind_base_uuid6.ext pattern")
    func testArtifactNaming() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutArtifact-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let dir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Test")

        let url = ExportLayout.artifact(in: dir, kind: .longformVideo, base: "субъективность", ext: "mp4")
        let name = url.lastPathComponent
        #expect(name.hasPrefix("longform_субъективность_"))
        #expect(name.hasSuffix(".mp4"))
        // uuid6 prefix is 6 chars
        let stem = name.replacingOccurrences(of: ".mp4", with: "")
        let parts = stem.split(separator: "_")
        #expect(parts.count == 3) // longform, субъективность, <uuid6>
        #expect(parts[2].count == 6)
    }

    @Test("Artifact with unique=false omits UUID suffix")
    func testArtifactNonUnique() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutNoUUID-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let dir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Test")

        let url = ExportLayout.artifact(in: dir, kind: .cover, base: "interstellar", ext: "jpg", unique: false)
        #expect(url.lastPathComponent == "thumbnail_interstellar.jpg")
    }

    // MARK: - Collision retry

    @Test("Collision retry appends -2, -3, etc.")
    func testCollisionRetry() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutCollision-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let dir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Test")

        // Create a file that will collide with the non-unique name
        let existing = dir.appendingPathComponent("thumbnail_test.jpg")
        FileManager.default.createFile(atPath: existing.path, contents: Data("fake".utf8))

        let url = ExportLayout.artifact(in: dir, kind: .cover, base: "test", ext: "jpg", unique: false)
        // Should have -2 suffix since the base name exists
        #expect(url.lastPathComponent == "thumbnail_test-2.jpg")

        // Create the -2 file too
        FileManager.default.createFile(atPath: url.path, contents: Data("fake".utf8))
        let url3 = ExportLayout.artifact(in: dir, kind: .cover, base: "test", ext: "jpg", unique: false)
        #expect(url3.lastPathComponent == "thumbnail_test-3.jpg")
    }

    // MARK: - Loudnorm neighbor

    @Test("Loudnorm temporary file lands in same directory as nested output")
    func testLoudnormNeighbor() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutLoudnorm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let filmDir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Фильм")

        let outputURL = ExportLayout.artifact(in: filmDir, kind: .longformVideo, base: "тема", ext: "mp4")
        let tempURL = LongformLoudnessService.makeTemporaryURL(for: outputURL)

        // Same parent directory — same volume, atomic rename works
        #expect(tempURL.deletingLastPathComponent() == outputURL.deletingLastPathComponent())
        #expect(tempURL.pathExtension == "mp4")
        #expect(tempURL.lastPathComponent.hasPrefix("loudnorm_"))
    }

    // MARK: - Video + cover in same dir

    @Test("Video and cover artifacts land in the same film directory")
    func testVideoAndCoverSameDir() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutSameDir-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let filmDir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Test")

        let videoURL = ExportLayout.artifact(in: filmDir, kind: .longformVideo, base: "тема", ext: "mp4")
        let coverURL = ExportLayout.artifact(in: filmDir, kind: .cover, base: "тема", ext: "jpg")

        #expect(videoURL.deletingLastPathComponent() == filmDir)
        #expect(coverURL.deletingLastPathComponent() == filmDir)
        #expect(videoURL.lastPathComponent.hasPrefix("longform_"))
        #expect(coverURL.lastPathComponent.hasPrefix("thumbnail_"))
    }

    // MARK: - Shorts directory

    @Test("Shorts directory is nested inside film directory")
    func testShortsDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportLayoutShorts-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let filmDir = try ExportLayout.filmDirectory(workingDirectory: tempRoot, movieTitle: "Test")
        let shortsDir = try ExportLayout.shortsDirectory(in: filmDir)

        #expect(shortsDir.lastPathComponent == "shorts")
        #expect(shortsDir.deletingLastPathComponent() == filmDir)
        #expect(FileManager.default.fileExists(atPath: shortsDir.path))
    }

    // MARK: - fileNameBase

    @Test("fileNameBase strips forbidden chars and lowercases")
    func testFileNameBase() {
        #expect(ExportLayout.fileNameBase(from: "СУБЪЕКТИВНОСТЬ") == "субъективность")
        #expect(ExportLayout.fileNameBase(from: "Blade: Runner") == "blade-runner")
        #expect(ExportLayout.fileNameBase(from: "  ") == "")
    }
}
