import AVFoundation
import AppKit
import QuartzCore

/// Full appearance config for the burned-in watermark. Codable so it lives in
/// UserDefaults via AppSettings, matching the SubtitleAppearance pattern.
struct WatermarkAppearance: Codable, Equatable, Sendable {
    var fontSizeScale: Double = 0.026
    var opacity: Double = 0.85
    var positionRaw: String = WatermarkPosition.bottomLeft.rawValue
    var animationRaw: String = WatermarkAnimation.typewriter.rawValue
    var holdDuration: Double = 2.5
    var typingDuration: Double = 1.5

    enum WatermarkPosition: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottomLeft, bottomCenter, bottomRight, topLeft, topCenter, topRight
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .bottomLeft:   "Bottom Left"
            case .bottomCenter: "Bottom Center"
            case .bottomRight:  "Bottom Right"
            case .topLeft:      "Top Left"
            case .topCenter:    "Top Center"
            case .topRight:     "Top Right"
            }
        }
    }

    var position: WatermarkPosition {
        get { WatermarkPosition(rawValue: positionRaw) ?? .bottomLeft }
        set { positionRaw = newValue.rawValue }
    }

    enum WatermarkAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
        case typewriter, scanLine, subtitle, cursorUnderscore, hud, cinematicFocus, maskWipe, glitch, neon, bounce, `static`
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .typewriter:       "Typewriter"
            case .scanLine:         "Scan Line"
            case .subtitle:         "Subtitle"
            case .cursorUnderscore: "Cursor _"
            case .hud:              "HUD"
            case .cinematicFocus:   "Cinematic Focus"
            case .maskWipe:         "Mask Wipe"
            case .glitch:           "Glitch"
            case .neon:             "Neon Glow"
            case .bounce:           "Bounce"
            case .static:           "Static"
            }
        }
    }

    var animation: WatermarkAnimation {
        get { WatermarkAnimation(rawValue: animationRaw) ?? .typewriter }
        set { animationRaw = newValue.rawValue }
    }

    static let `default` = WatermarkAppearance()
}

/// Renders a configurable watermark into a video
/// via `AVVideoCompositionCoreAnimationTool`. Returns a new temporary `.mp4`.
enum WatermarkRenderer {

