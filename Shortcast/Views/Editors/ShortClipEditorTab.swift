import SwiftUI

/// Вкладки меню редактирования шортса.
/// Single Responsibility Principle (SRP): инкапсулирует навигацию и структуру разделов редактора.
enum ShortClipEditorTab: String, CaseIterable, Identifiable, Sendable {
    case content = "content"
    case scene = "scene"
    case subtitles = "subtitles"
    case styleAudio = "styleAudio"
    case publish = "publish"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .content:
            return "Контент"
        case .scene:
            return "Монтаж сцены"
        case .subtitles:
            return "Субтитры"
        case .styleAudio:
            return "Стиль и звук"
        case .publish:
            return "Публикация"
        }
    }

    var icon: String {
        switch self {
        case .content:
            return "film"
        case .scene:
            return "scissors"
        case .subtitles:
            return "captions.bubble.fill"
        case .styleAudio:
            return "paintpalette.fill"
        case .publish:
            return "paperplane.fill"
        }
    }
}
