import AppKit

/// The same JetBrains Mono face used by BLACKFORGE's monospace typography.
enum ShortsWatermark {
    static let version = 2
    static let text = "@telonyx_cinema"
    static let frameRate = 10
    static let opacity = 0.5
    static let canvas = CGSize(width: 640, height: 90)
    // Stay above TikTok's caption/navigation area while keeping the mark in the lower band.
    static let bottomInset = 240
    static let filter = "[0:v]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,setsar=1[base];[base][1:v]overlay=(W-w)/2:H-h-\(bottomInset):format=auto:eof_action=repeat[v]"

    static var frameCount: Int { text.count + 1 }

    /// Each character arrives on a frame; the last frame is held for the entire remaining clip.
    @MainActor static func writeFrames(in directory: URL) throws -> URL {
        FontDownloadService.shared.registerBundledFonts()
        guard let font = NSFont(name: "JetBrainsMono-Regular", size: 40) else {
            throw ShortsError.message("Не найден шрифт JetBrains Mono для водяного знака BLACKFORGE.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(opacity), .shadow: shadow
        ]
        let originX = (canvas.width - (text as NSString).size(withAttributes: attributes).width) / 2
        for index in 0..<frameCount {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0) else { throw ShortsError.message("Не удалось создать водяной знак.") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let prefix = String(text.prefix(min(index + 1, text.count)))
            let visible = index < text.count - 1 ? prefix + "▏" : prefix
            (visible as NSString).draw(at: NSPoint(x: originX, y: 24), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw ShortsError.message("Не удалось сохранить кадр водяного знака.")
            }
            try data.write(to: directory.appendingPathComponent(String(format: "frame-%02d.png", index)), options: .atomic)
        }
        return directory.appendingPathComponent("frame-%02d.png")
    }
}
