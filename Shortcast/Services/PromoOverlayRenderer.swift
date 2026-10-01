import AVFoundation
import AppKit
import QuartzCore

/// Burns a compact, tasteful RedQueen Security promo chip into the top of a vertical
/// short. It occupies only a slim strip so it never covers the content, and uses Core
/// Animation for a premium feel: the chip slides in, a red halo gently breathes, and a
/// specular light sweeps across it every few seconds.
enum PromoOverlayRenderer {

    // RedQueen brand palette (crimson).
    private static let crimson       = NSColor(red: 0.80, green: 0.12, blue: 0.16, alpha: 1)
    private static let crimsonLight  = NSColor(red: 0.95, green: 0.26, blue: 0.30, alpha: 1)
    private static let crimsonDeep   = NSColor(red: 0.42, green: 0.04, blue: 0.08, alpha: 1)

    static func render(videoURL: URL, config: PromoOverlayConfig) async throws -> URL {
        let cfg = config.sanitized
        guard cfg.isValid else { throw MediaExtractorError.clipExportFailed("promo disabled") }

        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        let total = CMTimeGetSeconds(duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        // INSERT THE ENTIRE ASSET TO PRESERVE EXACT TIMING (EDTS / B-FRAMES)
        try await composition.insertTimeRange(full, of: asset, at: .zero)
        guard let compVideo = try await composition.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "AVFoundation", code: 1, userInfo: nil)
        }

