import Cocoa
import CoreGraphics
import CoreText
import ImageIO

// MARK: - AssetRenderer Protocol (Open/Closed & Liskov Substitution)
protocol AssetRenderer {
    var size: CGSize { get }
    var outputName: String { get }
    func render(in context: CGContext, colorSpace: CGColorSpace)
}

// MARK: - 1. Square Avatar Renderer (800 x 800)
struct AvatarSquareRenderer: AssetRenderer {
    let size = CGSize(width: 800, height: 800)
    let outputName = "avatar_square"

    func render(in context: CGContext, colorSpace: CGColorSpace) {
        let bounds = CGRect(origin: .zero, size: size)

        // 1. Deep Obsidian Radial Background
        if let bgGrad = CinemaPalette.subtleRadialBgGradient(in: colorSpace) {
            context.drawRadialGradient(
                bgGrad,
                startCenter: CGPoint(x: 400, y: 440),
                startRadius: 0,
                endCenter: CGPoint(x: 400, y: 440),
                endRadius: 580,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // 2. Silky Anamorphic horizontal optical flare (centered through emblem)
        CinemaGraphics.drawAnamorphicStreak(
            in: context,
            flareCenter: CGPoint(x: 400, y: 475),
            streakWidth: 740,
            colorSpace: colorSpace
        )

        // 3. Viewfinder Outer Brackets & Frame Guides
        let frameRect = bounds.insetBy(dx: 44, dy: 44)
        CinemaGraphics.drawViewfinderBrackets(
            in: context,
            rect: frameRect,
            cornerLength: 44,
            strokeWidth: 1.75,
            color: CinemaPalette.champagneGold
        )

        // Framing hairline grid
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.12))
        context.setLineWidth(0.75)
        context.stroke(frameRect.insetBy(dx: 12, dy: 12))

        // Center crosshairs near edge
        CinemaGraphics.drawCrosshair(in: context, center: CGPoint(x: frameRect.midX, y: frameRect.minY + 12), size: 14, gap: 4, strokeWidth: 1.0, color: CinemaPalette.champagneGold)
        CinemaGraphics.drawCrosshair(in: context, center: CGPoint(x: frameRect.midX, y: frameRect.maxY - 12), size: 14, gap: 4, strokeWidth: 1.0, color: CinemaPalette.champagneGold)
        CinemaGraphics.drawCrosshair(in: context, center: CGPoint(x: frameRect.minX + 12, y: frameRect.midY), size: 14, gap: 4, strokeWidth: 1.0, color: CinemaPalette.champagneGold)
        CinemaGraphics.drawCrosshair(in: context, center: CGPoint(x: frameRect.maxX - 12, y: frameRect.midY), size: 14, gap: 4, strokeWidth: 1.0, color: CinemaPalette.champagneGold)

        // 4. Header Technical Metadata
        // Left: REC [ ● ]
        context.setFillColor(CinemaPalette.recRed)
        context.fillEllipse(in: CGRect(x: 82, y: 728, width: 8, height: 8))
        _ = TypographyEngine.drawText(
            "REC",
            in: context,
            point: CGPoint(x: 114, y: 732),
            font: TypographyEngine.grotesqueFont(size: 11, weight: .bold),
            color: CinemaPalette.warmIvory,
            tracking: 2.0,
            alignment: .left
        )

        // Center Top: 2.39:1 • 35MM
        _ = TypographyEngine.drawText(
            "2.39:1  •  35MM  •  24 FPS",
            in: context,
            point: CGPoint(x: 400, y: 732),
            font: TypographyEngine.grotesqueFont(size: 10.5, weight: .medium),
            color: CinemaPalette.champagneLight,
            tracking: 3.5,
            alignment: .center
        )

        // Right Top: 4K UHD
        _ = TypographyEngine.drawText(
            "4K UHD",
            in: context,
            point: CGPoint(x: 718, y: 732),
            font: TypographyEngine.grotesqueFont(size: 11, weight: .bold),
            color: CinemaPalette.color(212, 175, 55, 0.75),
            tracking: 2.0,
            alignment: .right
        )

        // 5. Signature Cinema Aperture Emblem
        CinemaGraphics.drawCinemaLensEmblem(
            in: context,
            center: CGPoint(x: 400, y: 475),
            radius: 145,
            primaryColor: CinemaPalette.champagneGold,
            secondaryColor: CinemaPalette.champagneLight,
            accentColor: CinemaPalette.champagnePale,
            drawMonogram: true
        )

        // 6. Master Editorial Typography Stack
        // Main Title: «КАДР & СЕНС» with ivory text & gold ampersand
        let titleY: CGFloat = 262
        _ = TypographyEngine.drawBrandTitle(
            in: context,
            center: CGPoint(x: 400, y: titleY),
            fontSize: 52,
            tracking: 7.0
        )

        // Decorative hairline separator with diamond
        let sepY: CGFloat = 216
        let sepWidth: CGFloat = 260
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.40))
        context.setLineWidth(1.0)
        context.strokeLineSegments(between: [
            CGPoint(x: 400 - sepWidth / 2.0, y: sepY),
            CGPoint(x: 400 - 16, y: sepY)
        ])
        context.strokeLineSegments(between: [
            CGPoint(x: 400 + 16, y: sepY),
            CGPoint(x: 400 + sepWidth / 2.0, y: sepY)
        ])

        // Central diamond accent
        context.saveGState()
        context.setFillColor(CinemaPalette.champagneGold)
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: 400, y: sepY + 4))
        diamond.addLine(to: CGPoint(x: 400 + 4, y: sepY))
        diamond.addLine(to: CGPoint(x: 400, y: sepY - 4))
        diamond.addLine(to: CGPoint(x: 400 - 4, y: sepY))
        diamond.closeSubpath()
        context.addPath(diamond)
        context.fillPath()
        context.restoreGState()

        // Tagline: «АНАТОМІЯ КУЛЬТОВОГО КІНО»
        _ = TypographyEngine.drawText(
            "АНАТОМІЯ КУЛЬТОВОГО КІНО",
            in: context,
            point: CGPoint(x: 400, y: 184),
            font: TypographyEngine.grotesqueFont(size: 15.5, weight: .bold),
            color: CinemaPalette.champagneLight,
            tracking: 4.5,
            alignment: .center
        )

        // Slogan: «ВІДЕОЕСЕ • ДІАЛОГИ»
        _ = TypographyEngine.drawText(
            "ВІДЕОЕСЕ  •  ДІАЛОГИ",
            in: context,
            point: CGPoint(x: 400, y: 144),
            font: TypographyEngine.grotesqueFont(size: 13, weight: .medium),
            color: CinemaPalette.color(250, 247, 242, 0.75),
            tracking: 3.5,
            alignment: .center
        )

        // Bottom Footer: AUTEUR CINEMA ESSAYS
        _ = TypographyEngine.drawText(
            "AUTEUR CINEMA CLUB  •  UKRAINIAN ESSAYS",
            in: context,
            point: CGPoint(x: 400, y: 72),
            font: TypographyEngine.grotesqueFont(size: 9.5, weight: .light),
            color: CinemaPalette.color(212, 175, 55, 0.45),
            tracking: 3.0,
            alignment: .center
        )
    }
}

