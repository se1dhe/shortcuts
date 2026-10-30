import SwiftUI

/// Shared, sequence-oriented timeline for the essay and short-form editors.
/// Each clip is a source-film range; gaps between cards are explicit edit points.
struct EditorTimelineClip: Identifiable {
    let id: UUID
    let start: Double
    let end: Double
    let isAdded: Bool

    var duration: Double { max(0, end - start) }
}

struct EditorTimelineView: View {
    let clips: [EditorTimelineClip]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void
    let onInsertAt: (Int) -> Void
    let onMoveEarlier: ((UUID) -> Void)?
    let onMoveLater: ((UUID) -> Void)?
    let onRemove: ((UUID) -> Void)?

    private var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("МОНТАЖНАЯ ПОСЛЕДОВАТЕЛЬНОСТЬ", systemImage: "film.stack")
                    .font(.system(size: 10, weight: .bold)).tracking(1.1)
                    .foregroundStyle(StudioTheme.accent)
                Spacer()
                Text("\(clips.count) склеек  ·  \(timecode(totalDuration))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .center, spacing: 5) {
                    insertionPoint(0)
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        Button { onSelect(clip.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 4) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 10, weight: .black, design: .monospaced))
                                    Spacer(minLength: 0)
                                    if clip.isAdded { Image(systemName: "plus.circle.fill").font(.system(size: 9)) }
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.2))
                                        RoundedRectangle(cornerRadius: 2).fill(StudioTheme.accent.opacity(0.72))
                                            .frame(width: max(8, proxy.size.width * 0.74))
                                        HStack(spacing: 3) {
                                            ForEach(0..<5, id: \.self) { barIndex in
                                                Capsule().fill(.white.opacity(0.24)).frame(width: 2, height: CGFloat([6, 11, 8, 13, 7][barIndex]))
                                            }
                                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }.frame(height: 17)
                                Text("\(timecode(clip.start)) → \(timecode(clip.end))")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                Text("\(Int(clip.duration.rounded())) с")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(StudioTheme.accent)
                            }
                            .padding(9)
                            .frame(width: clipWidth(clip), height: 90, alignment: .topLeading)
                            .foregroundStyle(.white.opacity(0.9))
                            .background(selectedID == clip.id ? StudioTheme.accent.opacity(0.23) : StudioTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedID == clip.id ? StudioTheme.accent : StudioTheme.line,
                                        lineWidth: selectedID == clip.id ? 1.5 : 1))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            if let onMoveEarlier { Button("Переместить раньше", systemImage: "arrow.left") { onMoveEarlier(clip.id) } }
                            if let onMoveLater { Button("Переместить позже", systemImage: "arrow.right") { onMoveLater(clip.id) } }
                            if let onRemove { Button("Удалить сцену", systemImage: "trash", role: .destructive) { onRemove(clip.id) } }
                        }
                        cutMarker
                        insertionPoint(index + 1)
                    }
                    if clips.isEmpty { Text("Добавьте первую сцену из исходного фильма").font(.caption).foregroundStyle(StudioTheme.muted).padding(.horizontal, 10) }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 7) {
                Image(systemName: "scissors").foregroundStyle(StudioTheme.accent)
                Text("СКЛЕЙКА")
                Rectangle().fill(StudioTheme.line).frame(height: 1)
                Text("порядок ролика")
            }
            .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(StudioTheme.muted)
        }
        .padding(13)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.line, lineWidth: 1))
    }

    private var cutMarker: some View {
        Image(systemName: "scissors")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(StudioTheme.accent)
            .frame(width: 14)
            .help("Точка склейки между сценами")
    }

    private func insertionPoint(_ index: Int) -> some View {
        Button { onInsertAt(index) } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 22, height: 22)
                .background(StudioTheme.accent.opacity(0.1), in: Circle())
                .overlay(Circle().stroke(StudioTheme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "Вставить в начало" : index == clips.count ? "Вставить в конец" : "Вставить между сценами")
    }

    private func clipWidth(_ clip: EditorTimelineClip) -> CGFloat {
        min(220, max(112, CGFloat(clip.duration) * 3.2))
    }

    private func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
