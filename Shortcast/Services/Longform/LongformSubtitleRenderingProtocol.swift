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
    /// - вступительный слоган под субтитрами и карточки актов.
    /// - Плашки, рамки и фоны под текстом запрещены — только обводка и кино-тень.
    /// - Порядок подслоёв корня зафиксирован: `[0]` слово темы, `[1]` субтитры, `[2]` слоган,
    ///   `[3]` карточки актов, `[4]` знак канала. Знак добавляется строго в конец списка:
    ///   вставлять его в середину нельзя — тесты читают `sublayers` по индексам, а у слоя-картинки
    ///   ненулевой `contents`, и проверка «никаких плашек» посчитала бы его плашкой.
    /// - `layout.channelLogo == nil` — пятая полоса не создаётся вовсе (4 подслоя, как раньше).
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct],
        actStartTimes: [Double],
        totalDuration: Double,
        layout: LongformOverlayLayout
    ) async -> CALayer

    /// Генерирует статический кадр для SwiftUI превью в фирменном стиле Shortcast.
    /// Обязан использовать те же помощники типографики, что и `makeOverlayLayer`
    /// (единый масштаб k = renderSize.height / 1080), иначе превью молча разойдется с видео.
    /// Знак канала рисуется тем же вызовом `ChannelLogoPlacement.essay`, что и в видео.
    func renderPreviewImage(
        renderSize: CGSize,
        concept: ThematicConcept,
        currentPhrase: String?,
        layout: LongformOverlayLayout
    ) -> CGImage?
}

extension LongformSubtitleRenderingProtocol {
    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct],
        actStartTimes: [Double],
        totalDuration: Double
    ) async -> CALayer {
        await makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            acts: acts,
            actStartTimes: actStartTimes,
            totalDuration: totalDuration,
            layout: LongformOverlayLayout()
        )
    }

    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct],
        totalDuration: Double,
        layout: LongformOverlayLayout
    ) async -> CALayer {
        await makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            acts: acts,
            actStartTimes: [],
            totalDuration: totalDuration,
            layout: layout
        )
    }

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
            totalDuration: totalDuration,
            layout: LongformOverlayLayout()
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
            totalDuration: timedPhrases.last?.end ?? 300.0
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
