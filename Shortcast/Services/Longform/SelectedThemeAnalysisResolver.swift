import Foundation

/// Один путь выбора плана для preview и render. Пул другой темы и старый кэш
/// без проверяемых цитат никогда не становятся планом выбранного эссе.
@MainActor
enum SelectedThemeAnalysisResolver {
    static func matches(_ analysis: ThematicAnalysisResult, selection: ThematicConcept) -> Bool {
        let identities = [analysis.primaryConcept, analysis.plannedConcept].compactMap { $0 }
        return identities.contains {
            key($0.word) == key(selection.word)
                && key($0.philosophicalPremise) == key(selection.philosophicalPremise)
        }
    }

    static func resolve(
        selection: ThematicConcept,
        cached: ThematicAnalysisResult?,
        transcript: Transcript,
        userPlan: EssayPlan?,
        replan: () async throws -> ThematicAnalysisResult
    ) async throws -> ThematicAnalysisResult {
        let reusable = cached.map {
            matches($0, selection: selection)
                && ThematicAnalysisCache.isReusable($0, transcript: transcript)
        } ?? false
        var analysis: ThematicAnalysisResult
        if reusable, let cached {
            analysis = cached
        } else {
            analysis = try await replan()
            let sameSelection = key(analysis.primaryConcept.word) == key(selection.word)
            let semanticallyApprovedReplacement: Bool
            if let proof = analysis.semanticProof {
                semanticallyApprovedReplacement = selection.source == .llm
                    && analysis.primaryConcept.source == .llm
                    && key(proof.theme) == key(analysis.primaryConcept.word)
                    && EssaySemanticSelection.evidenceIsValid(
                        proof, analysis: analysis, transcript: transcript)
            } else {
                semanticallyApprovedReplacement = false
            }
            guard sameSelection || semanticallyApprovedReplacement else {
                throw ThematicDiscoveryError.noGroundedTheme("Director построил план другой темы")
            }
        }
        // Хук всегда берётся из актуального решения модели. Старый ручной выбор
        // или номер варианта не переносится через повторный анализ темы.
        if let cta = userPlan?.selectedCTA, cta.source == .manual, var plan = analysis.essayPlan {
            plan = plan.confirming(hookText: nil, ctaText: cta.text)
            analysis.essayPlan = plan
        }

        try Task.checkCancellation()
        try EssaySceneEvidence.validate(analysis, transcript: transcript)
        if analysis.plannedConcept == nil { analysis.plannedConcept = selection }
        // Ручной выбор слова не приписывается модели; упаковка и сцены Stage 2
        // при этом действительно сгенерированы ею.
        if selection.source == .manual { analysis.primaryConcept.source = .manual }
        if !selection.suggestedTitle.trimmed.isEmpty, selection.source == .manual {
            analysis.primaryConcept.suggestedTitle = selection.suggestedTitle
        }
        return ThematicAnalysisCache.binding(analysis, to: transcript)
    }

    private static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
