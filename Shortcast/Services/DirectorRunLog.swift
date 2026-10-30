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
