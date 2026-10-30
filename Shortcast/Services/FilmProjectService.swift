import Foundation
import os

/// Протокол управления проектами фильмов (SOLID: Interface Segregation & Dependency Inversion).
protocol FilmProjectServicing: Sendable {
    func loadProject(for movieURL: URL) async throws -> FilmProject?
    func saveProject(_ project: FilmProject) async throws
    func deleteProject(id: UUID) async throws
    func listRecentProjects() async throws -> [FilmProject]

    /// Есть ли на диске архив этого фильма — читаемый или битый. Нужен, чтобы
    /// пустой проект не перезаписал то, что мы не смогли прочитать.
    func hasStoredProjectFile(matching movieURL: URL) async -> Bool
}

extension FilmProjectServicing {
    /// Реализация по умолчанию: архива нет — можно создавать новый проект.
    func hasStoredProjectFile(matching movieURL: URL) async -> Bool { false }
}

/// Потокобезопасная реализация хранилища проектов фильмов.
/// Сохраняет проекты в Application Support/Shortcast/Projects в формате JSON.
final class FilmProjectService: FilmProjectServicing, Sendable {

    static let shared = FilmProjectService()

    private static let logger = Logger(subsystem: "app.shortcast", category: "FilmProjectService")

    private let storageDirectory: URL
    private let corruptionLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Сколько архивов пострадало при последнем сканировании каталога: не читается
    /// целиком или содержит поля, которые не удалось разобрать.
    var corruptedProjectCount: Int { corruptionLock.withLock { $0 } }

    init(storageDirectory: URL? = nil) {
        if let custom = storageDirectory {
            self.storageDirectory = custom
        } else {
            let appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Shortcast/Projects", isDirectory: true)
            self.storageDirectory = appSupport
        }
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).shortcastproj")
    }

    private func keyFor(movieURL: URL) -> String {
        let size = (try? movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = movieURL.lastPathComponent
        return "\(name)_\(size)"
    }

    func loadProject(for movieURL: URL) async throws -> FilmProject? {
        let incomingBaseName = movieURL.deletingPathExtension().lastPathComponent
        let incomingFullName = movieURL.lastPathComponent
        // URL.resourceValues может вернуть закэшированный размер того же URL
        // после замены файла. Для идентичности нужен свежий stat.
        let incomingSize = ((try? FileManager.default.attributesOfItem(atPath: movieURL.path)[.size]) as? NSNumber)?.int64Value ?? 0

        let projects = try await listRecentProjects()

        return projects.first { p in
            // URL может остаться тем же после замены файла другим фильмом.
            if let savedSize = p.fileSizeBytes, savedSize > 0, incomingSize > 0,
               savedSize != incomingSize { return false }
            // 1. Прямое совпадение URL
            if p.sourceMovieURL == movieURL {
                return true
            }

            // 2. Совпадение по имени файла (с расширением или без)
            let pBaseName = p.sourceMovieURL.deletingPathExtension().lastPathComponent
            let pFullName = p.sourceMovieURL.lastPathComponent
            let nameMatches = (incomingBaseName == pBaseName ||
                               incomingFullName == pFullName ||
                               incomingBaseName == p.movieFileName ||
                               incomingFullName == p.movieFileName)

            guard nameMatches else { return false }

            // Если у проекта сохранен точный размер файла — сверяем
            if let savedSize = p.fileSizeBytes, savedSize > 0 && incomingSize > 0 {
                return savedSize == incomingSize
            }

            // Fallback для старых проектов без fileSizeBytes
            let legacySavedSize = (try? p.sourceMovieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            if legacySavedSize > 0 && incomingSize > 0 {
                return legacySavedSize == incomingSize
            }

            // Если размер недоступен, но имя файла уникально совпадает
            return true
        }
    }

    func saveProject(_ project: FilmProject) async throws {
        var updated = project
        updated.updatedAt = Date()

        if updated.fileSizeBytes == nil || updated.fileSizeBytes == 0 {
            if let size = (try? updated.sourceMovieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                updated.fileSizeBytes = Int64(size)
            }
        }

        let url = fileURL(for: updated.id)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(updated)
        try data.write(to: url, options: .atomic)
        Self.logger.notice("Saved project \(updated.movieTitle) (\(updated.id.uuidString))")
    }

    func deleteProject(id: UUID) async throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func listRecentProjects() async throws -> [FilmProject] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        let decoder = makeDecoder()

        var loaded: [FilmProject] = []
        var corrupted = 0
        for file in files where file.pathExtension == "shortcastproj" {
            do {
                let data = try Data(contentsOf: file)
                let project = try decoder.decode(FilmProject.self, from: data)
                if !project.decodeDamage.isEmpty {
                    // Проект загружен, но часть данных потеряна — это не молчаливая
                    // потеря фильма, но и не норма: порчу видно в логе и в счётчике.
                    Self.logger.error("Project \(file.lastPathComponent) loaded damaged at: \(project.decodeDamage.joined(separator: ", "))")
                    corrupted += 1
                }
                loaded.append(project)
            } catch {
                // Молча пропущенный проект раньше приводил к перезаписи пустым.
                Self.logger.error("Skipping unreadable project \(file.lastPathComponent): \(error.localizedDescription)")
                corrupted += 1
            }
        }

        let corruptedCount = corrupted
        corruptionLock.withLock { $0 = corruptedCount }
        if corruptedCount > 0 {
            let folder = storageDirectory.path
            Self.logger.error("\(corruptedCount) corrupted project archive(s) under \(folder)")
        }

        return loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Ищет архив этого фильма, не требуя, чтобы он читался: битый файл тоже
    /// отвечает «да», и тогда пустой проект его не перезапишет.
    func hasStoredProjectFile(matching movieURL: URL) async -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = makeDecoder()
        let baseName = movieURL.deletingPathExtension().lastPathComponent
        let fullName = movieURL.lastPathComponent

        for file in files where file.pathExtension == "shortcastproj" {
            guard let data = try? Data(contentsOf: file) else {
                Self.logger.error("Project \(file.lastPathComponent) exists but cannot be read")
                continue
            }
            if let project = try? decoder.decode(FilmProject.self, from: data) {
                let matches = project.sourceMovieURL == movieURL
                    || project.sourceMovieURL.lastPathComponent == fullName
                    || project.movieFileName == baseName
                    || project.movieFileName == fullName
                if matches { return true }
                continue
            }
            guard baseName.count > 2, let text = String(data: data, encoding: .utf8) else { continue }
            if text.contains(movieURL.path) || text.contains(fullName) || text.contains(baseName) {
                Self.logger.error("Found unreadable archive \(file.lastPathComponent) for \(movieURL.lastPathComponent)")
                return true
            }
        }
        return false
    }
}
