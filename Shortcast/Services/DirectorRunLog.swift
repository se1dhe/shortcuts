import Foundation

/// Долговечный журнал Director: приложение запускается через `open`, поэтому
/// stderr с этапами анализа уходит в /dev/null. Тот же поток дописывается в
/// `~/Library/Logs/Shortcast/director.log`, а сырые ответы модели сохраняются
/// отдельными файлами — разбор сбоя идёт по тексту, а не по памяти процесса.
enum DirectorRunLog {

    private static let lock = NSLock()
    /// Дампы двух этапов + ретраи: два прогона по 2 попытки на стадию уже дают 4
    /// файла, а стадия 1 не имеет права затираться стадией 2 — разбор идёт по обоим.
    private static let maxRawDumps = 8

    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Shortcast", isDirectory: true)
    }

    static func write(
        _ message: String,
        source: String = "director",
        directory: URL = DirectorRunLog.directory
    ) {
        OperationJournal.shared.append(message)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("[shortcast/\(source)] \(message)\n".utf8))
        append("[\(timestamp())] \(message)\n",
               to: directory.appendingPathComponent("director.log"),
               in: directory)
    }

    /// `stage` попадает в имя файла, чтобы дамп стадии 1 было видно рядом с
    /// дампом стадии 2: без метки они различимы только микростемп'ом.
    static func dumpRaw(
        _ raw: String,
        stage: String = "director",
        attempt: Int,
        directory: URL = DirectorRunLog.directory
    ) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
        let url = directory.appendingPathComponent("director-raw-\(stamp)-\(stage)-attempt\(attempt).txt")
        try? Data(raw.utf8).write(to: url, options: .atomic)
        pruneRawDumps(in: directory)
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        date.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
    }

    private static func append(_ text: String, to url: URL, in directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        guard fm.fileExists(atPath: url.path) else {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Оставляет только последние ответы модели: полный поток за неделю
    /// разросся бы до гигабайт, а для разбора нужен лишь последний прогон.
    ///
    /// Порядок — по имени, а не по дате изменения: штамп в имени это микросекунды
    /// эпохи фиксированной ширины, поэтому лексикографически он сравнивается как
    /// число. `contentModificationDate` для двух дампов внутри одной секунды
    /// одинаков, и «какие восемь оставить» превращалось бы в лотерею.
    private static func pruneRawDumps(in directory: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let raws = urls
            .filter { $0.lastPathComponent.hasPrefix("director-raw-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in raws.dropFirst(maxRawDumps) {
            try? fm.removeItem(at: url)
        }
    }
}

/// Thread-safe journal shared by background services and every operation screen.
final class OperationJournal: @unchecked Sendable {
    enum Level: String, Sendable { case info, warning, error }
    struct Entry: Identifiable, Sendable {
        let id: UUID
        let time: Date
        let message: String
        let level: Level
    }
    static let shared = OperationJournal()
    private let lock = NSLock()
    private var entries: [Entry] = []

    func begin(_ title: String) {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        entries.append(Entry(id: UUID(), time: Date(), message: title, level: .info))
        lock.unlock()
    }

    func append(_ message: String, level: Level? = nil) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let severity = level ?? Self.inferredLevel(message)
        lock.lock()
        defer { lock.unlock() }
        guard entries.last?.message != message || entries.last?.level != severity else { return }
        entries.append(Entry(id: UUID(), time: Date(), message: message, level: severity))
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Retried/rejected candidates are recoverable; terminal failures are explicit
    /// at their call sites. A word inside a film title must not mark it critical.
    static func inferredLevel(_ message: String) -> Level {
        let value = message.lowercased()
        return ["⚠", "warning", "rejected", "fallback", "повторная попытка", "предупрежд", "недоступ", "не найдена", "обірван", "truncated", "failed"]
            .contains(where: value.contains) ? .warning : .info
    }
}