        let oriented = naturalSize.applying(transform)
        let natural = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        // Composite at a minimum short-side of 1080 so the burned-in banner stays razor
        // sharp even when the source clip is low-res (a 9:16 crop of 1080p landscape is
        // only ~608 wide). The video is upscaled to fill; the overlay is drawn fresh at
        // the higher resolution, so it never inherits the source's softness.
        let (renderSize, upscale) = Self.targetRenderSize(natural)

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

        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        addBanner(to: parentLayer, promoCode: cfg.promoCode, renderSize: renderSize,
                  total: total, holdSeconds: cfg.holdSeconds)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-promo-\(UUID().uuidString).mp4")
        try await HighBitrateExporter.export(
            asset: composition, videoComposition: videoComposition, to: outputURL)
        return outputURL
    }

    /// The resolution to composite at: at least a `minShortSide` short edge, upscaling a
    /// low-res source so burned-in overlays stay sharp. Returns the render size and the
    /// scale factor applied to the source video (1 when no upscale is needed). Shared by
    /// the other overlay renderers.
    static func targetRenderSize(_ natural: CGSize, minShortSide: CGFloat = 1080) -> (CGSize, CGFloat) {
        let shortSide = min(natural.width, natural.height)
        guard shortSide > 0, minShortSide / shortSide > 1 else { return (natural, 1) }
        let upscale = minShortSide / shortSide
        let size = CGSize(width: (natural.width * upscale).rounded(),
                          height: (natural.height * upscale).rounded())
        return (size, upscale)
    }

    // MARK: - Layers

    private struct BannerLayers {
        let container: CALayer   // clipped chip (bg + content + shimmer)
        let glow: CALayer        // sibling halo behind the chip
        let shimmer: CALayer     // specular sweep inside the chip
    }

    /// Adds the promo chip to an existing Core Animation render tree. Reusable so the
    /// reframe/hook/subtitle renderers can burn it in during the same export pass.
    /// `promoCode` is kept for call-site compatibility; the chip advertises the bot and
    /// does not display a code.
    static func addBanner(to parentLayer: CALayer, promoCode: String,
                          renderSize: CGSize, total: Double, holdSeconds: Double = 0) {
        // How long the banner stays before retracting. 0 => half the video.
        let visible = holdSeconds > 0 ? min(holdSeconds, total) : total * 0.5
        let b = makeBannerLayers(renderSize: renderSize)
        addBannerAnimations(container: b.container, glow: b.glow, shimmer: b.shimmer,
                            total: total, visible: visible)
        parentLayer.addSublayer(b.glow)       // halo sits behind
        parentLayer.addSublayer(b.container)
    }

    private static func makeBannerLayers(renderSize: CGSize) -> BannerLayers {
        let w = renderSize.width
        let h = renderSize.height
        let pillH = w * 0.17          // slim strip — room for name + slogan + handle
        let pillW = w * 0.92
        let topGap = w * 0.045
        let corner = pillH * 0.32
        let frame = CGRect(x: (w - pillW) / 2, y: h - topGap - pillH, width: pillW, height: pillH)

        // Breathing red halo behind the chip (its own layer so masksToBounds on the chip
        // doesn't clip the shadow).
        let glow = CALayer()
        glow.frame = frame
        glow.cornerRadius = corner
        glow.backgroundColor = NSColor.clear.cgColor
        glow.shadowColor = crimsonLight.cgColor
        glow.shadowRadius = w * 0.035
        glow.shadowOpacity = 0.85
        glow.shadowOffset = .zero
        glow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                                 cornerWidth: corner, cornerHeight: corner, transform: nil)

        // The chip itself, clipped to a rounded rect.
        let container = CALayer()
        container.frame = frame
        container.cornerRadius = corner
        container.masksToBounds = true
        container.allowsEdgeAntialiasing = true
        container.borderWidth = max(1, w * 0.0035)
        container.borderColor = crimsonLight.withAlphaComponent(0.55).cgColor

        let bg = CALayer()
        bg.frame = container.bounds
        bg.contentsScale = 4
        bg.contents = paintBackground(size: frame.size)
        container.addSublayer(bg)

        let content = CALayer()
        content.frame = container.bounds
        content.contentsScale = 4
        content.contents = paintContent(size: frame.size)
        container.addSublayer(content)

        // Specular sweep: a tilted bright band that slides across the chip.
        let shimmer = CAGradientLayer()
        let bandW = pillW * 0.30
        shimmer.frame = CGRect(x: 0, y: -pillH * 0.6, width: bandW, height: pillH * 2.2)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        shimmer.locations = [0, 0.5, 1]
        shimmer.transform = CATransform3DMakeRotation(-18 * .pi / 180, 0, 0, 1)
        container.addSublayer(shimmer)

        return BannerLayers(container: container, glow: glow, shimmer: shimmer)
    }

    // MARK: - Animations

    private static func addBannerAnimations(container: CALayer, glow: CALayer,
                                            shimmer: CALayer, total: Double, visible: Double) {
        let appear = min(0.5, total * 0.14)
        let retract = min(0.45, total * 0.12)
        slideAndFade(container, total: total, appear: appear, visible: visible, retract: retract)
        slideAndFade(glow, total: total, appear: appear, visible: visible, retract: retract)
        pulseGlow(glow, total: total, appear: appear, visible: visible)
        sweepShimmer(shimmer, pillW: container.bounds.width, total: total, appear: appear, visible: visible)
    }

    /// Slides the layer down from above and holds it; then, unless it stays the whole clip,
    /// slides it back up and fades it out at `visible`.
    private static func slideAndFade(_ layer: CALayer, total: Double,
                                     appear: Double, visible: Double, retract: Double) {
        let above = layer.bounds.height * 1.25   // fully parked above the top edge
        let tIn = min(0.4, appear / max(0.001, total))

        let slide = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let fade = CAKeyframeAnimation(keyPath: "opacity")

        if visible >= total {
            slide.values = [above, 0, 0]
            slide.keyTimes = [0, NSNumber(value: tIn), 1]
            slide.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                     CAMediaTimingFunction(name: .linear)]
            fade.values = [0, 1, 1]
            fade.keyTimes = [0, NSNumber(value: tIn), 1]
        } else {
            let tHold = max(tIn + 0.001, min(0.997, visible / total))
            let tOut = min(1.0, max(tHold + 0.001, (visible + retract) / total))
            slide.values = [above, 0, 0, above]
            slide.keyTimes = [0, NSNumber(value: tIn), NSNumber(value: tHold), NSNumber(value: tOut)]
            slide.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                                     CAMediaTimingFunction(name: .linear),
                                     CAMediaTimingFunction(name: .easeIn)]
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: tIn), NSNumber(value: tHold), NSNumber(value: tOut)]
        }

        for anim in [slide, fade] {
            anim.duration = total
            anim.beginTime = AVCoreAnimationBeginTimeAtZero
            anim.isRemovedOnCompletion = false
            anim.fillMode = .both
        }
        layer.add(slide, forKey: "promoSlide")
        layer.add(fade, forKey: "promoFade")
    }

    private static func pulseGlow(_ glow: CALayer, total: Double, appear: Double, visible: Double) {
        let cycle = 2.4
        let steps = max(6, Int(total / cycle) * 4)
        var values: [Double] = []
        var times: [NSNumber] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps) * total
            let v: Double
            if t < appear || t > visible {
                v = 0
            } else {
                let phase = (t - appear).truncatingRemainder(dividingBy: cycle) / cycle
                v = 0.35 + 0.55 * (0.5 + 0.5 * sin(phase * .pi * 2))
            }
            values.append(v)
            times.append(NSNumber(value: min(0.999, t / total)))
        }
        values.append(0); times.append(1)

        let anim = CAKeyframeAnimation(keyPath: "shadowOpacity")
        anim.values = values
        anim.keyTimes = times
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        glow.add(anim, forKey: "promoGlowPulse")
    }

    /// A light band that waits, then sweeps across the chip — repeating only while visible.
    private static func sweepShimmer(_ shimmer: CALayer, pillW: CGFloat,
                                     total: Double, appear: Double, visible: Double) {
        let cycle = 3.2
        let travel = pillW * 1.6
        let offLeft = pillW * 0.6
        let window = max(cycle, visible - appear)
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [-offLeft, -offLeft, travel, travel]
        anim.keyTimes = [0, 0.55, 0.85, 1]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]
        anim.duration = cycle
        anim.repeatCount = Float(max(1, floor(window / cycle)))
        anim.beginTime = AVCoreAnimationBeginTimeAtZero + appear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        shimmer.add(anim, forKey: "promoShimmer")
    }

    // MARK: - Painting

    private static func paintBackground(size: CGSize) -> CGImage? {
        let scale: CGFloat = 4
        let pxW = max(1, Int(size.width * scale))
        let pxH = max(1, Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        // Near-black glass so the video subtly shows through.
        ctx.setFillColor(NSColor(red: 0.05, green: 0.02, blue: 0.03, alpha: 0.82).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        // Crimson glow anchored on the left (under the shield emblem).
        let colors = [
            crimson.withAlphaComponent(0.55).cgColor,
            crimsonDeep.withAlphaComponent(0.35).cgColor,
            crimsonDeep.withAlphaComponent(0.0).cgColor,
        ] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(g,
                startCenter: CGPoint(x: size.height * 0.62, y: size.height * 0.5), startRadius: 0,
                endCenter: CGPoint(x: size.height * 0.62, y: size.height * 0.5),
                endRadius: size.width * 0.55, options: [])
        }

        // Thin top highlight for a glassy edge.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - max(1, size.height * 0.03),
                        width: size.width, height: max(1, size.height * 0.03)))

        return ctx.makeImage()
    }

    private static func paintContent(size: CGSize) -> CGImage? {
        let scale: CGFloat = 4
        let pxW = max(1, Int(size.width * scale))
        let pxH = max(1, Int(size.height * scale))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        nsCtx.imageInterpolation = .high
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        ctx.scaleBy(x: scale, y: scale)

        // Bot avatar (or shield fallback) on the left.
        let iconD = size.height * 0.66
        let iconRect = CGRect(x: size.height * 0.18, y: (size.height - iconD) / 2,
                              width: iconD, height: iconD)
        drawIcon(in: iconRect, ctx: ctx)

        // Text block: name · slogan (what it is / for what) · handle.
        let textX = iconRect.maxX + size.height * 0.18

        let title = "RedQueen Security"
        title.draw(at: CGPoint(x: textX, y: size.height * 0.605), withAttributes: [
            .font: NSFont.systemFont(ofSize: size.height * 0.225, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: 0.3,
        ])

        let slogan = "Умная AI-модерация Telegram-чатов"
        slogan.draw(at: CGPoint(x: textX, y: size.height * 0.375), withAttributes: [
            .font: NSFont.systemFont(ofSize: size.height * 0.145, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ])

        let handle = "@RedQueenSecurity_Bot · капча · антиспам"
        handle.draw(at: CGPoint(x: textX, y: size.height * 0.145), withAttributes: [
            .font: NSFont.systemFont(ofSize: size.height * 0.135, weight: .semibold),
            .foregroundColor: crimsonLight,
            .kern: 0.2,
        ])

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Draws the bot avatar (asset "BotAvatar") clipped to a circle with a crimson ring.
    /// Falls back to a drawn shield when the asset isn't in the bundle, so it always builds.
    private static func drawIcon(in r: CGRect, ctx: CGContext) {
        if let img = NSImage(named: "BotAvatar") {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: r).addClip()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            let ring = NSBezierPath(ovalIn: r)
            ring.lineWidth = max(1.5, r.width * 0.06)
            crimsonLight.setStroke()
            ring.stroke()
        } else {
            let sr = CGRect(x: r.minX + r.width * 0.12, y: r.minY,
                            width: r.width * 0.76, height: r.height)
            drawShield(in: sr, ctx: ctx)
        }
    }

    /// A crimson shield with a white check — the bot's security mark.
    private static func drawShield(in r: CGRect, ctx: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.40))
        path.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY),
                          control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.12))
        path.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.40),
                          control: CGPoint(x: r.minX, y: r.minY + r.height * 0.12))
        path.closeSubpath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [crimsonLight.cgColor, crimson.cgColor, crimsonDeep.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY),
                                   end: CGPoint(x: r.midX, y: r.minY), options: [])
        }
        ctx.restoreGState()

        // Subtle inner rim.
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(max(1, r.width * 0.03))
        ctx.strokePath()

        // White check mark.
        let cx = r.midX, cy = r.minY + r.height * 0.52
        let s = r.width * 0.26
        let check = CGMutablePath()
        check.move(to: CGPoint(x: cx - s, y: cy))
        check.addLine(to: CGPoint(x: cx - s * 0.2, y: cy - s * 0.75))
        check.addLine(to: CGPoint(x: cx + s * 1.05, y: cy + s * 0.7))
        ctx.addPath(check)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(r.width * 0.12)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }
}
