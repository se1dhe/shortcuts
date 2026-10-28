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

/// Геометрия полос поверх кадра: нижний летбокс и знак канала.
///
/// Поля — только доля/пиксели уже посчитанного `renderSize`: абсолютных констант здесь нет,
/// поэтому раскладка переживает любой размер кадра (1280x720, 1920x1080, 3840x2160).
struct LongformOverlayLayout: Sendable, Equatable {
    /// Высота нижней чёрной полосы летбокса в пикселях `renderSize` (0 — когда кадра не было).
    /// Значение приходит из `LongformPipelineCoordinator`, где считается посадка кадра,
    /// а не из догадки: знак отступает от фактической полосы, иначе он ляжет на летбокс.
    var bottomBarHeight: CGFloat = 0
    /// `nil` — знак канала не прожигается. По умолчанию включён в режиме эссе.
    var channelLogo: ChannelLogoStyle? = .essay
}

/// Протокол отрисовщика брендовых титров и кинематографических оверлеев Shortcast для длинных роликов (SOLID: ISP/DIP)
protocol LongformSubtitleRenderingProtocol: Sendable {
    /// Создает анимированный оверлейный CALayer для AVVideoCompositionCoreAnimationTool.
    /// Включает фирменную кино-типографику Shortcast:
    /// - якорное слово темы по центру кадра (кегль 44pt при 1080 строках, авто-усадка до 60% ширины),
    /// - синхронные реплики строго под ним (32pt, акцент не ниже WCAG AA 4.5:1 против кадра),
    /// - вступительный слоган или хук под субтитрами.
    /// - Плашки, рамки и фоны под текстом запрещены — только обводка и кино-тень.
    /// - Порядок подслоёв корня зафиксирован: `[0]` слово темы, `[1]` субтитры, `[2]` слоган/хук,
    ///   `[3]` финальный CTA (только если `ctaText` задан), `[4]` постоянный знак канала — последним.
    /// - Карточки актов на видео не выводятся: акты видны в результате и таймкодах, не на экране.
    /// - `layout.channelLogo == nil` — знак канала не создаётся вовсе.
    /// - `hookText` заменяет слоган на вступительной карточке и держит субтитры скрытыми до 9.2 с;
    ///   nil — прежнее поведение (слоган до 4.2 с, субтитры с 4.5 с).
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        totalDuration: Double,
        layout: LongformOverlayLayout,
        hookText: String?,
        ctaText: String?
    ) async -> CALayer

    /// Генерирует статический кадр для SwiftUI превью в фирменном стиле Shortcast.
    /// Обязан использовать те же помощники типографики, что и `makeOverlayLayer`
    /// (единый масштаб k = renderSize.height / 1080), иначе превью молча разойдется с видео.
    /// Вотермарк-знак постоянный, а не таймированный: превью обязано показать его там же,
    /// где он окажется на видео.
    func renderPreviewImage(
        renderSize: CGSize,
        concept: ThematicConcept,
        currentPhrase: String?,
        layout: LongformOverlayLayout
    ) -> CGImage?
}

extension LongformSubtitleRenderingProtocol {
    /// Старый вызов без хука/CTA: сохраняет прежнюю вступительную карточку и слой-состав.
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        totalDuration: Double,
        layout: LongformOverlayLayout
    ) async -> CALayer {
        await makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            totalDuration: totalDuration,
            layout: layout,
            hookText: nil,
            ctaText: nil
        )
    }

    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        totalDuration: Double
    ) async -> CALayer {
        await makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            totalDuration: totalDuration,
            layout: LongformOverlayLayout(),
            hookText: nil,
            ctaText: nil
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
            totalDuration: timedPhrases.last?.end ?? 300.0,
            layout: LongformOverlayLayout(),
            hookText: nil,
            ctaText: nil
        )
    }

    /// Превью с той же раскладкой полос, что и видео; без аргумента — дефолтная раскладка эссе.
    func renderPreviewImage(
        renderSize: CGSize,
        concept: ThematicConcept,
        currentPhrase: String?
    ) -> CGImage? {
        renderPreviewImage(
            renderSize: renderSize,
            concept: concept,
            currentPhrase: currentPhrase,
            layout: LongformOverlayLayout()
        )
    }
}
