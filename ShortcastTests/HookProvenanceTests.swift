import Testing
import Foundation
@testable import Shortcast

/// Провенанс того, что выходит на экран: хук и призыв. Молчаливый
/// `hookVariants.first` больше не притворяется «выбором ИИ» — либо авторство
/// записано, либо его выбрал человек, либо на экране этого текста не будет.
@Suite("Hook and CTA provenance")
struct HookProvenanceTests {

    private func transcript() -> Transcript {
        Transcript(
            segments: stride(from: 0.0, to: 2400.0, by: 10.0).map { start in
                TranscriptSegment(start: start, end: start + 9.0, text: "Репліка \(Int(start)) про вибір.")
            },
            language: "uk"
        )
    }

    private var concept: ThematicConcept {
        ThematicConcept(
            word: "ВИБІР", tagline: "т", philosophicalPremise: "п",
            suggestedTitle: "з", accentColorHex: "#FFFFFF"
        )
    }

    private func moments() -> [SelectedMoment] {
        let rows: [(Double, Double, LongformActType, Bool)] = [
            (200, 230, .hook, true), (400, 430, .form, false),
            (900, 930, .psychology, false), (1400, 1430, .philosophy, false),
            (1900, 1930, .catharsis, true)
        ]
        return rows.map { row in
            SelectedMoment(
                startTime: row.0, endTime: row.1, reason: "Сцена",
                dramaticWeight: row.3 ? 0.95 : 0.5,
                actRole: row.2, supports: nil, featured: row.3)
        }
    }

    private func essay(for plan: EssayPlan?) async throws -> LongformNarrativeArc {
        try await LongformNarrativeDirector().buildArc(
            from: transcript(),
            concept: concept,
            selectedMoments: moments(),
            movieTitle: "Тест",
            targetDuration: 480,
            essayPlan: plan
        )
    }

    /// Так выглядел старый путь: план без провенанса, первый вариант брался
    /// молча и публиковался как текст Director.
    @Test("a hook with unrecorded authorship never reaches the screen")
    func unsourcedHookStaysOffScreen() async throws {
        let plan = EssayPlan(
            hookVariants: [.init(text: "Перший варіант, який ми не просили обирати.")],
            ctaVariants: [.init(text: "Підпишися.")],
            targetDuration: 480
        )
        #expect(plan.chosenHookVariant == nil)
        let arc = try await essay(for: plan)
        #expect(arc.hookText == nil, "без провенанса хук выдан за выбор модели")
        #expect(arc.ctaText == nil, "без провенанса призыв выдан за выбор модели")
    }

    @Test("a hook the model printed keeps its provenance onto the arc")
    func modelPrintedHookIsPublished() async throws {
        let plan = EssayPlan(
            hookVariants: [.init(text: "Ти контролюєш усе, крім себе.", source: .llm)],
            selectedHook: .init(text: "Ти контролюєш усе, крім себе.", source: .llm),
            ctaVariants: [.init(text: "Напиши, що обираєш ти.", source: .llm)],
            targetDuration: 480
        )
        let arc = try await essay(for: plan)
        #expect(arc.hookText == "Ти контролюєш усе, крім себе.")
        #expect(arc.ctaText == "Напиши, що обираєш ти.")
    }

    /// Выбор человека честен без `.llm`: человек и есть автор показа.
    @Test("a hook chosen by the user is published as chosen by the user")
    func userChosenHookKeepsManualProvenance() async throws {
        let generated = EssayPlan(
            hookVariants: [.init(text: "Варіант моделі.", source: .llm)],
            targetDuration: 480
        )
        let chosen = generated.confirming(hookText: "Мій хук.", ctaText: nil)
        #expect(chosen.selectedHook?.source == .manual)
        let arc = try await essay(for: chosen)
        #expect(arc.hookText == "Мій хук.")

        // Тот же план, но человек просто подтвердил показанный вариант модели.
        let accepted = generated.confirming(hookText: nil, ctaText: nil)
        let acceptedArc = try await essay(for: accepted)
        #expect(acceptedArc.hookText == nil, "подтверждение плана не выбирает первый вариант за модель")
    }

    @Test("empty and oversized screen texts are refused")
    func gateRefusesUnusableText() {
        let blank = EssayPlan.TextVariant(text: "   ", source: .llm)
        if case .rejected(_, let code) = DirectorArtifactGate.screenText(
            blank, chosenByUser: false, label: "хук") {
            #expect(code == .empty)
        } else {
            Issue.record("пустой хук принят")
        }

        let long = EssayPlan.TextVariant(text: String(repeating: "а", count: 241), source: .llm)
        if case .rejected(_, let code) = DirectorArtifactGate.screenText(
            long, chosenByUser: false, label: "хук") {
            #expect(code == .tooLong)
        } else {
            Issue.record("нечитаемый по длине текст принят")
        }
    }

    /// Провенанс доезжает до архива: без поля `source` в JSON вариант не становится
    /// «выбором ИИ» при чтении старого проекта.
    @Test("stored plans without provenance decode as untrusted")
    func decodingWithoutProvenance() throws {
        let json = Data("""
        {"thesis":"Т","hookVariants":[{"text":"Х"}],"ctaVariants":[]}
        """.utf8)
        let plan = try JSONDecoder().decode(EssayPlan.self, from: json)
        #expect(plan.hookVariants.first?.source == .unknown)
        #expect(plan.hookVariants.first?.source.isTrustworthy == false)
    }
}
