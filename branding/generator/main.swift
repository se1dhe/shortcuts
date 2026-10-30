import Cocoa
import CoreGraphics
import CoreText
import ImageIO

struct ImageExporter {
    static func export(
        cgImage: CGImage,
        to url: URL,
        format: CFString,
        quality: CGFloat = 1.0
    ) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format, 1, nil) else {
            print("❌ Failed to create CGImageDestination for \(url.path)")
            return false
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        if CGImageDestinationFinalize(destination) {
            print("✅ Successfully exported \(url.lastPathComponent) (\(cgImage.width)x\(cgImage.height))")
            return true
        } else {
            print("❌ Failed to finalize image destination for \(url.path)")
            return false
        }
    }
}

func main() {
    print("🎬 Starting Cinema Branding Generation for «Кадр & Сенс»...")

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        fatalError("Failed to create sRGB color space")
    }

    let basePath = "/Users/se1dhe/Desktop/каналы"
    let dir01 = URL(fileURLWithPath: "\(basePath)/01_cinema_kadr_sens/branding")
    let dir02 = URL(fileURLWithPath: "\(basePath)/02_cinema_telegram/branding")

    try? FileManager.default.createDirectory(at: dir01, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: dir02, withIntermediateDirectories: true)

    // Helper to render an asset
    func renderAsset(_ renderer: AssetRenderer, hasAlpha: Bool = false) -> CGImage? {
        let width = Int(renderer.size.width)
        let height = Int(renderer.size.height)
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .premultipliedLast

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            print("Failed to create context for \(renderer.outputName)")
            return nil
        }

        // Enable high quality rendering
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        // Render asset
        renderer.render(in: context, colorSpace: colorSpace)

        return context.makeImage()
    }

    // 1. Avatar Square (YouTube & TikTok)
    print("\n[1/4] Rendering Avatar Square (800x800)...")
    let avatarRenderer = AvatarSquareRenderer()
    if let img = renderAsset(avatarRenderer) {
        let pngUrl = dir01.appendingPathComponent("avatar_square.png")
        let jpgUrl = dir01.appendingPathComponent("avatar_square.jpg")
        _ = ImageExporter.export(cgImage: img, to: pngUrl, format: kUTTypePNG)
        _ = ImageExporter.export(cgImage: img, to: jpgUrl, format: kUTTypeJPEG, quality: 0.98)
    }

    // 2. YouTube Banner (2560x1440)
    print("\n[2/4] Rendering YouTube Banner (2560x1440)...")
    let bannerRenderer = YouTubeBannerRenderer()
    if let img = renderAsset(bannerRenderer) {
        let pngUrl = dir01.appendingPathComponent("youtube_banner.png")
        let jpgUrl = dir01.appendingPathComponent("youtube_banner.jpg")
        _ = ImageExporter.export(cgImage: img, to: pngUrl, format: kUTTypePNG)
        _ = ImageExporter.export(cgImage: img, to: jpgUrl, format: kUTTypeJPEG, quality: 0.98)
    }

    // 3. YouTube Watermark Square (500x500 Transparent)
    print("\n[3/4] Rendering YouTube Watermark (500x500 Transparent)...")
    let watermarkRenderer = WatermarkSquareRenderer()
    if let img = renderAsset(watermarkRenderer, hasAlpha: true) {
        let pngUrl = dir01.appendingPathComponent("watermark_square_youtube.png")
        _ = ImageExporter.export(cgImage: img, to: pngUrl, format: kUTTypePNG)
    }

    // 4. Telegram Avatar (800x800 Circular Crop Optimized)
    print("\n[4/4] Rendering Telegram Avatar (800x800)...")
    let telegramRenderer = AvatarTelegramRenderer()
    if let img = renderAsset(telegramRenderer) {
        let pngUrl = dir02.appendingPathComponent("avatar_telegram.png")
        let jpgUrl = dir02.appendingPathComponent("avatar_telegram.jpg")
        _ = ImageExporter.export(cgImage: img, to: pngUrl, format: kUTTypePNG)
        _ = ImageExporter.export(cgImage: img, to: jpgUrl, format: kUTTypeJPEG, quality: 0.98)
    }

    print("\n🎉 All branding assets rendered successfully!")
}

main()
