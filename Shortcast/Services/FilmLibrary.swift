import AppKit
import Foundation
import Observation

@MainActor @Observable
final class FilmLibrary {
    static let shared = FilmLibrary()
    struct Download: Codable, Identifiable {
        var id: String { film.id }
        let film: PlannedFilm
        let torrent: URL
        let folder: URL
        let file: String
        let index: Int
        let bytes: Int64
        var state: String
        var readyURL: URL? = nil
        var progress: String = ""
        var sourceURL: URL { folder.appendingPathComponent(file) }
    }
    var films: [PlannedFilm] = []
    var completed: Set<String> = []
    var downloads: [Download] = []
    var error: String?
    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private var polling: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let text = defaults.string(forKey: "filmPlan.markdown") { films = PlannedFilm.parse(text) }
        else if let url = Bundle.main.url(forResource: "essays_20_films", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) { films = PlannedFilm.parse(text) }
        if let saved = defaults.array(forKey: "filmPlan.completed") as? [String] { completed = Set(saved) }
        else { completed = Set(films.prefix(3).map(\.id)); defaults.set(Array(completed), forKey: "filmPlan.completed") }
        if let data = defaults.data(forKey: "filmPlan.downloads"), let saved = try? JSONDecoder().decode([Download].self, from: data) {
            downloads = saved.map { var task = $0; if task.state == "Загрузка" { task.state = "Приостановлено" }; return task }
        }
    }
    func importPlan(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = PlannedFilm.parse(text)
        guard !parsed.isEmpty else { throw TorrentManifest.invalid }
        films = parsed; defaults.set(text, forKey: "filmPlan.markdown")
    }
    func notePrepared(source: URL, output: URL) {
        guard let index = downloads.firstIndex(where: { $0.sourceURL.standardizedFileURL == source.standardizedFileURL }) else { return }
        downloads[index].readyURL = output; downloads[index].state = "MP4 готов"; save()
    }
    func isManaged(_ source: URL) -> Bool { downloads.contains { $0.sourceURL.standardizedFileURL == source.standardizedFileURL } }
    func toggleCompleted(_ film: PlannedFilm) {
        if completed.contains(film.id) { completed.remove(film.id) } else { completed.insert(film.id) }
        defaults.set(Array(completed), forKey: "filmPlan.completed")
    }
    private func save() {
        do { defaults.set(try JSONEncoder().encode(downloads), forKey: "filmPlan.downloads") }
        catch { self.error = error.localizedDescription }
    }
    nonisolated static func requireSpace(folder: URL, bytes: Int64) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw NSError(domain: "FilmLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey: "Недостаточно места: нужно около \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) для исходника и MP4."])
        }
    }
    func enqueue(film: PlannedFilm, torrent: URL, file: TorrentManifest.File, workingDirectory: URL) throws {
        guard !downloads.contains(where: { $0.id == film.id }) else { throw NSError(domain: "FilmLibrary", code: 3, userInfo: [NSLocalizedDescriptionKey: "Фильм уже есть в загрузках. Продолжите существующую задачу."]) }
        let folder = workingDirectory.appendingPathComponent("films/\(film.number)-\(film.year)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.requireSpace(folder: folder, bytes: file.bytes > Int64.max / 3 ? Int64.max : file.bytes * 3)
        let saved = folder.appendingPathComponent("source.torrent")
        try Data(contentsOf: torrent).write(to: saved, options: .atomic)
        downloads.append(Download(film: film, torrent: saved, folder: folder, file: file.path, index: file.index, bytes: file.bytes, state: "Приостановлено")); save()
        try resume(film.id)
    }
    func resume(_ id: String) throws {
        guard let index = downloads.firstIndex(where: { $0.id == id }), processes[id] == nil else { return }
        let task = downloads[index]
        guard let engine = BinaryDownloadService.resolveBinary("aria2c", workingDirectory: nil) else {
            throw NSError(domain: "FilmLibrary", code: 4, userInfo: [NSLocalizedDescriptionKey: "Для торрентов нужен aria2. Установите его командой brew install aria2."])
        }
        let existing = (try? task.sourceURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        let remaining = max(0, task.bytes - Int64(existing))
        try Self.requireSpace(folder: task.folder, bytes: remaining > Int64.max / 3 ? Int64.max : remaining * 3)
        let log = task.folder.appendingPathComponent("download.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process(); process.executableURL = engine
        process.arguments = ["--no-conf=true", "--stop-with-process=\(ProcessInfo.processInfo.processIdentifier)", "--dir=" + task.folder.path, "--select-file=\(task.index)", "--seed-time=0", "--check-integrity=true", "--file-allocation=none", "--auto-file-renaming=false", "--allow-overwrite=false", "--summary-interval=1", "--console-log-level=notice", "--enable-color=false", "--bt-remove-unselected-file=true", task.torrent.path]
        process.standardOutput = output; process.standardError = output
        try process.run(); processes[id] = process; downloads[index].state = "Загрузка"; error = nil; save()
        OperationJournal.shared.append("Скачиваю \(task.film.title) в \(task.folder.path)")
        polling[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let i = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                if let handle = try? FileHandle(forReadingFrom: log) {
                    let end = (try? handle.seekToEnd()) ?? 0
                    try? handle.seek(toOffset: end > 6000 ? end - 6000 : 0)
                    let data = (try? handle.readToEnd()) ?? Data(); try? handle.close()
                    self.downloads[i].progress = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).last(where: { $0.contains("DL:") || $0.contains("ERR") || $0.contains("NOTICE") }) ?? "Ожидаю раздающих…"
                }
                guard !process.isRunning else { continue }
                self.processes[id] = nil
                if self.downloads[i].state == "Загрузка" {
                    let complete = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: task.sourceURL.path)
                    self.downloads[i].state = complete ? "Скачан" : "Ошибка загрузки"
                    OperationJournal.shared.append(complete ? "Фильм скачан и проверен: \(task.film.title)" : "Ошибка загрузки \(task.film.title): \(self.downloads[i].progress)", level: complete ? .info : .error)
                }
                self.save(); self.polling[id] = nil; return
            }
        }
    }
    func pause(_ id: String) {
        guard processes[id]?.isRunning == true, let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].state = "Приостановлено"; processes[id]?.interrupt(); save()
    }
    func remove(_ id: String, deleteFiles: Bool) throws {
        guard processes[id] == nil, let task = downloads.first(where: { $0.id == id }) else { return }
        if deleteFiles { try FileManager.default.trashItem(at: task.folder, resultingItemURL: nil) }
        downloads.removeAll { $0.id == id }; save()
    }
}
