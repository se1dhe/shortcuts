import AppKit
import CoreGraphics
import QuartzCore
import os

/// Единая точка доступа к логотипу канала: геометрия, слой для оверлея и композит для обложек.
///
/// Ассет `ChannelLogo` — PNG с альфой, полученной из яркости оригинала (золото на чёрном),
/// поэтому прожжённый знак читается и на светлом, и на тёмном кадре без подложки.
/// Если ассета нет — не рисуем ничего: синтетический значок был бы подделкой бренда.
enum ChannelLogo {
    static let assetName = "ChannelLogo"

    private static let logger = Logger(subsystem: "app.shortcast", category: "ChannelLogo")
    nonisolated(unsafe) private static var cachedImage: CGImage?
    nonisolated(unsafe) private static var loadAttempted = false

    /// Растр эмблемы в sRGB. Кэшируется: оверлей строится один раз на рендер, обложек — несколько.
    static var image: CGImage? {
        if loadAttempted { return cachedImage }
        loadAttempted = true
        let loaded = NSImage(named: assetName).flatMap { image in
            var rect = NSRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        if loaded == nil {
            logger.notice("logo asset '\(assetName, privacy: .public)' is missing — drawing nothing")
        }
        cachedImage = loaded
        return loaded
    }

    static var isAvailable: Bool { image != nil }

    /// Слой для `AVVideoCompositionCoreAnimationTool`: все прожжённые элементы в проекте — растр в `contents`.
    static func makeLayer(frame: CGRect, renderSize: CGSize, opacity: Double) -> CALayer? {
        guard let image else { return nil }
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = max(1.0, renderSize.height / 540.0)
        layer.opacity = Float(opacity)
        return layer
    }

    /// Композит для обложек, которые рисуются в `CGContext` от начала до конца.
    /// На обложке знак полноцветный и непрозрачный: это не накладка поверх чужой картинки.
    static func composite(in ctx: CGContext, rect: CGRect, opacity: CGFloat = 1.0) {
        guard let image else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.setAlpha(opacity)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}

struct ChannelLogoStyle: Sendable, Equatable {
    /// Доля высоты кадра: 119 px при 1080 и 211 px при вертикальных 1920.
    var sizeFraction: CGFloat = 0.11
    /// Почти прозрачный знак: он угадывается, но не перетягивает взгляд с кадра.
    var opacity: Double = 0.12
    /// Отступ от нижней границы субтитров до верха знака, в единицах `k`.
    var gapBelowSubtitles: CGFloat = 24
    /// Отступ от края кадра / от верхней полосы леттбокса, в единицах `k`.
    var edgeInset: CGFloat = 12
    /// Ниже этой доли высоты знак не сжимаем — лучше пропустить, чем делать грязное пятно.
    var minSizeFraction: CGFloat = 0.06

    static let essay = ChannelLogoStyle(opacity: 0.12)
    static let shorts = ChannelLogoStyle(opacity: 0.22)
}

/// Чистая геометрия без CoreAnimation — чтобы коллизии с субтитрами и полосами проверялись тестом.
/// Все координаты bottom-left origin, как у слоёв оверлея (`isGeometryFlipped == false`).
enum ChannelLogoPlacement {
    /// Эссе: по центру у самого низа кадра, над нижней чёрной полосой леттбокса.
    /// Субтитры живут под словом темы в середине, поэтому знак к ним не поднимается;
    /// если места до них всё же нет — ужимается, а ниже пола не рисуется вовсе.
    static func essay(renderSize: CGSize, subtitleBottom: CGFloat, bottomBarHeight: CGFloat,
                      style: ChannelLogoStyle = .essay) -> CGRect? {
        let height = renderSize.height
        let k = height / 1080.0
        let nominal = style.sizeFraction * height
        let gap = style.gapBelowSubtitles * k
        let floorY = bottomBarHeight + style.edgeInset * k
        let ceilingY = subtitleBottom - gap
        guard ceilingY > floorY else { return nil }

        let side = min(nominal, ceilingY - floorY)
        guard side >= style.minSizeFraction * height else { return nil }
        return square(width: side, in: renderSize, y: floorY)
    }

    /// Шортсы: нижний левый угол. Правый угол занят рельсом действий платформы, центр — текстовым вотермарком.
    static func short(renderSize: CGSize, subtitleSnapRects: [CGRect],
                      style: ChannelLogoStyle = .shorts) -> CGRect? {
        let width = renderSize.width
        let height = renderSize.height
        let nominal = style.sizeFraction * height
        let inset = max(16, width * 0.02)
        let gap = 0.012 * height

        let column = CGRect(x: inset - gap, y: 0, width: nominal + gap, height: height)
        let subBottom = subtitleSnapRects
            .filter { $0.intersects(column) }
            .map(\.minY)
            .min() ?? height * 0.12
        let band = subBottom - gap - inset

        if band >= nominal {
            return CGRect(x: inset, y: inset, width: nominal, height: nominal)
        }
        guard band >= 0.07 * height else { return nil }
        return CGRect(x: inset, y: inset, width: band, height: band)
    }

    /// Обложка эссе: правый верх — единственная полоса, которая не воюет ни с одним текстовым слотом
    /// ни в одном из режимов раскладки.
    static func essayCover(canvas: CGSize, inset: CGFloat = 48) -> CGRect {
        let side = 0.11 * canvas.height
        return CGRect(x: canvas.width - side - inset, y: canvas.height - side - inset,
                      width: side, height: side)
    }

    /// Обложка шортса 9:16: левый верх — снизу и справа интерфейс YouTube Shorts.
    static func shortCover(canvas: CGSize) -> CGRect {
        let side = 0.11 * canvas.height
        let inset = 0.05 * canvas.width
        return CGRect(x: inset, y: canvas.height - side - inset, width: side, height: side)
    }

    private static func square(width side: CGFloat, in canvas: CGSize, y: CGFloat) -> CGRect {
        CGRect(x: (canvas.width - side) / 2, y: y, width: side, height: side)
    }
}
