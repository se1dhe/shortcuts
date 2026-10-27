import Foundation

/// Долговечный журнал Director: приложение запускается через `open`, поэтому
/// stderr с этапами анализа уходит в /dev/null. Тот же поток дописывается в
/// `~/Library/Logs/Shortcast/director.log`, а сырые ответы модели сохраняются
/// отдельными файлами — разбор сбоя идёт по тексту, а не по памяти процесса.
enum DirectorRunLog {

    private static let lock = NSLock()
    private static let maxRawDumps = 3

    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Shortcast", isDirectory: true)
    }

    static func write(
        _ message: String,
        source: String = "director",
        directory: URL = DirectorRunLog.directory
    ) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data("[shortcast/\(source)] \(message)\n".utf8))
        append("[\(timestamp())] \(message)\n",
               to: directory.appendingPathComponent("director.log"),
               in: directory)
    }

    static func dumpRaw(_ raw: String, attempt: Int, directory: URL = DirectorRunLog.directory) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1_000_000))
        let url = directory.appendingPathComponent("director-raw-\(stamp)-attempt\(attempt).txt")
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
    private static func pruneRawDumps(in directory: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        let raws = urls
            .filter { $0.lastPathComponent.hasPrefix("director-raw-") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return l > r
            }
        for url in raws.dropFirst(maxRawDumps) {
            try? fm.removeItem(at: url)
        }
    }
}