// MARK: - 2. YouTube Banner Renderer (2560 x 1440)
struct YouTubeBannerRenderer: AssetRenderer {
    let size = CGSize(width: 2560, height: 1440)
    let outputName = "youtube_banner"

    func render(in context: CGContext, colorSpace: CGColorSpace) {
        let bounds = CGRect(origin: .zero, size: size)

        // Safe Area Specifications
        // Mobile & Universal Safe Area: 1546 x 423 px centered at (1280, 720)
        let safeArea = CGRect(x: 507, y: 508.5, width: 1546, height: 423)

        // 1. Full Canvas Background: Deep Obsidian with atmospheric glow
        if let bgGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CinemaPalette.color(24, 27, 36),
                CinemaPalette.obsidianSlate,
                CinemaPalette.obsidianDark,
                CinemaPalette.obsidianVoid
            ] as CFArray,
            locations: [0.0, 0.35, 0.7, 1.0]
        ) {
            context.drawRadialGradient(
                bgGrad,
                startCenter: CGPoint(x: 1280, y: 720),
                startRadius: 0,
                endCenter: CGPoint(x: 1280, y: 720),
                endRadius: 1400,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // 2. Cinematic 35mm Film Sprockets on Far Left and Far Right
        // Left sprocket rail (x: 40..100)
        CinemaGraphics.drawFilmPerforations(
            in: context,
            rect: CGRect(x: 50, y: 0, width: 50, height: 1440),
            isVertical: true,
            pitch: 48.0,
            holeWidth: 24.0,
            holeHeight: 34.0,
            holeCornerRadius: 5.0,
            color: CinemaPalette.color(212, 175, 55, 0.18)
        )
        // Right sprocket rail (x: 2460..2520)
        CinemaGraphics.drawFilmPerforations(
            in: context,
            rect: CGRect(x: 2460, y: 0, width: 50, height: 1440),
            isVertical: true,
            pitch: 48.0,
            holeWidth: 24.0,
            holeHeight: 34.0,
            holeCornerRadius: 5.0,
            color: CinemaPalette.color(212, 175, 55, 0.18)
        )

        // Authentic Kodak 35mm Film Edge Print (Running VERTICALLY next to sprockets)
        context.saveGState()
        let edgeText = "EASTMAN 5219  •  23 1488 + 04  •  KODAK VISION3 500T  •  KADR & SENS CINEMA ARCHIVE"

        // Left vertical edge text
        context.saveGState()
        context.translateBy(x: 125, y: 720)
        context.rotate(by: .pi / 2.0)
        _ = TypographyEngine.drawText(
            edgeText,
            in: context,
            point: .zero,
            font: TypographyEngine.grotesqueFont(size: 11, weight: .light),
            color: CinemaPalette.color(212, 175, 55, 0.28),
            tracking: 3.5,
            alignment: .center
        )
        context.restoreGState()

        // Right vertical edge text
        context.saveGState()
        context.translateBy(x: 2435, y: 720)
        context.rotate(by: -.pi / 2.0)
        _ = TypographyEngine.drawText(
            edgeText,
            in: context,
            point: .zero,
            font: TypographyEngine.grotesqueFont(size: 11, weight: .light),
            color: CinemaPalette.color(212, 175, 55, 0.28),
            tracking: 3.5,
            alignment: .center
        )
        context.restoreGState()
        context.restoreGState()

        // 3. Cinematic 2.39:1 Letterbox Widescreen Gate Lines (across canvas)
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.15))
        context.setLineWidth(1.0)
        context.strokeLineSegments(between: [CGPoint(x: 0, y: 1240), CGPoint(x: 2560, y: 1240)])
        context.strokeLineSegments(between: [CGPoint(x: 0, y: 200), CGPoint(x: 2560, y: 200)])

        // TV Outer Area Guides & Metadata (Top & Bottom)
        _ = TypographyEngine.drawText(
            "•  AUTEUR CINEMA VIDEO ESSAYS  •  ANATOMY OF CULT CINEMA  •  PHILOSOPHY & AESTHETICS  •  CINEPHILE ARCHIVE  •",
            in: context,
            point: CGPoint(x: 1280, y: 1280),
            font: TypographyEngine.grotesqueFont(size: 12, weight: .medium),
            color: CinemaPalette.color(212, 175, 55, 0.35),
            tracking: 4.0,
            alignment: .center
        )

        _ = TypographyEngine.drawText(
            "•  ASPECT RATIO 2.39:1  •  35MM ANAMORPHIC  •  CINEPHILE CLUB UKRAINE  •",
            in: context,
            point: CGPoint(x: 1280, y: 160),
            font: TypographyEngine.grotesqueFont(size: 12, weight: .medium),
            color: CinemaPalette.color(212, 175, 55, 0.35),
            tracking: 4.0,
            alignment: .center
        )

        // 4. Silky Anamorphic Horizontal Lens Flare (centered at Y = 785 through emblem)
        CinemaGraphics.drawAnamorphicStreak(
            in: context,
            flareCenter: CGPoint(x: 1280, y: 785),
            streakWidth: 2200,
            colorSpace: colorSpace
        )

        // 5. STRICT SAFE AREA COMPOSITION (All critical elements inside safeArea)
        // Safe Area Viewfinder Corner Brackets
        CinemaGraphics.drawViewfinderBrackets(
            in: context,
            rect: safeArea.insetBy(dx: 12, dy: 10),
            cornerLength: 32,
            strokeWidth: 1.5,
            color: CinemaPalette.color(212, 175, 55, 0.55)
        )

        // Safe Area Top Technical Bar (Y = 888)
        // REC [ ● ]
        context.setFillColor(CinemaPalette.recRed)
        context.fillEllipse(in: CGRect(x: safeArea.minX + 40, y: 884, width: 9, height: 9))
        _ = TypographyEngine.drawText(
            "REC",
            in: context,
            point: CGPoint(x: safeArea.minX + 76, y: 888),
            font: TypographyEngine.grotesqueFont(size: 12, weight: .bold),
            color: CinemaPalette.warmIvory,
            tracking: 2.0,
            alignment: .left
        )

        // Technical specs center top
        _ = TypographyEngine.drawText(
            "2.39:1 ANAMORPHIC  •  35MM KODAK VISION3  •  24 FPS  •  4K UHD",
            in: context,
            point: CGPoint(x: 1280, y: 888),
            font: TypographyEngine.grotesqueFont(size: 11, weight: .medium),
            color: CinemaPalette.champagneLight,
            tracking: 3.5,
            alignment: .center
        )

        // Right side timecode
        _ = TypographyEngine.drawText(
            "TC 01:24:19:00",
            in: context,
            point: CGPoint(x: safeArea.maxX - 40, y: 888),
            font: TypographyEngine.grotesqueFont(size: 11, weight: .bold),
            color: CinemaPalette.color(212, 175, 55, 0.7),
            tracking: 2.0,
            alignment: .right
        )

        // Center Hero Cinema Aperture Emblem
        CinemaGraphics.drawCinemaLensEmblem(
            in: context,
            center: CGPoint(x: 1280, y: 785),
            radius: 58,
            primaryColor: CinemaPalette.champagneGold,
            secondaryColor: CinemaPalette.champagneLight,
            accentColor: CinemaPalette.champagnePale,
            drawMonogram: true
        )

        // Main Title: «КАДР & СЕНС» with ivory letters & champagne gold ampersand (Y = 696)
        _ = TypographyEngine.drawBrandTitle(
            in: context,
            center: CGPoint(x: 1280, y: 696),
            fontSize: 58,
            tracking: 8.0
        )

        // Tagline: «АНАТОМІЯ КУЛЬТОВОГО КІНО» (Y = 638)
        _ = TypographyEngine.drawText(
            "АНАТОМІЯ КУЛЬТОВОГО КІНО",
            in: context,
            point: CGPoint(x: 1280, y: 638),
            font: TypographyEngine.grotesqueFont(size: 17, weight: .bold),
            color: CinemaPalette.champagneLight,
            tracking: 4.5,
            alignment: .center
        )

        // Cinematic Depth & Form Line (Y = 595)
        _ = TypographyEngine.drawText(
            "МІЗАНСЦЕНА  •  ДРАМАТУРГІЯ  •  АРХЕТИПИ  •  СИЛА КІНОМОВИ",
            in: context,
            point: CGPoint(x: 1280, y: 595),
            font: TypographyEngine.grotesqueFont(size: 12, weight: .medium),
            color: CinemaPalette.color(250, 247, 242, 0.70),
            tracking: 3.5,
            alignment: .center
        )

        // Subtitle: «ГЛИБОКІ ВІДЕОЕСЕ • КУЛЬТОВІ ДІАЛОГИ» (Y = 558)
        _ = TypographyEngine.drawText(
            "ВІДЕОЕСЕ  •  КУЛЬТОВІ ДІАЛОГИ  •  КІНОКЛУБ",
            in: context,
            point: CGPoint(x: 1280, y: 558),
            font: TypographyEngine.grotesqueFont(size: 11, weight: .light),
            color: CinemaPalette.color(212, 175, 55, 0.55),
            tracking: 3.5,
            alignment: .center
        )

        // Social Badges (INSIDE Safe Area at left and right flanks)
        // Left Badge: «🎬 НОВЕ ЕСЕ ЩОТИЖНЯ» with vector clapper icon
        let leftBadgeRect = CGRect(x: safeArea.minX + 36, y: 695, width: 242, height: 48)
        drawClapperBadge(
            in: context,
            rect: leftBadgeRect,
            text: "НОВЕ ЕСЕ ЩОТИЖНЯ"
        )

        // Right Badge: «✈️ TG: @kadr_sens» with vector telegram icon
        let rightBadgeRect = CGRect(x: safeArea.maxX - 266, y: 695, width: 230, height: 48)
        drawTelegramBadge(
            in: context,
            rect: rightBadgeRect,
            text: "TG: @kadr_sens"
        )
    }

    private func drawClapperBadge(in context: CGContext, rect: CGRect, text: String) {
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2.0, cornerHeight: rect.height / 2.0, transform: nil)

        // Glass background
        context.setFillColor(CinemaPalette.color(16, 18, 25, 0.88))
        context.addPath(path)
        context.fillPath()

        // Champagne gold border
        context.setStrokeColor(CinemaPalette.champagneGold)
        context.setLineWidth(1.2)
        context.addPath(path)
        context.strokePath()

        // Vector Clapperboard Icon
        let iconCenter = CGPoint(x: rect.minX + 28, y: rect.midY)
        CinemaGraphics.drawClapperIcon(in: context, center: iconCenter, size: 16, color: CinemaPalette.champagneLight)

        // Text
        _ = TypographyEngine.drawText(
            text,
            in: context,
            point: CGPoint(x: rect.minX + 130, y: rect.midY),
            font: TypographyEngine.grotesqueFont(size: 12.5, weight: .bold),
            color: CinemaPalette.warmIvory,
            tracking: 1.5,
            alignment: .center
        )
        context.restoreGState()
    }

    private func drawTelegramBadge(in context: CGContext, rect: CGRect, text: String) {
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2.0, cornerHeight: rect.height / 2.0, transform: nil)

        // Glass background
        context.setFillColor(CinemaPalette.color(16, 18, 25, 0.88))
        context.addPath(path)
        context.fillPath()

        // Champagne gold border
        context.setStrokeColor(CinemaPalette.champagneGold)
        context.setLineWidth(1.2)
        context.addPath(path)
        context.strokePath()

        // Vector Telegram Airplane Icon
        let iconCenter = CGPoint(x: rect.minX + 28, y: rect.midY)
        CinemaGraphics.drawTelegramIcon(in: context, center: iconCenter, size: 16, color: CinemaPalette.champagneLight)

        // Text
        _ = TypographyEngine.drawText(
            text,
            in: context,
            point: CGPoint(x: rect.minX + 124, y: rect.midY),
            font: TypographyEngine.grotesqueFont(size: 13, weight: .bold),
            color: CinemaPalette.warmIvory,
            tracking: 1.5,
            alignment: .center
        )
        context.restoreGState()
    }
}

