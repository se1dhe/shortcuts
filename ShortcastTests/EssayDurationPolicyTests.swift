import Testing
import Foundation
@testable import Shortcast

/// Коридор 4:00–8:00: длина не запрашивается, она выводится из пула сцен модели.
/// Эти тесты закрепляют арифметику коридора и цифры контракта в промптах —
/// чтобы промпт и монтаж не разъехались, как это случилось с «8–15 хвилин».
@Suite("EssayDurationPolicy")
struct EssayDurationPolicyTests {

    @Test("any request is clamped into the corridor")
    func clampsIntoCorridor() {
        #expect(EssayDurationPolicy.clamp(660) == 480)     // старый проект просил 11 минут
        #expect(EssayDurationPolicy.clamp(120) == 240)     // меньше четырёх не бывает
        #expect(EssayDurationPolicy.clamp(300) == 300)
        #expect(EssayDurationPolicy.clamp(0) == 240)
        #expect(EssayDurationPolicy.clamp(100_000) == 480)
    }

    /// Тема с бедным пулом даёт нижнюю границу, тема с богатым — верхнюю: это и
    /// есть «длина рождается из темы», а не из переключателя.
    @Test("rendered target grows with the scene pool and stays inside the corridor")
    func targetEmergesFromPool() {
        let poorest = Double(EssayDurationPolicy.pool.lowerBound)
            * EssayDurationPolicy.sceneLength.lowerBound     // 14 × 18 = 252
        let richest = Double(EssayDurationPolicy.pool.upperBound)
            * EssayDurationPolicy.sceneLength.upperBound     // 22 × 40 = 880
        let middle = EssayDurationPolicy.renderedTarget(poolSeconds: 450)

        #expect(middle > EssayDurationPolicy.renderedTarget(poolSeconds: poorest))
        #expect(middle < EssayDurationPolicy.renderedTarget(poolSeconds: richest))
        for pool in [0.0, poorest, 300, 450, 590, richest, 5_000] {
            let target = EssayDurationPolicy.renderedTarget(poolSeconds: pool)
            #expect(EssayDurationPolicy.rendered.contains(target),
                    "пул \(pool)с дал цель \(target)с вне коридора")
        }
        // Даже минимальный честный пул перекрывает нижнюю границу коридора.
        #expect(EssayDurationPolicy.renderedTarget(poolSeconds: poorest)
                >= EssayDurationPolicy.rendered.lowerBound)
    }

    @Test("content budget subtracts fixed padding and intra-act gaps")
    func contentBudgetArithmetic() {
        let scenes = 18
        let budget = EssayDurationPolicy.contentBudget(renderedTarget: 480, scenes: scenes)
        #expect(budget == 480 - EssayDurationPolicy.fixedPadding
                        - Double(scenes - 1) * EssayDurationPolicy.intraActGap)
        // Цель клампится до чтения: просьба про 11 минут не расширяет бюджет.
        #expect(EssayDurationPolicy.contentBudget(renderedTarget: 660, scenes: scenes)
                == EssayDurationPolicy.contentBudget(renderedTarget: 480, scenes: scenes))
        #expect(EssayDurationPolicy.contentBudget(renderedTarget: 240, scenes: 1) == 240 - EssayDurationPolicy.fixedPadding)
        // Просьба ниже коридора всё равно читается как коридор: бюджет не обнуляется.
        #expect(EssayDurationPolicy.contentBudget(renderedTarget: 0, scenes: 5)
                == EssayDurationPolicy.contentBudget(renderedTarget: 240, scenes: 5))
    }

    @Test("the corridor is exactly four to eight minutes")
    func corridorIsFourToEight() {
        #expect(EssayDurationPolicy.rendered == 240...480)
        #expect(EssayDurationPolicy.sceneLength == 18...40)
        #expect(EssayDurationPolicy.pool == 14...22)
        #expect(EssayDurationPolicy.rendered.contains(EssayDurationPolicy.defaultRenderedTarget))
        #expect(EssayDurationPolicy.format(463) == "7:43")
        #expect(EssayDurationPolicy.format(298) == "4:58")
    }

    /// Промпт и политика обязаны требовать одно и то же: раньше КРОК 1 просил
    /// «3-5 сцен», а КРОК 5 — 16-24, и модель выбирала, чему верить.
    @Test("prompts ask for the pool the pipeline can actually mount")
    func promptsMatchThePolicy() {
        let stage2 = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")
        let stage1 = DirectorStagedAnalysis.candidatesInstructions(movieTitle: "Фільм")
        for prompt in [stage2, stage1] {
            #expect(!prompt.contains("16-24"), "промпт всё ещё просит старый пул")
            #expect(!prompt.contains("720-900"), "промпт просит пул длиной в 12 минут")
            #expect(!prompt.contains("8–15"), "промпт обещает зрителю 8–15 хвилин")
            #expect(!prompt.contains("8-15"), "промпт обещает зрителю 8-15 хвилин")
        }
        #expect(stage2.contains("14-22"))
        #expect(stage2.contains("18-40"))
        #expect(stage2.contains("310-590"))
        #expect(stage2.contains("4-8"))
        #expect(stage1.contains("П'ЯТЬ"))
        #expect(DirectorStagedAnalysis.stage1MaxTokens < DirectorStagedAnalysis.stage2MaxTokens)
    }

    /// Модель больше не спрашивают про хронометраж: если в промпте появится
    /// «цель N секунд», длина снова станет нашей выдумкой, а не свойством темы.
    @Test("the model is never asked for a target runtime")
    func noRuntimeIsRequestedFromTheModel() {
        let stage2 = LongformThematicService.thematicSystemPrompt(movieTitle: "Фільм")
        let stage1 = DirectorStagedAnalysis.candidatesInstructions(movieTitle: "Фільм")
        let focus = DirectorStagedAnalysis.stage2Focus(winner: "СВОБОДА", runnersUp: ["ОБМАН"])
        for text in [stage2, stage1, focus] {
            #expect(!text.lowercased().contains("targetduration"),
                    "промпт просит модель задать хронометраж")
            #expect(!text.contains("цільовий хронометраж"),
                    "промпт просит модель задать хронометраж")
        }
    }
}
