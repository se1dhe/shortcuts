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

    @Test("raw model replies are kept, but only the last eight")
    func testKeepsOnlyTheLastRawDumps() throws {
        let dir = makeDirectory()
        for attempt in 1...10 {
            DirectorRunLog.dumpRaw("raw reply \(attempt)", attempt: attempt, directory: dir)
            // Пауза не нужна (обрезка идёт по имени с микросекундным штампом),
            // но оставляем её как доказательство: порядок не зависит от даты файла.
            Thread.sleep(forTimeInterval: 0.02)
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("director-raw-") }
        #expect(files.count == 8)
        // Точное содержимое, а не `contains`: «raw reply 1» входит в «raw reply 10».
        let kept = Set(try files.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(kept == Set((3...10).map { "raw reply \($0)" }))
    }

    /// Двухэтапный Director обязан оставлять сырые дампы обеих стадий: иначе
    /// стадия 2 затирает доказательство того, какие темы предлагала модель.
    @Test("stage dumps are labelled and both stages survive one run")
    func testStageDumpsCoexist() throws {
        let dir = makeDirectory()
        DirectorRunLog.dumpRaw("stage 1 candidates", stage: "stage1", attempt: 1, directory: dir)
        Thread.sleep(forTimeInterval: 0.02)
        DirectorRunLog.dumpRaw("stage 2 essay plan", stage: "stage2", attempt: 1, directory: dir)

        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("director-raw-") }
        #expect(files.count == 2)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains { $0.contains("-stage1-") })
        #expect(names.contains { $0.contains("-stage2-") })
    }
}