// MARK: - 3. Watermark Square Renderer (500 x 500, Transparent PNG)
struct WatermarkSquareRenderer: AssetRenderer {
    let size = CGSize(width: 500, height: 500)
    let outputName = "watermark_square_youtube"

    func render(in context: CGContext, colorSpace: CGColorSpace) {
        // High contrast transparent overlay
        // 1. Semi-translucent dark slate backing plate with rounded corners
        let plateRect = CGRect(x: 20, y: 20, width: 460, height: 460)
        let platePath = CGPath(roundedRect: plateRect, cornerWidth: 32, cornerHeight: 32, transform: nil)

        // Frosted dark glass fill
        context.setFillColor(CinemaPalette.color(11, 12, 16, 0.90))
        context.addPath(platePath)
        context.fillPath()

        // Golden perimeter border
        context.setStrokeColor(CinemaPalette.champagneGold)
        context.setLineWidth(2.0)
        context.addPath(platePath)
        context.strokePath()

        // Inner subtle border
        let innerPlatePath = CGPath(roundedRect: plateRect.insetBy(dx: 8, dy: 8), cornerWidth: 26, cornerHeight: 26, transform: nil)
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.35))
        context.setLineWidth(0.75)
        context.addPath(innerPlatePath)
        context.strokePath()

        // Corner brackets inside plate
        CinemaGraphics.drawViewfinderBrackets(
            in: context,
            rect: plateRect.insetBy(dx: 16, dy: 16),
            cornerLength: 20,
            strokeWidth: 1.25,
            color: CinemaPalette.champagneLight
        )

        // 2. Cinema Lens Aperture Emblem
        CinemaGraphics.drawCinemaLensEmblem(
            in: context,
            center: CGPoint(x: 250, y: 310),
            radius: 88,
            primaryColor: CinemaPalette.champagneGold,
            secondaryColor: CinemaPalette.champagneLight,
            accentColor: CinemaPalette.champagnePale,
            drawMonogram: true
        )

        // 3. Title: «КАДР & СЕНС» with ivory letters and gold ampersand
        _ = TypographyEngine.drawBrandTitle(
            in: context,
            center: CGPoint(x: 250, y: 178),
            fontSize: 32,
            tracking: 5.0
        )

        // 4. Prominent High-Contrast Call to Action: «ПІДПИШИСЬ»
        let buttonRect = CGRect(x: 65, y: 60, width: 370, height: 64)
        let buttonPath = CGPath(roundedRect: buttonRect, cornerWidth: buttonRect.height / 2.0, cornerHeight: buttonRect.height / 2.0, transform: nil)

        // Button background: rich champagne gold gradient
        if let goldGrad = CinemaPalette.goldGradient(in: colorSpace) {
            context.saveGState()
            context.addPath(buttonPath)
            context.clip()
            context.drawLinearGradient(
                goldGrad,
                start: CGPoint(x: buttonRect.minX, y: buttonRect.minY),
                end: CGPoint(x: buttonRect.maxX, y: buttonRect.maxY),
                options: []
            )
            context.restoreGState()
        }

        // Button golden rim
        context.setStrokeColor(CinemaPalette.pureWhite)
        context.setLineWidth(1.0)
        context.addPath(buttonPath)
        context.strokePath()

        // Button Text: «▶ ПІДПИШИСЬ»
        _ = TypographyEngine.drawText(
            "▶  ПІДПИШИСЬ",
            in: context,
            point: CGPoint(x: buttonRect.midX, y: buttonRect.midY),
            font: TypographyEngine.grotesqueFont(size: 21, weight: .bold),
            color: CinemaPalette.obsidianVoid,
            tracking: 3.0,
            alignment: .center
        )
    }
}

