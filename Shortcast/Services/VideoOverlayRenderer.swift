import AVFoundation
import AppKit
import QuartzCore

/// Burns a short text "hook" into the top of a clip for its first seconds, then
/// fades it out — the classic short-form overlay. Re-encodes via an
/// `AVVideoCompositionCoreAnimationTool`, so it's only run at publish time on
/// clips whose overlay is enabled.
enum VideoOverlayRenderer {

    /// Renders `clipURL` with `text` shown for `holdSeconds` (then a short fade).
    /// Returns a new temp `.mp4`. Throws `MediaExtractorError.clipExportFailed`.
    static func render(clipURL: URL, text: String?, holdSeconds: Double = 3, promoCode: String? = nil,
                       promoHoldSeconds: Double = 0,
                       appearance: HookAppearance = .default) async throws -> URL {
        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        // Build a composition with the video (+ audio if present).
        let composition = AVMutableComposition()
        // INSERT THE ENTIRE ASSET TO PRESERVE EXACT TIMING (EDTS / B-FRAMES)
        try await composition.insertTimeRange(full, of: asset, at: .zero)
        guard let compVideo = try await composition.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "AVFoundation", code: 1, userInfo: nil)
        }

        // Oriented render size, upscaled to a ≥1080 short side so burned-in overlays
        // stay sharp even on low-res / narrowly-cropped source clips.
        let oriented = naturalSize.applying(transform)
        let natural = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let (renderSize, upscale) = PromoOverlayRenderer.targetRenderSize(natural)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = full
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        let fillTransform = upscale > 1 ? transform.concatenating(CGAffineTransform(scaleX: upscale, y: upscale)) : transform
        layerInstruction.setTransform(fillTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Core Animation layer tree: video + the hook band on top.
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        let total = CMTimeGetSeconds(duration)
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let band = makeHookBand(text: text, renderSize: renderSize, hasPromo: promoCode != nil, appearance: appearance)
            addOpacityAnimation(to: band, total: total, hold: holdSeconds)
            addStyleAnimation(to: band, style: appearance.normalized.style, total: total)
            parentLayer.addSublayer(band)
        }
        if let promoCode, !promoCode.isEmpty {
            PromoOverlayRenderer.addBanner(to: parentLayer, promoCode: promoCode,
                                           renderSize: renderSize, total: total, holdSeconds: promoHoldSeconds)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-clip-hook-\(UUID().uuidString).mp4")
        try await HighBitrateExporter.export(
            asset: composition, videoComposition: videoComposition, to: outputURL)
        return outputURL
    }

    // MARK: - Layers

    /// A rounded pill near the top holding the wrapped, centered hook text.
    /// (Core Animation's video coordinate space has its origin at the bottom-left,
    /// so "top" is a high y.)
    /// Internal (not private) so `VerticalReframer` can reuse it when it burns the
    /// hook into the same export pass as the reframe.
    static func makeHookBand(text: String, renderSize: CGSize, hasPromo: Bool = false,
                             appearance: HookAppearance = .default) -> CALayer {
        let appearance = appearance.normalized
        let style = appearance.style
        let w = renderSize.width
        let fontSize = max(24, w * appearance.sizeScale * 1.8)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let padding = fontSize * 0.55
        let bandWidth = w * 0.88
        let innerWidth = bandWidth - padding * 2

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ]
        // Styles without a pill need a stroke so the text stays legible on video.
        if !style.showsPill {
            attributes[.strokeColor] = NSColor.black
            attributes[.strokeWidth] = -3.0
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textBounds = attributed.boundingRect(
            with: CGSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = ceil(textBounds.height)
        let bandHeight = textHeight + padding * 2

        let promoHeight = hasPromo ? renderSize.width * 0.35 : 0
        let topMargin = renderSize.height * 0.12 + promoHeight
        let bandY = renderSize.height - topMargin - bandHeight

        let band = CALayer()
        band.frame = CGRect(x: (w - bandWidth) / 2, y: bandY, width: bandWidth, height: bandHeight)
        if style.showsPill {
            band.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            band.cornerRadius = bandHeight * 0.28
            band.masksToBounds = true
        } else {
            band.backgroundColor = NSColor.clear.cgColor
            band.masksToBounds = false
        }

        // Render the (possibly multi-line) text to a bitmap and show it as the
        // layer's contents. CATextLayer mis-positions / clips wrapped text in
        // AVFoundation's offline render server (the band drew but a 2-line hook
        // overflowed it); a pre-rendered, vertically-centred image is exact and
        // orientation-safe, and renders identically on screen and in the export.
        let textLayer = CALayer()
        textLayer.frame = CGRect(x: padding, y: padding, width: innerWidth, height: textHeight)
        textLayer.contentsScale = 3
        textLayer.contentsGravity = .resize
        textLayer.contents = renderTextImage(
            attributed, size: CGSize(width: innerWidth, height: textHeight))
        // Neon: colored halo around the glyphs.
        if style == .neon {
            textLayer.shadowColor = (NSColor(hex: "#48B7FF") ?? .cyan).cgColor
            textLayer.shadowRadius = fontSize * 0.3
            textLayer.shadowOpacity = 1.0
            textLayer.shadowOffset = .zero
            textLayer.masksToBounds = false
        }
        band.addSublayer(textLayer)
        // Typewriter reveals the text with an animated mask (added by the caller
        // via addStyleAnimation, which needs the band's geometry set here).
        band.name = "hookBand"
        return band
    }

    /// Entrance animation for the hook band, per style. Opacity hold/fade is added
    /// separately by `addOpacityAnimation`.
    static func addStyleAnimation(to band: CALayer, style: HookAppearance.HookStyle, total: Double) {
        switch style {
        case .pop:
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.6, 1.15, 0.96, 1.0]
            scale.keyTimes = [0, 0.5, 0.78, 1]
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            scale.beginTime = AVCoreAnimationBeginTimeAtZero
            scale.duration = 0.4
            scale.fillMode = .both
            scale.isRemovedOnCompletion = false
            band.add(scale, forKey: "hookPop")
        case .typewriter:
            // Left-to-right reveal via an animated mask over the band.
            let mask = CALayer()
            mask.backgroundColor = NSColor.white.cgColor
            mask.anchorPoint = CGPoint(x: 0, y: 0.5)
            mask.position = CGPoint(x: 0, y: band.bounds.height / 2)
            mask.bounds = band.bounds
            band.mask = mask

            let reveal = CABasicAnimation(keyPath: "bounds.size.width")
            reveal.fromValue = 0
            reveal.toValue = band.bounds.width
            reveal.beginTime = AVCoreAnimationBeginTimeAtZero
            reveal.duration = min(1.2, max(0.4, total * 0.4))
            reveal.fillMode = .both
            reveal.isRemovedOnCompletion = false
            mask.add(reveal, forKey: "hookReveal")
        case .pill, .neon, .minimal:
            break
        }
    }

    /// Draws `text` vertically centred into a 3× bitmap for use as a CALayer's
    /// `contents`. Avoids CATextLayer's offline-render quirks (invisible / clipped
    /// wrapped text).
    private static func renderTextImage(_ text: NSAttributedString, size: CGSize) -> CGImage? {
        let scale: CGFloat = 3
        let pxW = max(1, Int(size.width * scale))
        let pxH = max(1, Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)
        let bounds = text.boundingRect(
            with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let y = max(0, (size.height - bounds.height) / 2)
        text.draw(with: CGRect(x: 0, y: y, width: size.width, height: ceil(bounds.height)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Visible from 0→hold, fades over 0.5s, then stays hidden.
    static func addOpacityAnimation(to layer: CALayer, total: Double, hold: Double) {
        let fade = 0.5
        let clampedHold = min(hold, max(0, total - fade))
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0, 0]
        anim.keyTimes = [
            0,
            NSNumber(value: clampedHold / total),
            NSNumber(value: (clampedHold + fade) / total),
            1,
        ]
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "hookOpacity")
        layer.opacity = 0   // final state after the animation
    }
}
