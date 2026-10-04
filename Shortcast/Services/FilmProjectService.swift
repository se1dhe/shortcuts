import Foundation
import os.log

/// Протокол управления проектами фильмов (SOLID: Interface Segregation & Dependency Inversion).
public protocol FilmProjectServicing: Sendable {
    func loadProject(for movieURL: URL) async throws -> FilmProject?
    func saveProject(_ project: FilmProject) async throws
    func deleteProject(id: UUID) async throws
    func listRecentProjects() async throws -> [FilmProject]
}

/// Потокобезопасная реализация хранилища проектов фильмов.
/// Сохраняет проекты в Application Support/Shortcast/Projects в формате JSON.
public final class FilmProjectService: FilmProjectServicing, Sendable {

    public static let shared = FilmProjectService()

    private static let logger = Logger(subsystem: "app.shortcast", category: "FilmProjectService")

    private let storageDirectory: URL

    public init(storageDirectory: URL? = nil) {
        if let custom = storageDirectory {
            self.storageDirectory = custom
        } else {
            let appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Shortcast/Projects", isDirectory: true)
            self.storageDirectory = appSupport
        }
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(id.uuidString).shortcastproj")
    }

    private func keyFor(movieURL: URL) -> String {
        let size = (try? movieURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = movieURL.lastPathComponent
        return "\(name)_\(size)"
    }

    public func loadProject(for movieURL: URL) async throws -> FilmProject? {
        let key = keyFor(movieURL: movieURL)
        let projects = try await listRecentProjects()
        return projects.first { p in
            p.sourceMovieURL == movieURL || keyFor(movieURL: p.sourceMovieURL) == key
        }
    }

    public func saveProject(_ project: FilmProject) async throws {
        var updated = project
        updated.updatedAt = Date()
        let url = fileURL(for: updated.id)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(updated)
        try data.write(to: url, options: .atomic)
        Self.logger.notice("Saved project \(updated.movieTitle) (\(updated.id.uuidString))")
    }

    public func deleteProject(id: UUID) async throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func listRecentProjects() async throws -> [FilmProject] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [FilmProject] = []
        for file in files where file.pathExtension == "shortcastproj" {
            guard let data = try? Data(contentsOf: file),
                  let project = try? decoder.decode(FilmProject.self, from: data) else {
                continue
            }
            loaded.append(project)
        }

        return loaded.sorted { $0.updatedAt > $1.updatedAt }
    }
}
