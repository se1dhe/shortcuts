import Testing
import Foundation
import SwiftUI
import AppKit
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

@Suite("Operation journal")
struct OperationJournalTests {
    @Test func retainsFullHistoryAndStartsANewOperation() {
        let journal = OperationJournal()
        journal.begin("Начало монтажа")
        for index in 0..<250 { journal.append("Сцена \(index)") }
        journal.append("Повторная попытка: модель вернула неверный ответ", level: .warning)
        journal.append("Экспорт остановлен: нет места на диске", level: .error)
        let entries = journal.snapshot()
        #expect(entries.count == 253)
        #expect(entries.first?.message == "Начало монтажа")
        #expect(entries[251].level == .warning)
        #expect(entries[252].level == .error)
        journal.begin("Следующая операция")
        #expect(journal.snapshot().map(\.message) == ["Следующая операция"])
        #expect(OperationJournal.inferredLevel("stage=essay attempt 1: selection rejected") == .warning)
        #expect(OperationJournal.inferredLevel("Мастеринг звука") == .info)
    }

    @Test func concurrentWritersKeepEveryDistinctEvent() async {
        let journal = OperationJournal()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { journal.append("event \(index)") }
            }
        }
        #expect(journal.snapshot().count == 200)
        #expect(Set(journal.snapshot().map(\.message)).count == 200)
    }

    @MainActor
    @Test func logPanelRendersAllThreeSeverities() throws {
        let journal = OperationJournal()
        journal.begin("Сборка кино-эссе · Интерстеллар")
        journal.append("Названия актов готовы. Собираем видеокомпозицию 1920×1080…")
        journal.append("Фоновая музыка не найдена. Продолжаем с оригинальным звуком.", level: .warning)
        journal.append("Экспорт остановлен: недостаточно места на диске.", level: .error)
        let view = OperationLogPanel(journal: journal)
            .frame(width: 1120, height: 280).background(StudioTheme.background).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1120, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 280)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/shortcast-operation-log-preview.png"))
    }
}

@MainActor
@Suite("Live operation journal")
struct LiveOperationJournalTests {
    @Test func initiallyEmptyJournalStartsFollowingEvents() async throws {
        let journal = OperationJournal()
        let host = NSHostingView(rootView: OperationLogPanel(journal: journal))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1120, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        journal.append("Первое действие после открытия экрана")
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 100)
    }
}
