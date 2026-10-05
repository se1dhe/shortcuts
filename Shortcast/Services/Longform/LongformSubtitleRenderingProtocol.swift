import AppKit
import AVFoundation
import CoreGraphics

/// Модель таймированной реплики субтитра для длинного ролика
struct TimedSubtitlePhrase: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String

    init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Протокол отрисовщика брендовых титров и кинематографических оверлеев Shortcast для длинных роликов (SOLID: ISP/DIP)
protocol LongformSubtitleRenderingProtocol: Sendable {
    /// Создает анимированный оверлейный CALayer для AVVideoCompositionCoreAnimationTool.
    /// Включает кинетическую пословную типографику Shortcast (1-2 слова, micro-punch),
    /// кинематографическую вступительную титульную карточку (Intro Title Card)
    /// и маркеры актов (Act Chapter Cards).
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct],
        actStartTimes: [Double],
        totalDuration: Double
    ) async -> CALayer

    /// Генерирует статический кадр для SwiftUI превью в фирменном стиле Shortcast
    func renderPreviewImage(
        renderSize: CGSize,
        concept: ThematicConcept,
        currentPhrase: String?
    ) -> CGImage?
}

extension LongformSubtitleRenderingProtocol {
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct],
        totalDuration: Double
    ) async -> CALayer {
        await makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            acts: acts,
            actStartTimes: [],
            totalDuration: totalDuration
        )
    }

    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase]
    ) async -> CALayer {
        await makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            acts: [],
            actStartTimes: [],
            totalDuration: timedPhrases.last?.end ?? 300.0
        )
    }
}
