import Foundation
import Observation

/// Сервис управления состоянием проектов фильмов.
/// Отвечает за: создание/загрузку проектов, транскрипты, сохранение на диск.
/// Выделено из WorkspaceModel (SOLID: Single Responsibility).
@MainActor
@Observable
final class ProjectStateService {
    
    /// Активный проект фильма
    var currentProject: FilmProject?
    
    /// Хранит полный транскрипт фильма
    var storedTranscript: Transcript?
    
    /// Сервис для работы с архивами проектов на диске
    let filmProjectService: any FilmProjectServicing
    
    init(filmProjectService: any FilmProjectServicing = FilmProjectService.shared) {
        self.filmProjectService = filmProjectService
    }
    
    /// Загружает проект из архива
    func loadProject(for url: URL) async throws -> FilmProject? {
        return try? await filmProjectService.loadProject(for: url)
    }
    
    /// Сохраняет проект в архив
    func saveProject(_ project: FilmProject) async {
        try? await filmProjectService.saveProject(project)
    }
    
    /// Очищает состояние проекта
    func clearProject() {
        currentProject = nil
        storedTranscript = nil
    }
}
