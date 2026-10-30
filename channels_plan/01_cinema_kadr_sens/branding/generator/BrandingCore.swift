import Cocoa
import CoreGraphics
import CoreText
import ImageIO

// MARK: - 1. Color Palette & Aesthetics (Single Responsibility)
struct CinemaPalette {
    // Obsidian / Void Black tones
    static let obsidianVoid = CGColor(red: 8/255.0, green: 9/255.0, blue: 12/255.0, alpha: 1.0)
    static let obsidianDark = CGColor(red: 11/255.0, green: 12/255.0, blue: 16/255.0, alpha: 1.0)
    static let obsidianMedium = CGColor(red: 16/255.0, green: 17/255.0, blue: 22/255.0, alpha: 1.0)
    static let obsidianSlate = CGColor(red: 22/255.0, green: 25/255.0, blue: 33/255.0, alpha: 1.0)
    static let filmSlateGray = CGColor(red: 30/255.0, green: 32/255.0, blue: 40/255.0, alpha: 1.0)
    static let filmSlateLight = CGColor(red: 45/255.0, green: 48/255.0, blue: 60/255.0, alpha: 1.0)

    // Champagne & Antique Gold tones
    static let champagneGold = CGColor(red: 212/255.0, green: 175/255.0, blue: 55/255.0, alpha: 1.0) // #D4AF37
    static let champagneLight = CGColor(red: 236/255.0, green: 206/255.0, blue: 115/255.0, alpha: 1.0) // #ECCE73
    static let champagnePale = CGColor(red: 249/255.0, green: 236/255.0, blue: 202/255.0, alpha: 1.0) // #F9ECCA
    static let champagneDark = CGColor(red: 158/255.0, green: 128/255.0, blue: 38/255.0, alpha: 1.0) // #9E8026
    static let antiqueBronze = CGColor(red: 120/255.0, green: 96/255.0, blue: 28/255.0, alpha: 1.0)

    // Ivory & Crisp White tones
    static let warmIvory = CGColor(red: 250/255.0, green: 247/255.0, blue: 242/255.0, alpha: 1.0) // #FAF7F2
    static let pureWhite = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    static let mutedSilver = CGColor(red: 180/255.0, green: 184/255.0, blue: 195/255.0, alpha: 1.0)

    // Cinematic Accents
    static let recRed = CGColor(red: 224/255.0, green: 45/255.0, blue: 45/255.0, alpha: 1.0)
    static let anamorphicCyan = CGColor(red: 65/255.0, green: 145/255.0, blue: 195/255.0, alpha: 0.3)
    static let amberGlow = CGColor(red: 235/255.0, green: 160/255.0, blue: 60/255.0, alpha: 0.15)

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
        return CGColor(red: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }

    static func goldGradient(in colorSpace: CGColorSpace) -> CGGradient? {
        let colors = [champagneLight, champagneGold, champagneDark, champagneLight] as CFArray
        let locations: [CGFloat] = [0.0, 0.45, 0.80, 1.0]
        return CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)
    }

    static func subtleRadialBgGradient(in colorSpace: CGColorSpace) -> CGGradient? {
        let colors = [
            color(20, 23, 31),
            obsidianMedium,
            obsidianDark,
            obsidianVoid
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.35, 0.72, 1.0]
        return CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)
    }
}

// MARK: - 2. Typography Engine (Single Responsibility)
struct TypographyEngine {
    static func drawText(
        _ text: String,
        in context: CGContext,
        point: CGPoint,
        font: NSFont,
        color: CGColor,
        tracking: CGFloat = 0.0,
        alignment: NSTextAlignment = .center
    ) -> CGRect {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
            .kern: tracking,
            .paragraphStyle: paragraphStyle
        ]

        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent

        var drawX = point.x
        if alignment == .center {
            drawX -= width / 2.0
        } else if alignment == .right {
            drawX -= width
        }
        let drawY = point.y - (ascent - descent) / 2.0

        context.saveGState()
        context.textPosition = CGPoint(x: drawX, y: drawY)
        CTLineDraw(line, context)
        context.restoreGState()

