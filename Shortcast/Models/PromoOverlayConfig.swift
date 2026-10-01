import Foundation

/// RedQueen Security bot promo chip burned into the top of a short.
/// `promoCode` is retained only as an on/off sentinel and for call-site compatibility;
/// the chip advertises @RedQueenSecurity_Bot and shows no code.
struct PromoOverlayConfig: Codable, Equatable, Sendable {
    /// Non-empty sentinel that keeps the overlay enabled (see `isValid`).
    var promoCode: String = "REDQUEEN"

    /// Seconds the banner stays on screen before it slides back up and disappears.
    /// 0 (the default) means half the video's duration.
    var holdSeconds: Double = 0

    static let `default` = PromoOverlayConfig()

    var sanitized: PromoOverlayConfig {
        var copy = self
        copy.promoCode = promoCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        copy.holdSeconds = max(0, holdSeconds)
        return copy
    }

    var isValid: Bool {
        !sanitized.promoCode.isEmpty
    }
}
