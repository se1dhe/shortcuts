import Foundation

/// Look + animation of the burned-in text hook (the line over the first seconds
/// of the clip). Codable so it lives in AppSettings and per-clip.
struct HookAppearance: Codable, Equatable, Sendable {

    enum HookStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case pill        // dark rounded pill behind bold text (classic)
        case pop         // pill + springy scale-in
        case typewriter  // pill + left-to-right reveal
        case neon        // no pill, glowing text
        case minimal     // no pill, clean text with soft outline/shadow

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .pill:        "Bold pill"
            case .pop:         "Pop"
            case .typewriter:  "Typewriter"
            case .neon:        "Neon"
            case .minimal:     "Minimal"
            }
        }

        /// Whether the dark background pill is drawn.
        var showsPill: Bool { self == .pill || self == .pop || self == .typewriter }
    }

    /// Font size as a fraction of video width (fontSize = width * sizeScale).
    var sizeScale: Double = 0.029
    var styleRaw: String = HookStyle.pill.rawValue

    var style: HookStyle {
        get { HookStyle(rawValue: styleRaw) ?? .pill }
        set { styleRaw = newValue.rawValue }
    }

    static let `default` = HookAppearance()

    /// Clamps the size to a sane on-screen range.
    var normalized: HookAppearance {
        var copy = self
        copy.sizeScale = min(0.055, max(0.020, copy.sizeScale))
        if HookStyle(rawValue: copy.styleRaw) == nil { copy.styleRaw = HookStyle.pill.rawValue }
        return copy
    }
}
