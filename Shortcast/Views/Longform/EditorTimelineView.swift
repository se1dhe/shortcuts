import SwiftUI

/// Sequence timeline shared by the essay and short editors.
/// Sequence time is shown separately from source-film time to make edits legible.
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

    private var outputDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("ПОСЛЕДОВАТЕЛЬНОСТЬ", systemImage: "film.stack")
                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                    .foregroundStyle(StudioTheme.accent)
                Spacer()
                HStack(spacing: 12) {
                    metric("\(clips.count)", label: sceneLabel(clips.count))
                    Rectangle().fill(StudioTheme.line).frame(width: 1, height: 18)
                    metric("\(max(0, clips.count - 1))", label: cutLabel(max(0, clips.count - 1)))
                    Rectangle().fill(StudioTheme.line).frame(width: 1, height: 18)
                    metric(timecode(outputDuration), label: "в ролике")
                }
            }

            if clips.isEmpty {
                Button { onInsertAt(0) } label: {
                    Label("Добавить первую сцену из фильма", systemImage: "plus.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 92)
                }
                .buttonStyle(.bordered).tint(StudioTheme.accent)
            } else {
                GeometryReader { geometry in
                    let insertWidth: CGFloat = 28
                    let cutWidth: CGFloat = 20
                    let fixedWidth = CGFloat(clips.count + 1) * insertWidth + CGFloat(max(0, clips.count - 1)) * cutWidth
                    let minimumClip: CGFloat = 154
                    let availableForClips = max(0, geometry.size.width - fixedWidth - 12)
                    let clipWidths = clips.map { clip in
                        max(minimumClip, outputDuration > 0
                            ? availableForClips * CGFloat(clip.duration / outputDuration) : minimumClip)
                    }
                    let neededForClips = clipWidths.reduce(0, +)
                    let contentWidth = max(geometry.size.width, fixedWidth + neededForClips + 12)

                    ScrollView(.horizontal, showsIndicators: contentWidth > geometry.size.width) {
                        VStack(alignment: .leading, spacing: 8) {
                            sequenceRuler(width: contentWidth - 12)
                            HStack(alignment: .center, spacing: 0) {
                                insertionPoint(0)
                                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                    clipCard(clip, index: index, sequenceStart: clips.prefix(index).reduce(0) { $0 + $1.duration })
                                        .frame(width: clipWidths[index], height: 102)
                                    if index < clips.count - 1 {
                                        cutMarker
                                        insertionPoint(index + 1)
                                    }
                                }
                                insertionPoint(clips.count)
                            }
                            .frame(width: contentWidth, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: 138)

                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").foregroundStyle(StudioTheme.accent)
                    Text("Нажмите «+» в начале, конце или на стыке, чтобы найти фрагмент фильма и вставить его в последовательность.")
                        .foregroundStyle(StudioTheme.muted)
                    Spacer(minLength: 0)
                    Label("источник фильма", systemImage: "film")
                        .foregroundStyle(StudioTheme.muted)
                }
                .font(.system(size: 10, weight: .medium))
            }
        }
        .padding(16)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.line, lineWidth: 1))
    }

    private func metric(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.primary)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(StudioTheme.muted)
        }
    }

    private func sceneLabel(_ count: Int) -> String {
        let lastTwo = count % 100
        if (11...14).contains(lastTwo) { return "сцен" }
        switch count % 10 {
        case 1: return "сцена"
        case 2...4: return "сцены"
        default: return "сцен"
        }
    }

    private func cutLabel(_ count: Int) -> String {
        let lastTwo = count % 100
        if (11...14).contains(lastTwo) { return "стыков" }
        switch count % 10 {
        case 1: return "стык"
        case 2...4: return "стыка"
        default: return "стыков"
        }
    }

    private func sequenceRuler(width: CGFloat) -> some View {
        HStack {
            Text("00:00").frame(width: 34, alignment: .leading)
            Rectangle().fill(StudioTheme.line).frame(height: 1)
            Text(timecode(outputDuration)).frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(StudioTheme.muted)
        .frame(width: width, height: 16, alignment: .leading)
    }

    private func clipCard(_ clip: EditorTimelineClip, index: Int, sequenceStart: Double) -> some View {
        Button { onSelect(clip.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("СЦЕНА \(String(format: "%02d", index + 1))")
                        .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(0.4)
                    Spacer(minLength: 4)
                    if clip.isAdded {
                        Label("ВСТАВЛЕНА", systemImage: "plus.circle.fill")
                            .font(.system(size: 8, weight: .bold)).labelStyle(.titleAndIcon)
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.25))
                        Capsule().fill(StudioTheme.accent.opacity(0.8))
                            .frame(width: proxy.size.width)
                        HStack {
                            Image(systemName: "arrowtriangle.left.fill")
                            Spacer()
                            Image(systemName: "arrowtriangle.right.fill")
                        }
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .padding(.horizontal, 5)
                    }
                }
                .frame(height: 9)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("РОЛИК  \(timecode(sequenceStart))–\(timecode(sequenceStart + clip.duration))")
                            .foregroundStyle(.white.opacity(0.88))
                        Text("ФИЛЬМ  \(timecode(clip.start))–\(timecode(clip.end))")
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    Spacer(minLength: 4)
                    Text(timecode(clip.duration))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(StudioTheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(.primary)
            .background(selectedID == clip.id ? StudioTheme.accent.opacity(0.2) : StudioTheme.raised,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selectedID == clip.id ? StudioTheme.accent : StudioTheme.line,
                        lineWidth: selectedID == clip.id ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onMoveEarlier { Button("Переместить раньше", systemImage: "arrow.left") { onMoveEarlier(clip.id) } }
            if let onMoveLater { Button("Переместить позже", systemImage: "arrow.right") { onMoveLater(clip.id) } }
            if let onRemove { Button("Удалить сцену", systemImage: "trash", role: .destructive) { onRemove(clip.id) } }
        }
        .accessibilityLabel("Сцена \(index + 1), длительность \(timecode(clip.duration)), исходник \(timecode(clip.start))–\(timecode(clip.end))")
    }

    private var cutMarker: some View {
        Image(systemName: "scissors")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(StudioTheme.accent)
            .frame(width: 20)
            .help("Стык сцен в итоговом ролике")
    }

    private func insertionPoint(_ index: Int) -> some View {
        Button { onInsertAt(index) } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 24, height: 24)
                .background(StudioTheme.accent.opacity(0.1), in: Circle())
                .overlay(Circle().stroke(StudioTheme.accent.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .frame(width: 28)
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "Вставить сцену в начало" : index == clips.count ? "Добавить сцену в конец" : "Вставить сцену в эту склейку")
        .accessibilityLabel(index == 0 ? "Вставить в начало" : index == clips.count ? "Вставить в конец" : "Вставить между сценами")
    }

    private func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}
