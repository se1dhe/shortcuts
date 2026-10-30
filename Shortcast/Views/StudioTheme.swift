import SwiftUI

enum StudioTheme {
    static let background = Color(hex: "101216")
    static let panel = Color(hex: "191C22")
    static let raised = Color(hex: "22262E")
    static let accent = Color(hex: "E8C582")
    static let muted = Color(hex: "9299A6")
    static let line = Color.white.opacity(0.08)
    static let success = Color(hex: "79C99E")
    static let warning = Color(hex: "E7AE68")
}

enum StudioStage: Int, CaseIterable, Identifiable {
    case film, essay, shorts, posting
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .film: "Фильм"
        case .essay: "Эссе"
        case .shorts: "Шортсы"
        case .posting: "Постинг"
        }
    }
    var detail: String {
        switch self {
        case .film: "Источник и озвучка"
        case .essay: "Тема и монтаж"
        case .shorts: "Два ракурса темы"
        case .posting: "Выпуск на площадки"
        }
    }
    var symbol: String {
        switch self {
        case .film: "film"
        case .essay: "rectangle.stack"
        case .shorts: "scissors"
        case .posting: "paperplane"
        }
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(Color(hex: "221C11"))
            .background(StudioTheme.accent.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.6)
    }
}

extension View {
    func studioPanel(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StudioTheme.line))
    }

    func studioSurface() -> some View {
        self.background(StudioTheme.background)
            .preferredColorScheme(.dark)
            .tint(StudioTheme.accent)
    }
}
