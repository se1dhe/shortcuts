import Foundation
import Observation

/// Сервис управления состоянием UI.
/// Отвечает за: фаза, прогресс, ошибки, настройки UI.
/// Выделено из WorkspaceModel (SOLID: Single Responsibility).
/// 
/// TODO: Миграция из WorkspaceModel:
/// - phase, inputMode
/// - errorMessage, pipelineError, publishReport, publishError
/// - pendingAudioSelection
/// - progressTracker
/// - Методы: reset, cancel, etc.
@MainActor
@Observable
final class UIStateService {
    
    enum Phase: Equatable {
        case empty
        // Single-video flow:
        case processing
        case results
        // Shorts flow:
        case transcribing
        case findingMoments
        case shortsResults
        // Longform flow:
        case selectingLongformConcept
        case editingLongformSubtitles
        case buildingLongform(fraction: Double, step: String)
        case longformResults
    }
    
    enum InputMode: String, CaseIterable, Identifiable, Sendable {
        case shorts    // long video → cut into clips → caption each → publish
        case longform  // фильм → 4-актное кино-эссе (16:9 YouTube, 5-8 мин, Shortcast Cinema)
        case caption   // short video → captions → publish (the original flow)
        case youtube   // search YouTube → download → use the long-video flow
        
        var id: String { rawValue }
    }
    
    /// The selected mode. Drives routing in `process(url:)`.
    var inputMode: InputMode = .shorts
    
    private(set) var phase: Phase = .empty
    
    /// Non-fatal banner shown on the drop screen.
    var errorMessage: String?
    
    /// Fatal pipeline error (transcription / moment-finding failed).
    var pipelineError: String?
    
    /// Publish report (success/failure) for the current clip.
    var publishReport: String?
    
    /// Error from the last latest publish attempt.
    var publishError: String?
    
    /// Pending audio track selection (shown when multiple tracks detected)
    var pendingAudioSelection: PendingAudioSelection?
    
    /// Сбрасывает состояние UI
    func resetUIState() {
        phase = .empty
        errorMessage = nil
        pipelineError = nil
        publishReport = nil
        publishError = nil
        pendingAudioSelection = nil
    }
}
