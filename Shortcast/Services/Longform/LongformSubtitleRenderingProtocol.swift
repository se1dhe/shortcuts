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
    /// Включает фирменную кино-типографику Shortcast:
    /// - якорное слово темы по центру кадра (кегль 44pt при 1080 строках, авто-усадка до 60% ширины),
    /// - синхронные реплики строго под ним (32pt, акцент не ниже WCAG AA 4.5:1 против кадра),
    /// - вступительный слоган под субтитрами и карточки актов.
    /// Плашки, рамки и фоны под текстом запрещены — только обводка и кино-тень.
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct],
        actStartTimes: [Double],
        totalDuration: Double
    ) async -> CALayer

    /// Генерирует статический кадр для SwiftUI превью в фирменном стиле Shortcast.
    /// Обязан использовать те же помощники типографики, что и `makeOverlayLayer`
    /// (единый масштаб k = renderSize.height / 1080), иначе превью молча разойдется с видео.
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
