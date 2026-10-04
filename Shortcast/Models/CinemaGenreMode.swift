import Foundation

/// Defines how cinema moments are detected and directed:
/// - auto: Automatically infer from TMDB movie genres (if comedy/humor → comedy mode, else drama).
/// - drama: Focus on deep thoughts, moral conflicts, stoicism, high-stakes negotiations.
/// - comedy: Focus on setup, absurdity escalation, witty comebacks, and punchlines.
/// Adheres to Single Responsibility Principle (SRP).
enum CinemaGenreMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case drama = "drama"
    case comedy = "comedy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто (по фильму)"
        case .drama: return "Драма / Конфликт"
        case .comedy: return "Комедия / Юмор"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .drama: return "theatermasks.fill"
        case .comedy: return "face.smiling.inverse"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Автоматически определяет жанр по метаданным TMDB"
        case .drama: return "Глубокие мысли, стоицизм, моральный выбор, напряжённые диалоги"
        case .comedy: return "Смешные реплики, курьёзы, сетап → эскалация → панчлайн"
        }
    }
}
