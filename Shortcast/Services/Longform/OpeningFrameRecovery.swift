import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

enum OpeningFrameRecovery {
    struct Hold: Sendable {
        let image: CGImage
        let duration: Double
    }

    static func isBlack(_ image: CGImage) -> Bool {
        let width = 80, height = 48
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var visible = 0, sampled = 0
        for y in (height / 4)..<(3 * height / 4) {
            for x in (width / 10)..<(9 * width / 10) {
                let index = (y * width + x) * 4
                if max(bytes[index], bytes[index + 1], bytes[index + 2]) > 8 { visible += 1 }
                sampled += 1
            }
        }
        return Double(visible) / Double(sampled) < 0.005
    }

    /// Replace only a verified leading blackout, never trim dialogue or borrow
    /// a shot from another scene. The moving picture rejoins the same frame.
    static func prepare(asset: AVAsset, scene: TimeSegment) async throws -> Hold? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
        let initial = try await generator.image(at: CMTime(seconds: scene.start, preferredTimescale: 600)).image
        guard isBlack(initial) else { return nil }
        for offset in stride(from: 0.25, through: min(6, scene.duration - 1), by: 0.25) {
            try Task.checkCancellation()
            let time = CMTime(seconds: scene.start + offset, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            if !isBlack(frame) {
                // The first non-black sample can be the barely visible first
                // frame of a source fade-in. Rejoin after that short fade so
                // the held picture is actually readable from output frame 0.
                let settled = min(offset + 0.75, scene.duration - 0.1)
                generator.maximumSize = .zero
                let full = try await generator.image(at: CMTime(seconds: scene.start + settled, preferredTimescale: 600)).image
                return Hold(image: full, duration: settled)
            }
        }
        throw EssayReleaseError.invalid("Первые шесть секунд выбранного хука — чёрный экран. Сцены сохранены; выберите другой вход в хук.")
    }

    static func layer(for hold: Hold, size: CGSize, totalDuration: Double) -> CALayer {
        let layer = CALayer(); layer.name = "opening-same-scene-frame"
        layer.frame = CGRect(origin: .zero, size: size)
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.contents = hold.image; layer.contentsGravity = .resizeAspect
        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, 0, 0]
        animation.keyTimes = [0, hold.duration / totalDuration, (hold.duration + 0.1) / totalDuration, 1].map { NSNumber(value: $0) }
        animation.duration = totalDuration; animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.fillMode = .both; animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "leading-blackout-recovery")
        return layer
    }
}
