import Testing
import Foundation
@testable import Shortcast

@Suite("DirectorRunLog Tests")
struct DirectorRunLogTests {

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-director-log-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("every stage line lands in director.log")
    func testWriteAppendsToLogFile() throws {
        let dir = makeDirectory()
        DirectorRunLog.write("analyzeThematicCore: profile=Gemma 4 12B", directory: dir)
        DirectorRunLog.write("analyzeThematicCore attempt 1: 31488 chars", directory: dir)
        let text = try String(
            contentsOf: dir.appendingPathComponent("director.log"),
            encoding: .utf8
        )
        #expect(text.contains("profile=Gemma 4 12B"))
        #expect(text.contains("attempt 1: 31488 chars"))
    }

    @Test("raw model replies are kept, but only the last three")
    func testKeepsOnlyTheLastThreeRawDumps() throws {
        let dir = makeDirectory()
        for attempt in 1...5 {
            DirectorRunLog.dumpRaw("raw reply \(attempt)", attempt: attempt, directory: dir)
            // Разные секунды: обрезка идёт по дате изменения файла.
            Thread.sleep(forTimeInterval: 0.02)
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("director-raw-") }
        #expect(files.count == 3)
        let kept = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(kept.contains("raw reply 5"))
        #expect(!kept.contains("raw reply 1"))
    }
}
