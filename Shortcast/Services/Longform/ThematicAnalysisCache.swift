import CryptoKit
import Foundation

/// Один контракт для загрузки архива, экрана выбора темы и сборки эссе.
/// Метка llm говорит об авторстве, но не доказывает пригодность старого кэша.
enum ThematicAnalysisCache {
    private struct Line: Encodable {
        let start: Double
        let end: Double
        let text: String
    }

    static func fingerprint(of transcript: Transcript) -> String? {
        guard !transcript.segments.isEmpty else { return nil }
        let lines = transcript.segments.map { Line(start: $0.start, end: $0.end, text: $0.text) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(lines) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func binding(_ analysis: ThematicAnalysisResult, to transcript: Transcript) -> ThematicAnalysisResult {
        var copy = analysis
        copy.sourceTranscriptFingerprint = fingerprint(of: transcript)
        return copy
    }

    static func isReusable(_ analysis: ThematicAnalysisResult, transcript: Transcript) -> Bool {
        guard hasMatchingSource(analysis, transcript: transcript),
              let proof = analysis.semanticProof,
              let hook = analysis.essayPlan?.selectedHook, hook.source == .llm,
              hook.text == proof.hook, analysis.essayPlan?.hookReason == proof.hookReason,
              EssaySemanticSelection.evidenceIsValid(proof, analysis: analysis, transcript: transcript) else { return false }
        return true
    }

    /// Только привязка к исходнику: позволяет прочитать прежний экспорт, но не
    /// выдаёт старую тему/список хуков за новый автоматический выбор модели.
    static func hasMatchingSource(_ analysis: ThematicAnalysisResult, transcript: Transcript) -> Bool {
        guard analysis.source == .llm, analysis.replyCompleteness.isAcceptable,
              let saved = analysis.sourceTranscriptFingerprint,
              let current = fingerprint(of: transcript), saved == current else { return false }
        if case .rejected = DirectorArtifactGate.concept(analysis.primaryConcept) { return false }
        return (try? EssaySceneEvidence.validate(analysis, transcript: transcript)) != nil
    }
}
