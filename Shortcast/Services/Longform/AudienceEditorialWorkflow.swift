import Foundation

enum AudienceEditorialWorkflow {
    /// A second local model is a bounded fallback, not an excuse to relax the
    /// source gates or regenerate an already accepted montage.
    @MainActor
    static func prepare(_ arc: LongformNarrativeArc, transcript: Transcript, manager: ModelManager,
                        preferred: ChatModelProfile, feedback: String? = nil) async throws -> LongformNarrativeArc {
        let profiles: [ChatModelProfile] = preferred.modelID == ChatModelProfile.gemma12B.modelID
            ? [preferred, .qwen35_9b] : [preferred]
        var lastError: (any Error)?
        for profile in profiles {
            try Task.checkCancellation()
            do {
                try await manager.requireDirector(profile: profile)
                let finder = manager.momentFinder
                let gateway = DirectorChatGateway(readiness: { await finder.isReady }, identifier: { profile.modelID },
                    completion: { instructions, prompt, tokens in
                        await finder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: tokens)
                    })
                return try await AudienceEditorialService(model: gateway).apply(to: arc, transcript: transcript, feedback: feedback)
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                OperationJournal.shared.append("Редактура \(profile.displayName) не принята: " + error.localizedDescription, level: .warning)
                if profiles.count > 1 && profile.modelID == profiles[0].modelID {
                    OperationJournal.shared.append("Сцены сохранены. Проверяю авторский текст с Qwen 3.5 9B; при первом запуске модель будет загружена.")
                }
            }
        }
        throw lastError ?? EssayReleaseError.invalid("Редактор недоступен; сцены сохранены.")
    }
}
