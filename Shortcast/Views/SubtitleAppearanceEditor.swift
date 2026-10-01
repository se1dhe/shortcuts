import SwiftUI

/// Focused TikTok-style subtitle controls. The renderer keeps the technical
/// defaults readable; the UI exposes only choices creators actually need.
struct SubtitleAppearanceEditor: View {

    @Binding var appearance: SubtitleAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Style", selection: presetBinding) {
                Text("TikTok").tag("tiktok")
                Text("Creator").tag("creator")
                Text("Karaoke").tag("karaoke")
                Text("Neon").tag("neon")
                Text("Clean").tag("minimal")
            }
            .pickerStyle(.segmented)

            row("Font") {
                Picker("", selection: fontBinding) {
                    ForEach(SubtitleAppearance.FontChoice.allCases) { font in
                        Text(LocalizedStringKey(font.displayName)).tag(font)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            row("Size") {
                Slider(value: $appearance.fontSizeScale, in: 0.052...0.09, step: 0.002)
                    .controlSize(.small)
                Text(LocalizedStringKey(sizeLabel))
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }

            row("Position") {
                Picker("", selection: positionBinding) {
                    Text("Middle").tag(0.58)
                    Text("Lower").tag(0.72)
                    Text("Bottom").tag(0.82)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            row("Accent") {
                HStack(spacing: 8) {
                    ForEach(accentColors, id: \.self) { hex in
                        Button {
                            appearance.accentColorHex = hex
                            if appearance.highlightModeRaw == "none" {
                                appearance.highlightModeRaw = "keyword"
                            }
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle("Highlight", isOn: highlightBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            row("Motion") {
                Picker("", selection: $appearance.animationRaw) {
                    Text("Pop-up").tag("pop")
                    Text("Bounce").tag("bounce")
                    Text("Karaoke").tag("karaoke")
                    Text("Neon").tag("neon")
                    Text("Fade").tag("fade")
                    Text("Clean").tag("clean")
                    Text("Static").tag("none")
                }
                .pickerStyle(.menu)
                .frame(width: 190)
            }
        }
        .onAppear { appearance = appearance.normalizedForTikTokUI }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: {
                switch appearance.animationRaw.lowercased() {
                case "karaoke": return "karaoke"
                case "neon": return "neon"
                default: break
                }
                if appearance.fontChoiceRaw == SubtitleAppearance.creator.fontChoiceRaw &&
                    appearance.accentColorHex == SubtitleAppearance.creator.accentColorHex {
                    return "creator"
                }
                if appearance.fontChoiceRaw == SubtitleAppearance.minimal.fontChoiceRaw &&
                    appearance.highlightModeRaw == SubtitleAppearance.minimal.highlightModeRaw {
                    return "minimal"
                }
                return "tiktok"
            },
            set: { value in
                appearance = SubtitleAppearance.defaults[value] ?? .tiktok
            })
    }

    private var fontBinding: Binding<SubtitleAppearance.FontChoice> {
        Binding(
            get: { appearance.fontChoice },
            set: {
                appearance.fontChoiceRaw = $0.rawValue
                switch $0 {
                case .russoOne, .bebasNeue, .impact:
                    appearance.fontWeightRaw = "heavy"
                    appearance.maxWordsPerCaption = 5
                case .helvetica:
                    appearance.fontWeightRaw = "bold"
                    appearance.maxWordsPerCaption = 9
                default:
                    appearance.fontWeightRaw = "bold"
                    appearance.maxWordsPerCaption = 7
                }
            })
    }

    private var positionBinding: Binding<Double> {
        Binding(
            get: {
                let v = appearance.verticalPosition
                if v < 0.65 { return 0.58 }
                if v < 0.78 { return 0.72 }
                return 0.82
            },
            set: { appearance.verticalPosition = $0 })
    }

    private var highlightBinding: Binding<Bool> {
        Binding(
            get: { appearance.highlightModeRaw != "none" },
            set: { appearance.highlightModeRaw = $0 ? "keyword" : "none" })
    }

    @ViewBuilder
    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sizeLabel: String {
        if appearance.fontSizeScale < 0.063 { return "Small" }
        if appearance.fontSizeScale < 0.078 { return "Bold" }
        return "Huge"
    }

    private let accentColors = [
        "#FFE45C", "#FF4D6D", "#50E3A4", "#48B7FF", "#FFFFFF",
    ]
}

private extension SubtitleAppearance {
    var normalizedForTikTokUI: SubtitleAppearance {
        var copy = normalized
        copy.bgOpacity = 0
        copy.cornerRadiusScale = 0
        copy.paddingScale = 0.006
        copy.textColorHex = "#FFFFFF"
        copy.textBorderColorHex = "#000000"
        copy.textBorderWidth = max(copy.textBorderWidth, 2.0)
        copy.horizontalAlign = "center"
        return copy
    }
}
