import Foundation
import Observation

/// Сервис управления состоянием длинного видео (кино-эссе).
/// Отвечает за: темы, арки, рендер лонгформа, метаданные YouTube.
/// Выделено из WorkspaceModel (SOLID: Single Responsibility).
/// 
/// TODO: Миграция из WorkspaceModel:
/// - thematicAnalysis, selectedConcept, discoveredConcepts
/// - stagedArc, stagedConcept, stagedAudioSettings, stagedEssayPlan
/// - longformResult, longformBuildProgress
/// - Методы: startLongformPipeline, buildLongformVideo, etc.
@MainActor
@Observable
final class LongformStateService {
    
    /// Полный анализ фильма с ОДНОЙ главной темой и разбором ИИ
    var thematicAnalysis: ThematicAnalysisResult?
    
    /// Выбранная тема для ролика
    var selectedConcept: ThematicConcept?
    
    /// Промежуточные параметры эссе для редактора субтитров
    var stagedConcept: ThematicConcept?
    var stagedConfirmedMovieTitle: String?
    var stagedAudioSettings: LongformAudioSettings?
    var stagedArc: LongformNarrativeArc?
    var stagedEssayPlan: EssayPlan?
    
    /// Результат генерации длинного ролика
    var longformResult: LongformBuildResult?
    
    /// Прогресс рендеринга длинного видео
    var longformBuildProgress: (fraction: Double, step: String) = (0.0, "")
    
    /// Идёт ли прямо сейчас повторный анализ сценария моделью Director
    private(set) var isRegeneratingConcepts = false
    
    /// Очищает состояние лонгформа
    func clearLongformState() {
        thematicAnalysis = nil
        selectedConcept = nil
        stagedConcept = nil
        stagedConfirmedMovieTitle = nil
        stagedAudioSettings = nil
        stagedArc = nil
        stagedEssayPlan = nil
        longformResult = nil
        longformBuildProgress = (0.0, "")
    }
}