        return CGRect(x: drawX, y: drawY - descent, width: width, height: height)
    }

    /// Master editorial brand title: «КАДР & СЕНС» with ivory letters and champagne gold italic ampersand
    static func drawBrandTitle(
        in context: CGContext,
        center: CGPoint,
        fontSize: CGFloat,
        tracking: CGFloat = 7.0
    ) -> CGRect {
        let str = NSMutableAttributedString()
        let mainFont = NSFont(name: "Baskerville-Bold", size: fontSize) ??
                       NSFont(name: "Georgia-Bold", size: fontSize) ??
                       NSFont.boldSystemFont(ofSize: fontSize)
        let ampFont = NSFont(name: "Baskerville-Italic", size: fontSize * 0.94) ??
                      NSFont(name: "Georgia-Italic", size: fontSize * 0.94) ??
                      mainFont

        let ivory = NSColor(cgColor: CinemaPalette.warmIvory)!
        let gold = NSColor(cgColor: CinemaPalette.champagneLight)!

        str.append(NSAttributedString(string: "КАДР", attributes: [
            .font: mainFont,
            .foregroundColor: ivory,
            .kern: tracking
        ]))
        str.append(NSAttributedString(string: " & ", attributes: [
            .font: ampFont,
            .foregroundColor: gold,
            .kern: tracking * 0.85
        ]))
        str.append(NSAttributedString(string: "СЕНС", attributes: [
            .font: mainFont,
            .foregroundColor: ivory,
            .kern: tracking
        ]))

        let line = CTLineCreateWithAttributedString(str as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let drawX = center.x - width / 2.0
        let drawY = center.y - (ascent - descent) / 2.0

        context.saveGState()
        context.textPosition = CGPoint(x: drawX, y: drawY)
        CTLineDraw(line, context)
        context.restoreGState()

        return CGRect(x: drawX, y: drawY - descent, width: width, height: ascent + descent)
    }

    static func serifFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if weight == .bold {
            return NSFont(name: "Baskerville-Bold", size: size) ??
                   NSFont(name: "Georgia-Bold", size: size) ??
                   NSFont.boldSystemFont(ofSize: size)
        } else {
            return NSFont(name: "Baskerville", size: size) ??
                   NSFont(name: "Georgia", size: size) ??
                   NSFont.systemFont(ofSize: size)
        }
    }

    static func grotesqueFont(size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        if weight == .bold {
            return NSFont(name: "AvenirNext-DemiBold", size: size) ??
                   NSFont(name: "HelveticaNeue-Bold", size: size) ??
                   NSFont.boldSystemFont(ofSize: size)
        } else if weight == .light {
            return NSFont(name: "AvenirNext-Light", size: size) ??
                   NSFont(name: "HelveticaNeue-Light", size: size) ??
                   NSFont.systemFont(ofSize: size, weight: .light)
        } else {
            return NSFont(name: "AvenirNext-Medium", size: size) ??
                   NSFont(name: "HelveticaNeue-Medium", size: size) ??
                   NSFont.systemFont(ofSize: size, weight: .medium)
        }
    }
}

// MARK: - 3. Geometric Motifs & Cinema Graphics (Single Responsibility)
struct CinemaGraphics {
    /// Draws viewfinder corner brackets [  ]
    static func drawViewfinderBrackets(
        in context: CGContext,
        rect: CGRect,
        cornerLength: CGFloat,
        strokeWidth: CGFloat,
        color: CGColor
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.square)