    /// Renders `videoURL` with `text` as a watermark configured by `appearance`.
    /// Returns a new temp `.mp4`. Throws `MediaExtractorError.clipExportFailed`.
    static func render(videoURL: URL, text: String, appearance: WatermarkAppearance) async throws -> URL {
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
        // ≥1080 short side so the burned-in watermark stays sharp on low-res sources.
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

        do {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            let parentLayer = CALayer()
            let videoLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            addWatermark(
                to: parentLayer, text: text, appearance: appearance,
                renderSize: renderSize, totalDuration: total)

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-wm-\(UUID().uuidString).mp4")
        try await HighBitrateExporter.export(
            asset: composition, videoComposition: videoComposition, to: outputURL)
        return outputURL
    }

    /// Adds a watermark to an existing Core Animation composition. This lets
    /// callers share a single video export with other overlays (for example,
    /// subtitles) instead of encoding the same clip twice.
    static func addWatermark(
        to parentLayer: CALayer,
        text: String,
        appearance: WatermarkAppearance,
        renderSize: CGSize,
        totalDuration: Double
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let watermark = makeLayers(text: text, appearance: appearance, renderSize: renderSize)

        switch appearance.animation {
        case .typewriter:
            addTypewriterAnimation(to: watermark.text, cursor: watermark.cursor, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
            if let cursor = watermark.cursor { parentLayer.addSublayer(cursor) }
        case .cursorUnderscore:
            addCursorBlinkAnimation(to: watermark.text, cursor: watermark.cursor, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
            if let cursor = watermark.cursor { parentLayer.addSublayer(cursor) }
        case .scanLine:
            addMaskWipeAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            addScanLineAnimation(to: watermark.cursor, textWidth: watermark.text.bounds.width,
                                 total: totalDuration, appearance: appearance)
            if let cursor = watermark.cursor { parentLayer.addSublayer(cursor) }
            parentLayer.addSublayer(watermark.text)
        case .subtitle:
            let bgLayer = CALayer()
            let bgInsetX: CGFloat = max(4, watermark.text.frame.width * 0.06)
            let bgInsetY: CGFloat = max(2, watermark.text.frame.height * 0.15)
            bgLayer.frame = watermark.text.frame.insetBy(dx: -bgInsetX, dy: -bgInsetY)
            bgLayer.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
            bgLayer.cornerRadius = max(2, bgLayer.frame.height * 0.15)
            addFadeAnimation(to: bgLayer, total: totalDuration, appearance: appearance)
            bgLayer.opacity = 0
            parentLayer.addSublayer(bgLayer)

            addFadeAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            watermark.text.opacity = 0
            parentLayer.addSublayer(watermark.text)
        case .hud:
            addHUDAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
        case .cinematicFocus:
            addCinematicFocusAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
        case .maskWipe:
            addMaskWipeAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
        case .glitch:
            addGlitchAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
        case .neon:
            addFadeAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            watermark.text.opacity = 0
            // Persistent colored halo around the text.
            watermark.text.shadowColor = NSColor(hex: "#48B7FF")?.cgColor ?? NSColor.cyan.cgColor
            watermark.text.shadowRadius = max(4, renderSize.width * appearance.fontSizeScale * 0.3)
            watermark.text.shadowOpacity = 1.0
            watermark.text.shadowOffset = .zero
            watermark.text.masksToBounds = false
            parentLayer.addSublayer(watermark.text)
        case .bounce:
            addFadeAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            watermark.text.opacity = 0
            addBounceAnimation(to: watermark.text, total: totalDuration, appearance: appearance)
            parentLayer.addSublayer(watermark.text)
        case .static:
            watermark.text.opacity = Float(appearance.opacity)
            parentLayer.addSublayer(watermark.text)
        }

    }

    // MARK: - Layer construction

    /// Builds the optional cursor layer (for cursor/scan styles) and the
    /// main text layer positioned according to `appearance.position`.
    private static func makeLayers(text: String, appearance: WatermarkAppearance,
                                   renderSize: CGSize) -> (text: CALayer, cursor: CALayer?) {
        let fontSize = max(16, renderSize.width * appearance.fontSizeScale)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let padding: CGFloat = max(16, renderSize.width * 0.02)

        let displayText: String
        switch appearance.animation {
        case .subtitle:
            displayText = "[ \(text.uppercased()) ]"
        case .hud:
            displayText = "ID // \(text.uppercased().replacingOccurrences(of: "@", with: ""))"
        default:
            displayText = text
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: displayText, attributes: attributes)
        let textBounds = attributed.boundingRect(
            with: CGSize(width: renderSize.width * 0.5, height: renderSize.height),
            options: [.usesFontLeading])
        let textWidth = ceil(textBounds.width)
        let textHeight = ceil(textBounds.height)

        var textOrigin: CGPoint
        switch appearance.position {
        case .bottomLeft:
            textOrigin = CGPoint(x: padding, y: padding)
        case .bottomCenter:
            textOrigin = CGPoint(x: (renderSize.width - textWidth) / 2, y: padding)
        case .bottomRight:
            textOrigin = CGPoint(x: renderSize.width - textWidth - padding, y: padding)
        case .topLeft:
            textOrigin = CGPoint(x: padding, y: renderSize.height - textHeight - padding)
        case .topCenter:
            textOrigin = CGPoint(x: (renderSize.width - textWidth) / 2,
                                 y: renderSize.height - textHeight - padding)
        case .topRight:
            textOrigin = CGPoint(x: renderSize.width - textWidth - padding, y: renderSize.height - textHeight - padding)
        }

        let textLayer = CALayer()
        textLayer.frame = CGRect(origin: textOrigin, size: CGSize(width: textWidth, height: textHeight))
        textLayer.contentsScale = 3
        textLayer.contentsGravity = .left
        textLayer.opacity = Float(appearance.opacity)
        textLayer.contents = renderTextImage(attributed, size: CGSize(width: textWidth, height: textHeight))

        var cursorLayer: CALayer?
        if [.typewriter, .scanLine, .cursorUnderscore].contains(appearance.animation) {
            // Measure text without the cursor suffix for cursor positioning.
            let textOnlyAttr = NSAttributedString(string: text, attributes: attributes)
            let textOnlyBounds = textOnlyAttr.boundingRect(
                with: CGSize(width: renderSize.width * 0.5, height: renderSize.height),
                options: [.usesFontLeading])
            let textOnlyWidth = ceil(textOnlyBounds.width)

            let cursorHeight = textHeight * 0.78
            let cursorWidth: CGFloat = max(2, fontSize * 0.08)
            let cursorX: CGFloat
            switch appearance.animation {
            case .scanLine:
                cursorX = textOrigin.x - max(6, fontSize * 0.25)
            case .cursorUnderscore:
                cursorX = textOrigin.x + textOnlyWidth
            default:
                cursorX = textOrigin.x - max(6, fontSize * 0.25)
            }
            let cursorY = textOrigin.y + (textHeight - cursorHeight) / 2

            let cursor = CALayer()
            cursor.frame = CGRect(x: cursorX, y: cursorY, width: cursorWidth, height: cursorHeight)
            cursor.backgroundColor = NSColor.white.withAlphaComponent(CGFloat(appearance.opacity)).cgColor
            cursor.cornerRadius = cursorWidth * 0.5
            cursorLayer = cursor
        }

        return (textLayer, cursorLayer)
    }

    /// For .typewriter: reveal left-to-right, hold, then erase right-to-left.
    private static func addTypewriterAnimation(to textLayer: CALayer, cursor: CALayer?,
                                                total: Double, appearance: WatermarkAppearance) {
        let typingBegin = min(0.3, total * 0.1)
        let available = max(0.4, total - typingBegin - 0.1)
        let typingDuration = min(appearance.typingDuration, available * 0.45)
        let typingEnd = typingBegin + typingDuration
        let eraseDuration = min(typingDuration, max(0.2, total - typingEnd - 0.1))
        let holdDuration = min(appearance.holdDuration, max(0.0, total - typingEnd - eraseDuration))
        let holdEnd = typingEnd + holdDuration
        let eraseEnd = min(total, holdEnd + eraseDuration)

        // ── Text reveal (discrete per-character) ──
        let steps = max(1, 10) // smooth enough for short texts
        var ctValues: [CGRect] = []
        var ctKeyTimes: [NSNumber] = []
        ctValues.append(CGRect(x: 0, y: 0, width: 0, height: 1))
        ctKeyTimes.append(0)

        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let t = typingBegin + typingDuration * progress
            ctValues.append(CGRect(x: 0, y: 0, width: progress, height: 1))
            ctKeyTimes.append(NSNumber(value: min(0.999, t / total)))
        }

        // Hold at full
        ctValues.append(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctKeyTimes.append(NSNumber(value: min(0.999, holdEnd / total)))

        // Erase back to the left.
        for i in 1...steps {
            let progress = 1.0 - Double(i) / Double(steps)
            let t = holdEnd + eraseDuration * (Double(i) / Double(steps))
            ctValues.append(CGRect(x: 0, y: 0, width: max(0, progress), height: 1))
            ctKeyTimes.append(NSNumber(value: min(0.999, t / total)))
        }

        ctValues.append(CGRect(x: 0, y: 0, width: 0, height: 1))
        ctKeyTimes.append(NSNumber(value: min(0.999, eraseEnd / total)))
        ctValues.append(CGRect(x: 0, y: 0, width: 0, height: 1))
        ctKeyTimes.append(1)

        let revealAnim = CAKeyframeAnimation(keyPath: "contentsRect")
        revealAnim.values = ctValues
        revealAnim.keyTimes = ctKeyTimes
        revealAnim.duration = total
        revealAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        revealAnim.isRemovedOnCompletion = false
        revealAnim.fillMode = .both
        revealAnim.calculationMode = .discrete
        textLayer.add(revealAnim, forKey: "reveal")

        // ── Text opacity (fade out at end) ──
        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        let baseOpacity = Double(textLayer.opacity)
        opacityAnim.values = [baseOpacity, baseOpacity, baseOpacity, baseOpacity, 0, 0]
        opacityAnim.keyTimes = [
            0,
            NSNumber(value: min(0.999, typingBegin / total)),
            NSNumber(value: min(0.999, typingEnd / total)),
            NSNumber(value: min(0.999, holdEnd / total)),
            NSNumber(value: min(0.999, eraseEnd / total)),
            1,
        ]
        opacityAnim.duration = total
        opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        opacityAnim.isRemovedOnCompletion = false
        opacityAnim.fillMode = .both
        textLayer.add(opacityAnim, forKey: "textOpacity")

        // ── Cursor follows the typed edge, blinks while holding, then erases back. ──
        guard let cursor else { return }
        let startX = cursor.position.x
        let endX = startX + textLayer.bounds.width + 4
        let cursorMove = CAKeyframeAnimation(keyPath: "position.x")
        cursorMove.values = [startX, startX, endX, endX, startX, startX]
        cursorMove.keyTimes = [
            0,
            NSNumber(value: min(0.999, typingBegin / total)),
            NSNumber(value: min(0.999, typingEnd / total)),
            NSNumber(value: min(0.999, holdEnd / total)),
            NSNumber(value: min(0.999, eraseEnd / total)),
            1,
        ]
        cursorMove.duration = total
        cursorMove.beginTime = AVCoreAnimationBeginTimeAtZero
        cursorMove.isRemovedOnCompletion = false
        cursorMove.fillMode = .both
        cursor.add(cursorMove, forKey: "cursorMove")

        var blinkValues: [Double] = [1]
        var blinkTimes: [NSNumber] = [0]

        var t = typingBegin
        let blinkOn: Double = 0.35
        let blinkOff: Double = 0.25
        while t < eraseEnd {
            t += blinkOn
            if t >= eraseEnd { break }
            blinkValues.append(0)
            blinkTimes.append(NSNumber(value: min(0.999, t / total)))
            t += blinkOff
            if t >= eraseEnd { break }
            blinkValues.append(1)
            blinkTimes.append(NSNumber(value: min(0.999, t / total)))
        }

        // Fade out
        blinkValues.append(0)
        blinkTimes.append(NSNumber(value: min(0.999, eraseEnd / total)))
        blinkValues.append(0)
        blinkTimes.append(1)

        let cursorAnim = CAKeyframeAnimation(keyPath: "opacity")
        cursorAnim.values = blinkValues
        cursorAnim.keyTimes = blinkTimes
        cursorAnim.duration = total
        cursorAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        cursorAnim.isRemovedOnCompletion = false
        cursorAnim.fillMode = .both
        cursor.add(cursorAnim, forKey: "cursorBlink")
    }

    /// For .cursorUnderscore: same typewriter reveal/erase, but cursor stays at
    /// the end of the text and simply blinks (no sweep).
    private static func addCursorBlinkAnimation(to textLayer: CALayer, cursor: CALayer?,
                                                total: Double, appearance: WatermarkAppearance) {
        let typingBegin = min(0.3, total * 0.1)
        let available = max(0.4, total - typingBegin - 0.1)
        let typingDuration = min(appearance.typingDuration, available * 0.45)
        let typingEnd = typingBegin + typingDuration
        let eraseDuration = min(typingDuration, max(0.2, total - typingEnd - 0.1))
        let holdDuration = min(appearance.holdDuration, max(0.0, total - typingEnd - eraseDuration))
        let holdEnd = typingEnd + holdDuration
        let eraseEnd = min(total, holdEnd + eraseDuration)

        // ── Text reveal / hold / erase ──
        let steps = max(1, 10)
        var ctValues: [CGRect] = []
        var ctKeyTimes: [NSNumber] = []
        ctValues.append(CGRect(x: 0, y: 0, width: 0, height: 1))
        ctKeyTimes.append(0)

        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let t = typingBegin + typingDuration * progress
            ctValues.append(CGRect(x: 0, y: 0, width: progress, height: 1))
            ctKeyTimes.append(NSNumber(value: min(0.999, t / total)))
        }
        ctValues.append(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctKeyTimes.append(NSNumber(value: min(0.999, holdEnd / total)))

        for i in 1...steps {
            let progress = 1.0 - Double(i) / Double(steps)
            let t = holdEnd + eraseDuration * (Double(i) / Double(steps))
            ctValues.append(CGRect(x: 0, y: 0, width: max(0, progress), height: 1))
            ctKeyTimes.append(NSNumber(value: min(0.999, t / total)))
        }
        ctValues.append(CGRect(x: 0, y: 0, width: 0, height: 1))
        ctKeyTimes.append(NSNumber(value: min(0.999, eraseEnd / total)))
        ctValues.append(CGRect(x: 0, y: 0, width: 0, height: 1))
        ctKeyTimes.append(1)

        let revealAnim = CAKeyframeAnimation(keyPath: "contentsRect")
        revealAnim.values = ctValues
        revealAnim.keyTimes = ctKeyTimes
        revealAnim.duration = total
        revealAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        revealAnim.isRemovedOnCompletion = false
        revealAnim.fillMode = .both
        revealAnim.calculationMode = .discrete
        textLayer.add(revealAnim, forKey: "reveal")

        // ── Text opacity ──
        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        let baseOpacity = Double(textLayer.opacity)
        opacityAnim.values = [baseOpacity, baseOpacity, baseOpacity, baseOpacity, 0, 0]
        opacityAnim.keyTimes = [
            0,
            NSNumber(value: min(0.999, typingBegin / total)),
            NSNumber(value: min(0.999, typingEnd / total)),
            NSNumber(value: min(0.999, holdEnd / total)),
            NSNumber(value: min(0.999, eraseEnd / total)),
            1,
        ]
        opacityAnim.duration = total
        opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        opacityAnim.isRemovedOnCompletion = false
        opacityAnim.fillMode = .both
        textLayer.add(opacityAnim, forKey: "textOpacity")

        // ── Cursor: blink only (static position) ──
        guard let cursor else { return }
        var blinkValues: [Double] = [0]
        var blinkTimes: [NSNumber] = [0]

        var t = typingBegin
        let blinkOn: Double = 0.35
        let blinkOff: Double = 0.25
        while t < eraseEnd {
            t += blinkOn
            if t >= eraseEnd { break }
            blinkValues.append(1)
            blinkTimes.append(NSNumber(value: min(0.999, t / total)))
            t += blinkOff
            if t >= eraseEnd { break }
            blinkValues.append(0)
            blinkTimes.append(NSNumber(value: min(0.999, t / total)))
        }

        blinkValues.append(0)
        blinkTimes.append(NSNumber(value: min(0.999, eraseEnd / total)))
        blinkValues.append(0)
        blinkTimes.append(1)

        let cursorAnim = CAKeyframeAnimation(keyPath: "opacity")
        cursorAnim.values = blinkValues
        cursorAnim.keyTimes = blinkTimes
        cursorAnim.duration = total
        cursorAnim.beginTime = AVCoreAnimationBeginTimeAtZero
        cursorAnim.isRemovedOnCompletion = false
        cursorAnim.fillMode = .both
        cursor.add(cursorAnim, forKey: "cursorBlink")
    }

    /// For .fade: simple fade in, hold, fade out.
    /// Springy scale-in overshoot at the start, matched to the fade-in window.
    private static func addBounceAnimation(to layer: CALayer, total: Double, appearance: WatermarkAppearance) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.6, 1.18, 0.94, 1.0]
        scale.keyTimes = [0, 0.5, 0.78, 1]
        scale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        scale.beginTime = AVCoreAnimationBeginTimeAtZero + min(0.4, total * 0.1)
        scale.duration = 0.4
        scale.fillMode = .both
        scale.isRemovedOnCompletion = false
        layer.add(scale, forKey: "bounceScale")
    }

    private static func addFadeAnimation(to layer: CALayer, total: Double, appearance: WatermarkAppearance) {
        let opacity = Double(layer.opacity)
        let fadeIn = min(0.4, total * 0.1)
        let holdEnd = min(total - 0.4, total - 0.3)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 0, opacity, opacity, 0, 0]
        anim.keyTimes = [
            0,
            NSNumber(value: min(0.999, fadeIn / total)),
            NSNumber(value: min(0.999, (fadeIn + 0.2) / total)),
            NSNumber(value: min(0.999, holdEnd / total)),
            NSNumber(value: min(0.999, (holdEnd + 0.3) / total)),
            1,
        ]
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "fadeOpacity")
    }

    /// Clean mask-style reveal + erase: width 0→1→0, matching the preview.
    private static func addMaskWipeAnimation(to layer: CALayer, total: Double, appearance: WatermarkAppearance) {
        let reveal = min(0.55, max(0.25, total * 0.12))
        let holdEnd = min(total - 0.35, reveal + appearance.holdDuration)

        let contents = CAKeyframeAnimation(keyPath: "contentsRect")
        contents.values = [
            CGRect(x: 0, y: 0, width: 0, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 0, height: 1),
        ]
        contents.keyTimes = [
            0,
            NSNumber(value: min(0.999, reveal / total)),
            NSNumber(value: min(0.999, holdEnd / total)),
            1,
        ]
        contents.duration = total
        contents.beginTime = AVCoreAnimationBeginTimeAtZero
        contents.isRemovedOnCompletion = false
        contents.fillMode = .both
        layer.add(contents, forKey: "maskWipe")

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, appearance.opacity, appearance.opacity, 0]
        opacity.keyTimes = contents.keyTimes
        opacity.duration = total
        opacity.beginTime = AVCoreAnimationBeginTimeAtZero
        opacity.isRemovedOnCompletion = false
        opacity.fillMode = .both
        layer.add(opacity, forKey: "wipeOpacity")
    }

    /// Scan cursor moves across the text while the same mask reveal opens it.
    private static func addScanLineAnimation(to cursor: CALayer?, textWidth: CGFloat,
                                             total: Double, appearance: WatermarkAppearance) {
        guard let cursor else { return }
        let reveal = min(0.55, max(0.25, total * 0.12))
        let holdEnd = min(total - 0.35, reveal + appearance.holdDuration)
        let startX = cursor.position.x
        let endX = cursor.position.x + max(24, textWidth + 10)

        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [startX, endX, endX]
        move.keyTimes = [0, NSNumber(value: min(0.999, reveal / total)), 1]
        move.duration = total
        move.beginTime = AVCoreAnimationBeginTimeAtZero
        move.isRemovedOnCompletion = false
        move.fillMode = .both
        cursor.add(move, forKey: "scanMove")

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [appearance.opacity, appearance.opacity, 0, 0]
        opacity.keyTimes = [
            0,
            NSNumber(value: min(0.999, reveal / total)),
            NSNumber(value: min(0.999, holdEnd / total)),
            1,
        ]
        opacity.duration = total
        opacity.beginTime = AVCoreAnimationBeginTimeAtZero
        opacity.isRemovedOnCompletion = false
        opacity.fillMode = .both
        cursor.add(opacity, forKey: "scanOpacity")
    }

    /// Cinematic focus impression: soft scale settle plus opacity in/out.
    private static func addCinematicFocusAnimation(to layer: CALayer, total: Double, appearance: WatermarkAppearance) {
        addFadeAnimation(to: layer, total: total, appearance: appearance)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.08, 1.0, 1.0, 0.985]
        scale.keyTimes = [0, 0.18, 0.82, 1]
        scale.duration = total
        scale.beginTime = AVCoreAnimationBeginTimeAtZero
        scale.isRemovedOnCompletion = false
        scale.fillMode = .both
        layer.add(scale, forKey: "cinematicScale")
    }

    /// Subtle interface/HUD entrance.
    private static func addHUDAnimation(to layer: CALayer, total: Double, appearance: WatermarkAppearance) {
        addFadeAnimation(to: layer, total: total, appearance: appearance)

        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        slide.values = [-8, 0, 0, 4]
        slide.keyTimes = [0, 0.14, 0.84, 1]
        slide.duration = total
        slide.beginTime = AVCoreAnimationBeginTimeAtZero
        slide.isRemovedOnCompletion = false
        slide.fillMode = .both
        layer.add(slide, forKey: "hudSlide")
    }

    /// Minimal digital hit: quick micro-jitter, then clean readable text.
    private static func addGlitchAnimation(to layer: CALayer, total: Double, appearance: WatermarkAppearance) {
        addFadeAnimation(to: layer, total: total, appearance: appearance)
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 0
        layer.shadowColor = NSColor.systemCyan.cgColor
        layer.shadowOffset = CGSize(width: 2, height: 0)

        let jitter = CAKeyframeAnimation(keyPath: "transform.translation.x")
        jitter.values = [0, -5, 4, -2, 0, 0, 3, -2, 0]
        jitter.keyTimes = [0, 0.035, 0.07, 0.105, 0.14, 0.82, 0.86, 0.90, 1]
        jitter.duration = total
        jitter.beginTime = AVCoreAnimationBeginTimeAtZero
        jitter.isRemovedOnCompletion = false
        jitter.fillMode = .both
        layer.add(jitter, forKey: "glitchJitter")

        let shadow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        shadow.values = [0.55, 0.8, 0, 0, 0.5, 0]
        shadow.keyTimes = [0, 0.08, 0.16, 0.82, 0.88, 1]
        shadow.duration = total
        shadow.beginTime = AVCoreAnimationBeginTimeAtZero
        shadow.isRemovedOnCompletion = false
        shadow.fillMode = .both
        layer.add(shadow, forKey: "glitchShadow")
    }

    // MARK: - Bitmap rendering

    /// Draws `text` into a 3× bitmap for use as a CALayer's `contents`. Same
    /// approach as `VideoOverlayRenderer.renderTextImage` to avoid CATextLayer
    /// quirks in offline rendering.
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
}
