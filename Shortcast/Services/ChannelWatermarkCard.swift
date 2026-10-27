import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore
import os

/// Вотермарк-карточка канала для кино-эссе: не постоянная плашка, а три коротких
/// стинга — после первой минуты, в середине и за минуту до финала.
///
/// Ассет `ChannelWatermarkCard` — квадратная карточка «КАДР & СЕНС» с альфой.
/// Если ассета нет — не рисуем ничего: самодельная замена была бы подделкой бренда.
enum ChannelWatermarkCard {
    static let assetName = "ChannelWatermarkCard"

    /// Первый стинг: «после минуты», но не позже четверти короткого эссе.
    static let leadIn: Double = 60.0
    /// Последний стинг: «за минуту до конца», но не позже 85% короткого эссе.
    static let tailOut: Double = 60.0
    /// Ближе этого стинги не ставим: два появления подряд выглядят как сбой.
    static let minimumGap: Double = 12.0

    private static let logger = Logger(subsystem: "app.shortcast", category: "ChannelWatermarkCard")
    nonisolated(unsafe) private static var cachedImage: CGImage?
    nonisolated(unsafe) private static var loadAttempted = false

    /// Растр карточки в sRGB. Кэшируется: оверлей строится один раз на рендер.
    static var image: CGImage? {
        if loadAttempted { return cachedImage }
        loadAttempted = true
        let loaded = NSImage(named: assetName).flatMap { image in
            var rect = NSRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        if loaded == nil {
            logger.notice("watermark card asset '\(assetName, privacy: .public)' is missing — drawing nothing")
        }
        cachedImage = loaded
        return loaded
    }

    static var isAvailable: Bool { image != nil }

    /// Правый верх: единственная зона, которая не спорит с темой по центру,
    /// субтитрами под ней и финальным CTA в нижней трети.
    static func placement(
        renderSize: CGSize,
        style: ChannelWatermarkStingStyle = .essay
    ) -> CGRect {
        let k = renderSize.height / 1080.0
        let side = style.sizeFraction * renderSize.height
        let inset = style.edgeInset * k
        return CGRect(
            x: renderSize.width - side - inset,
            y: renderSize.height - side - inset,
            width: side,
            height: side
        )
    }

    /// Три момента показа: [~1:00, середина, ~конец минус 1:00]. На коротком
    /// ролике окна сжимаются к четверти, середине и 85%, но всё ещё не слипаются.
    static func stingTimes(
        totalDuration: Double,
        style: ChannelWatermarkStingStyle = .essay
    ) -> [Double] {
        guard totalDuration > style.duration * 2 else { return [] }
        let candidates = [
            min(leadIn, totalDuration * 0.25),
            totalDuration / 2,
            max(totalDuration - tailOut, totalDuration * 0.85)
        ]
        var times: [Double] = []
        for time in candidates where time > 0 && time + style.duration < totalDuration {
            if let previous = times.last, time - previous < minimumGap { continue }
            times.append(time)
        }
        return times
    }

    /// Контейнер со всеми стингами: один корневой подслой поверх остальных полос.
    /// Каждая карточка появляется сама по своему абсолютному времени таймлайна.
    static func makeContainer(
        renderSize: CGSize,
        totalDuration: Double,
        style: ChannelWatermarkStingStyle = .essay
    ) -> CALayer? {
        guard let image else { return nil }
        let times = stingTimes(totalDuration: totalDuration, style: style)
        guard !times.isEmpty else { return nil }

        let k = renderSize.height / 1080.0
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.isGeometryFlipped = false

        let glow = NSColor(hex: "#E8C46A")?.cgColor
            ?? CGColor(srgbRed: 0.91, green: 0.77, blue: 0.42, alpha: 1.0)

        for time in times {
            let card = CALayer()
            card.frame = placement(renderSize: renderSize, style: style)
            card.contents = image
            card.contentsGravity = .resizeAspect
            card.contentsScale = max(1.0, renderSize.height / 540.0)
            card.opacity = 0
            card.shadowColor = glow
            card.shadowOpacity = 0
            card.shadowRadius = 26.0 * k
            card.shadowOffset = .zero

            card.add(
                animation(
                    keyPath: "opacity",
                    values: [0.0, style.opacity, style.opacity, 0.0],
                    keyTimes: [0.0, 0.12, 0.82, 1.0],
                    timingFunctions: [.easeOut, .linear, .easeIn],
                    style: style,
                    begin: time
                ),
                forKey: "watermarkStingOpacity"
            )
            card.add(
                animation(
                    keyPath: "transform",
                    values: [
                        NSValue(caTransform3D: CATransform3DScale(
                            CATransform3DMakeTranslation(0, -14.0 * k, 0), 0.82, 0.82, 1
                        )),
                        NSValue(caTransform3D: CATransform3DScale(
                            CATransform3DMakeTranslation(0, 4.0 * k, 0), 1.05, 1.05, 1
                        )),
                        NSValue(caTransform3D: CATransform3DMakeScale(1, 1, 1))
                    ],
                    keyTimes: [0.0, 0.55, 1.0],
                    timingFunctions: [.easeOut, .easeInEaseOut],
                    style: style,
                    begin: time
                ),
                forKey: "watermarkStingTransform"
            )
            card.add(
                animation(
                    keyPath: "shadowOpacity",
                    values: [0.0, 0.85, 0.45, 0.0],
                    keyTimes: [0.0, 0.14, 0.58, 1.0],
                    timingFunctions: [.easeOut, .easeInEaseOut, .easeIn],
                    style: style,
                    begin: time
                ),
                forKey: "watermarkStingGlow"
            )
            container.addSublayer(card)
        }
        return container
    }

    private static func animation(
        keyPath: String,
        values: [Any],
        keyTimes: [Double],
        timingFunctions: [CAMediaTimingFunctionName],
        style: ChannelWatermarkStingStyle,
        begin: Double
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        animation.timingFunctions = timingFunctions.map { CAMediaTimingFunction(name: $0) }
        animation.duration = style.duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }
}

struct ChannelWatermarkStingStyle: Sendable, Equatable {
    /// Доля высоты кадра: 302 px при 1080 — карточка читается, но не закрывает кадр.
    var sizeFraction: CGFloat = 0.28
    /// Отступ от правого и верхнего края в единицах `k` (1080 → 48 px).
    var edgeInset: CGFloat = 48
    /// Непрозрачность карточки на пике: она брендовая, но не должна спорить с кадром.
    var opacity: Double = 0.96
    /// Полная длина анимации: влёт, удержание и растворение.
    var duration: Double = 2.8

    static let essay = ChannelWatermarkStingStyle()
}