// MARK: - 4. Telegram Avatar Renderer (800 x 800)
struct AvatarTelegramRenderer: AssetRenderer {
    let size = CGSize(width: 800, height: 800)
    let outputName = "avatar_telegram"

    func render(in context: CGContext, colorSpace: CGColorSpace) {
        let center = CGPoint(x: 400, y: 400)

        // 1. Full Obsidian Radial Background
        if let bgGrad = CinemaPalette.subtleRadialBgGradient(in: colorSpace) {
            context.drawRadialGradient(
                bgGrad,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: 560,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // 2. Telegram Circular Framing System (radius <= 385px, safely within 400px circle)
        // Outer Master Gold Bezel
        let outerRadius: CGFloat = 380
        context.setStrokeColor(CinemaPalette.champagneGold)
        context.setLineWidth(3.5)
        context.strokeEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))

        // Inner Hairline Ring with radial lens ticks
        let tickRingRadius: CGFloat = 366
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.45))
        context.setLineWidth(1.0)
        context.strokeEllipse(in: CGRect(x: center.x - tickRingRadius, y: center.y - tickRingRadius, width: tickRingRadius * 2, height: tickRingRadius * 2))

        // Calibrated Ticks between tickRingRadius and outerRadius (48 ticks around circle)
        for i in 0..<48 {
            let angle = CGFloat(i) * (2.0 * .pi / 48.0)
            let isMajor = (i % 12 == 0)
            let isMedium = (i % 4 == 0)

            let rStart = isMajor ? outerRadius - 16 : (isMedium ? outerRadius - 12 : outerRadius - 8)
            let p1 = CGPoint(x: center.x + rStart * cos(angle), y: center.y + rStart * sin(angle))
            let p2 = CGPoint(x: center.x + (outerRadius - 2) * cos(angle), y: center.y + (outerRadius - 2) * sin(angle))

            context.setStrokeColor(isMajor ? CinemaPalette.champagneGold : CinemaPalette.color(212, 175, 55, 0.5))
            context.setLineWidth(isMajor ? 1.75 : (isMedium ? 1.2 : 0.7))
            context.strokeLineSegments(between: [p1, p2])
        }

        // Third Delicate Concentric Ring
        let thirdRingRadius: CGFloat = 348
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.20))
        context.setLineWidth(0.75)
        context.strokeEllipse(in: CGRect(x: center.x - thirdRingRadius, y: center.y - thirdRingRadius, width: thirdRingRadius * 2, height: thirdRingRadius * 2))

        // Silky anamorphic horizontal flare through center
        CinemaGraphics.drawAnamorphicStreak(
            in: context,
            flareCenter: CGPoint(x: 400, y: 465),
            streakWidth: 680,
            colorSpace: colorSpace
        )

        // 3. Top Arc / Label: «• КІНОКЛУБ • EST. 2026 •»
        _ = TypographyEngine.drawText(
            "•  КІНОКЛУБ  •  EST. 2026  •",
            in: context,
            point: CGPoint(x: 400, y: 690),
            font: TypographyEngine.grotesqueFont(size: 13.5, weight: .bold),
            color: CinemaPalette.champagneLight,
            tracking: 4.5,
            alignment: .center
        )

        // 4. Master Cinema Aperture Emblem
        CinemaGraphics.drawCinemaLensEmblem(
            in: context,
            center: CGPoint(x: 400, y: 465),
            radius: 148,
            primaryColor: CinemaPalette.champagneGold,
            secondaryColor: CinemaPalette.champagneLight,
            accentColor: CinemaPalette.champagnePale,
            drawMonogram: true
        )

        // 5. Typography
        // Main Title: «КАДР & СЕНС» with ivory letters & champagne gold ampersand
        _ = TypographyEngine.drawBrandTitle(
            in: context,
            center: CGPoint(x: 400, y: 255),
            fontSize: 50,
            tracking: 7.0
        )

        // Decorative hairline separator
        let sepY: CGFloat = 208
        let sepWidth: CGFloat = 220
        context.setStrokeColor(CinemaPalette.color(212, 175, 55, 0.40))
        context.setLineWidth(1.0)
        context.strokeLineSegments(between: [
            CGPoint(x: 400 - sepWidth / 2.0, y: sepY),
            CGPoint(x: 400 - 14, y: sepY)
        ])
        context.strokeLineSegments(between: [
            CGPoint(x: 400 + 14, y: sepY),
            CGPoint(x: 400 + sepWidth / 2.0, y: sepY)
        ])

        // Central diamond accent
        context.saveGState()
        context.setFillColor(CinemaPalette.champagneGold)
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: 400, y: sepY + 3.5))
        diamond.addLine(to: CGPoint(x: 400 + 3.5, y: sepY))
        diamond.addLine(to: CGPoint(x: 400, y: sepY - 3.5))
        diamond.addLine(to: CGPoint(x: 400 - 3.5, y: sepY))
        diamond.closeSubpath()
        context.addPath(diamond)
        context.fillPath()
        context.restoreGState()

        // Tagline: «АНАТОМІЯ КУЛЬТОВОГО КІНО»
        _ = TypographyEngine.drawText(
            "АНАТОМІЯ КУЛЬТОВОГО КІНО",
            in: context,
            point: CGPoint(x: 400, y: 178),
            font: TypographyEngine.grotesqueFont(size: 15, weight: .bold),
            color: CinemaPalette.champagneLight,
            tracking: 4.0,
            alignment: .center
        )

        // Community subtitle: «ДИСКУСІЇ • ЕСЕ • ПІДБІРКИ»
        _ = TypographyEngine.drawText(
            "ДИСКУСІЇ  •  ЕСЕ  •  ПІДБІРКИ",
            in: context,
            point: CGPoint(x: 400, y: 138),
            font: TypographyEngine.grotesqueFont(size: 12, weight: .medium),
            color: CinemaPalette.color(250, 247, 242, 0.70),
            tracking: 3.5,
            alignment: .center
        )
    }
}