        let path = CGMutablePath()
        // Top-Left
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLength))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.maxY))

        // Top-Right
        path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))

        // Bottom-Right
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLength))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerLength, y: rect.minY))

        // Bottom-Left
        path.move(to: CGPoint(x: rect.minX + cornerLength, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerLength))

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Draws a crosshair [ + ]
    static func drawCrosshair(
        in context: CGContext,
        center: CGPoint,
        size: CGFloat,
        gap: CGFloat,
        strokeWidth: CGFloat,
        color: CGColor
    ) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)

        let halfSize = size / 2.0
        let halfGap = gap / 2.0

        let path = CGMutablePath()
        // Horizontal left
        path.move(to: CGPoint(x: center.x - halfSize, y: center.y))
        path.addLine(to: CGPoint(x: center.x - halfGap, y: center.y))
        // Horizontal right
        path.move(to: CGPoint(x: center.x + halfGap, y: center.y))
        path.addLine(to: CGPoint(x: center.x + halfSize, y: center.y))
        // Vertical bottom
        path.move(to: CGPoint(x: center.x, y: center.y - halfSize))
        path.addLine(to: CGPoint(x: center.x, y: center.y - halfGap))
        // Vertical top
        path.move(to: CGPoint(x: center.x, y: center.y + halfGap))
        path.addLine(to: CGPoint(x: center.x, y: center.y + halfSize))

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Draws master signature Cinema Aperture / Lens Emblem
    static func drawCinemaLensEmblem(
        in context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        primaryColor: CGColor,
        secondaryColor: CGColor,
        accentColor: CGColor,
        drawMonogram: Bool = true
    ) {
        context.saveGState()

        // 1. Outer subtle lens barrel calibration ring
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.22))
        context.setLineWidth(0.75)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        // 2. Calibrated Lens Angle Ticks (36 ticks every 10 degrees, with major ticks every 90 and 45)
        for i in 0..<36 {
            let angle = CGFloat(i) * (2.0 * .pi / 36.0)
            let isMajor = (i % 9 == 0)
            let isSemi = (i % 3 == 0)

            let tickLen: CGFloat = isMajor ? radius * 0.09 : (isSemi ? radius * 0.055 : radius * 0.03)
            let tickWidth: CGFloat = isMajor ? 1.5 : (isSemi ? 1.0 : 0.6)
            let tickColor = isMajor ? primaryColor : (isSemi ? secondaryColor : CinemaPalette.color(212, 175, 55, 0.35))

            let xOuter = center.x + (radius - 2) * cos(angle)
            let yOuter = center.y + (radius - 2) * sin(angle)
            let xInner = center.x + (radius - 2 - tickLen) * cos(angle)
            let yInner = center.y + (radius - 2 - tickLen) * sin(angle)

            context.setStrokeColor(tickColor)
            context.setLineWidth(tickWidth)
            context.strokeLineSegments(between: [CGPoint(x: xInner, y: yInner), CGPoint(x: xOuter, y: yOuter)])
        }

        // 3. Second Ring (Inner Bezel)
        let innerRadius = radius * 0.86

        // Solid lens barrel interior backing for pristine emblem clarity
        context.setFillColor(CinemaPalette.obsidianDark)
        context.fillEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))

        context.setStrokeColor(primaryColor)
        context.setLineWidth(1.75)
        context.strokeEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))

        // Third Hairline Ring
        let thirdRadius = radius * 0.82
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.30))
        context.setLineWidth(0.75)
        context.strokeEllipse(in: CGRect(x: center.x - thirdRadius, y: center.y - thirdRadius, width: thirdRadius * 2, height: thirdRadius * 2))

        // 4. Optical Aperture Iris Blades (8 precision geometric blades)
        let bladeInnerRadius = radius * 0.40
        let bladeOuterRadius = radius * 0.78
        let bladeCount = 8

        context.saveGState()
        for i in 0..<bladeCount {
            let angle = CGFloat(i) * (2.0 * .pi / CGFloat(bladeCount)) + (.pi / 8.0)

            let pStart = CGPoint(
                x: center.x + bladeInnerRadius * cos(angle),
                y: center.y + bladeInnerRadius * sin(angle)
            )
            let pEnd = CGPoint(
                x: center.x + bladeOuterRadius * cos(angle + .pi / 4.0),
                y: center.y + bladeOuterRadius * sin(angle + .pi / 4.0)
            )

            // Blade line
            context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.40))
            context.setLineWidth(1.0)
            context.strokeLineSegments(between: [pStart, pEnd])

            // Delicate blade fill shading
            let bladePath = CGMutablePath()
            bladePath.move(to: pStart)
            bladePath.addLine(to: pEnd)
            let pArc = CGPoint(
                x: center.x + bladeOuterRadius * cos(angle + .pi / 3.0),
                y: center.y + bladeOuterRadius * sin(angle + .pi / 3.0)
            )
            bladePath.addLine(to: pArc)
            bladePath.closeSubpath()
            context.setFillColor(CinemaPalette.color(212, 175, 55, 0.035))
            context.addPath(bladePath)
            context.fillPath()
        }
        context.restoreGState()

        // 5. Central Anamorphic Film Gate (2.39:1 aspect ratio golden rectangle)
        let gateHeight = radius * 0.44
        let gateWidth = gateHeight * 2.39
        let gateRect = CGRect(
            x: center.x - gateWidth / 2.0,
            y: center.y - gateHeight / 2.0,
            width: gateWidth,
            height: gateHeight
        )

        // Solid dark fill for the anamorphic gate
        context.setFillColor(CinemaPalette.obsidianVoid)
        context.fill(gateRect)

        // Golden frame outline
        context.setStrokeColor(primaryColor)
        context.setLineWidth(1.5)
        context.stroke(gateRect)

        // Viewfinder corner marks on gate
        drawViewfinderBrackets(
            in: context,
            rect: gateRect.insetBy(dx: -4, dy: -4),
            cornerLength: 6,
            strokeWidth: 1.0,
            color: accentColor
        )

        // 6. Monogram inside the Anamorphic Gate
        if drawMonogram {
            let monoFont = TypographyEngine.serifFont(size: radius * 0.28, weight: .bold)
            let ampFont = NSFont(name: "Baskerville-Italic", size: radius * 0.24) ??
                          NSFont(name: "Georgia-Italic", size: radius * 0.24) ??
                          TypographyEngine.serifFont(size: radius * 0.24)

            // Letter "К"
            _ = TypographyEngine.drawText(
                "К",
                in: context,
                point: CGPoint(x: center.x - gateWidth * 0.26, y: center.y),
                font: monoFont,
                color: CinemaPalette.warmIvory,
                tracking: 0,
                alignment: .center
            )

            // Ampersand "&"
            _ = TypographyEngine.drawText(
                "&",
                in: context,
                point: CGPoint(x: center.x, y: center.y - 1),
                font: ampFont,
                color: primaryColor,
                tracking: 0,
                alignment: .center
            )

            // Letter "С"
            _ = TypographyEngine.drawText(
                "С",
                in: context,
                point: CGPoint(x: center.x + gateWidth * 0.26, y: center.y),
                font: monoFont,
                color: CinemaPalette.warmIvory,
                tracking: 0,
                alignment: .center
            )
        } else {
            drawCrosshair(
                in: context,
                center: center,
                size: radius * 0.30,
                gap: radius * 0.08,
                strokeWidth: 1.5,
                color: accentColor
            )
            context.setFillColor(primaryColor)
            context.fillEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
        }

        context.restoreGState()
    }

    /// Draws authentic 35mm film perforations (sprocket holes)
    static func drawFilmPerforations(
        in context: CGContext,
        rect: CGRect,
        isVertical: Bool = true,
        pitch: CGFloat = 36.0,
        holeWidth: CGFloat = 18.0,
        holeHeight: CGFloat = 26.0,
        holeCornerRadius: CGFloat = 4.0,
        color: CGColor
    ) {
        context.saveGState()
        context.setFillColor(color)

        if isVertical {
            var currentY = rect.minY + (pitch - holeHeight) / 2.0
            while currentY + holeHeight <= rect.maxY {
                let holeRect = CGRect(
                    x: rect.midX - holeWidth / 2.0,
                    y: currentY,
                    width: holeWidth,
                    height: holeHeight
                )
                let path = CGPath(roundedRect: holeRect, cornerWidth: holeCornerRadius, cornerHeight: holeCornerRadius, transform: nil)
                context.addPath(path)
                context.fillPath()
                currentY += pitch
            }
        }
        context.restoreGState()
    }

    /// Draws silky ethereal anamorphic optical flare (NO harsh rectangular clipping)
    static func drawAnamorphicStreak(
        in context: CGContext,
        flareCenter: CGPoint,
        streakWidth: CGFloat,
        colorSpace: CGColorSpace
    ) {
        context.saveGState()
        context.setBlendMode(.screen)

        // 1. Central warm golden/cyan bloom aura
        let bloomColors = [
            CinemaPalette.color(240, 215, 140, 0.28),
            CinemaPalette.color(80, 160, 220, 0.12),
            CinemaPalette.color(10, 12, 16, 0.0)
        ] as CFArray
        let bloomLocations: [CGFloat] = [0.0, 0.40, 1.0]
        if let bloomGrad = CGGradient(colorsSpace: colorSpace, colors: bloomColors, locations: bloomLocations) {
            context.saveGState()
            context.translateBy(x: flareCenter.x, y: flareCenter.y)
            context.scaleBy(x: 1.0, y: 0.35)
            context.drawRadialGradient(
                bloomGrad,
                startCenter: .zero,
                startRadius: 0,
                endCenter: .zero,
                endRadius: streakWidth * 0.20,
                options: []
            )
            context.restoreGState()
        }

        // 2. Silky horizontal hairline streak with smooth gradient
        let flareColors = [
            CinemaPalette.color(70, 150, 210, 0.0),
            CinemaPalette.color(70, 150, 210, 0.18),
            CinemaPalette.color(240, 215, 140, 0.55),
            CinemaPalette.color(255, 255, 255, 0.85),
            CinemaPalette.color(240, 215, 140, 0.55),
            CinemaPalette.color(70, 150, 210, 0.18),
            CinemaPalette.color(70, 150, 210, 0.0)
        ] as CFArray
        let flareLocations: [CGFloat] = [0.0, 0.25, 0.46, 0.5, 0.54, 0.75, 1.0]

        if let grad = CGGradient(colorsSpace: colorSpace, colors: flareColors, locations: flareLocations) {
            // Soft wide aura line (height 4px)
            context.saveGState()
            let softRect = CGRect(
                x: flareCenter.x - streakWidth / 2.0,
                y: flareCenter.y - 2,
                width: streakWidth,
                height: 4
            )
            context.clip(to: softRect)
            context.drawLinearGradient(
                grad,
                start: CGPoint(x: softRect.minX, y: flareCenter.y),
                end: CGPoint(x: softRect.maxX, y: flareCenter.y),
                options: []
            )
            context.restoreGState()

            // Razor sharp optical core (height 1.2px)
            context.saveGState()
            let coreRect = CGRect(
                x: flareCenter.x - streakWidth * 0.4,
                y: flareCenter.y - 0.6,
                width: streakWidth * 0.8,
                height: 1.2
            )
            context.clip(to: coreRect)
            context.drawLinearGradient(
                grad,
                start: CGPoint(x: coreRect.minX, y: flareCenter.y),
                end: CGPoint(x: coreRect.maxX, y: flareCenter.y),
                options: []
            )
            context.restoreGState()
        }

        context.restoreGState()
    }

    /// Draws a precision vector clapperboard icon
    static func drawClapperIcon(in context: CGContext, center: CGPoint, size: CGFloat, color: CGColor) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(1.0)

        let w = size
        let h = size * 0.78
        let x = center.x - w / 2.0
        let y = center.y - h / 2.0

        // Clapper body
        let bodyRect = CGRect(x: x, y: y, width: w, height: h * 0.62)
        context.stroke(bodyRect)

        // Top slate bar
        let topBarRect = CGRect(x: x, y: y + h * 0.62 + 1, width: w, height: h * 0.36)
        context.stroke(topBarRect)

        // Diagonal stripes on top bar
        let stripeCount = 3
        for i in 1...stripeCount {
            let sx = x + CGFloat(i) * (w / CGFloat(stripeCount + 1))
            context.strokeLineSegments(between: [
                CGPoint(x: sx - 2, y: y + h * 0.62 + 1),
                CGPoint(x: sx + 2, y: y + h)
            ])
        }

        context.restoreGState()
    }

    /// Draws a precision vector paper airplane / telegram icon
    static func drawTelegramIcon(in context: CGContext, center: CGPoint, size: CGFloat, color: CGColor) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(1.0)
        context.setLineJoin(.round)

        let s = size
        let x = center.x - s / 2.0
        let y = center.y - s / 2.0

        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y + s * 0.45))
        path.addLine(to: CGPoint(x: x + s, y: y + s))
        path.addLine(to: CGPoint(x: x + s * 0.4, y: y))
        path.addLine(to: CGPoint(x: x + s * 0.35, y: y + s * 0.42))
        path.addLine(to: CGPoint(x: x + s * 0.75, y: y + s * 0.75))
        path.closeSubpath()

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}
