import SwiftUI

extension Color {
    /// Creates a color from a 6-digit sRGB hex string (with or without `#`).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

extension SocialPlatform {
    /// Brand-ish accent color for this platform.
    var tint: Color { Color(hex: tintHex) }
}

// AppKit colors are used by the offscreen essay caption renderer.
extension NSColor {
    convenience init?(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xff) / 255,
                  green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
