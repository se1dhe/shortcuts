import Foundation
import Observation

/// Сервис управления состоянием коротких видео (шортсов).
/// Отвечает за: клипы, рендер шортсов, публикация.
/// Выделено из WorkspaceModel (SOLID: Single Responsibility).
/// 
/// TODO: Миграция из WorkspaceModel:
/// - clips: [ShortClip]
/// - variants: [PostVariant]
/// - detectedLanguage
/// - Методы: processPrecutShort, startShortsPipeline, publishClip, etc.
@MainActor
@Observable
final class ShortsStateService {
    
    /// The generated shorts (long-video flow).
    var clips: [ShortClip] = []
    
    /// The three proposed posts (single-video flow). Bound by the result cards.
    var variants: [PostVariant] = []
    
    var detectedLanguage: String?
    
    /// Очищает состояние шортсов
    func clearShortsState() {
        clips = []
        variants = []
        detectedLanguage = nil
    }
}
