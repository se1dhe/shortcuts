import SwiftUI

/// An editable clip in the final sequence. Source time and sequence time are kept distinct.
struct EditorTimelineClip: Identifiable {
    let id: UUID
    let start: Double
    let end: Double
    let isAdded: Bool
    var actNumber: Int? = nil
    var actTitle: String? = nil
    var sceneNumber: Int? = nil
    var quote: String? = nil
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
    var onTrimStart: ((UUID, Double) -> Void)? = nil
    var onTrimEnd: ((UUID, Double) -> Void)? = nil
    @State private var zoom: CGFloat = 1

    private var totalDuration: Double { clips.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("МОНТАЖНАЯ ЛИНИЯ", systemImage: "film.stack")
                        .font(.system(size: 11, weight: .bold)).tracking(1.2)
                        .foregroundStyle(StudioTheme.accent)
                    Text("Перетаскивайте края клипа для точной подрезки · «+» вставляет сцену в стык")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                HStack(spacing: 14) {
                    metric(clips.count, label: sceneLabel(clips.count))
                    metric(max(0, clips.count - 1), label: cutLabel(max(0, clips.count - 1)))
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(timecode(totalDuration))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                        Text("ДЛИТЕЛЬНОСТЬ")
                            .font(.system(size: 8, weight: .bold)).tracking(0.9)
                            .foregroundStyle(StudioTheme.muted)
                    }
                    HStack(spacing: 4) {
                        Button { zoom = max(1, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                            .help("Уменьшить масштаб, не меньше режима «Вписать»")
                        Button("Вписать") { zoom = 1 }
                            .font(.system(size: 9, weight: .semibold))
                            .help("Показать всю последовательность")
                        Button { zoom = min(3, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                            .help("Увеличить масштаб")
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .tint(StudioTheme.accent)
                }
            }

            if clips.isEmpty {
                Button { onInsertAt(0) } label: {
                    Label("Добавить первую сцену из фильма", systemImage: "plus.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 92)
                }
                .buttonStyle(.bordered).tint(StudioTheme.accent)
            } else {
                GeometryReader { viewport in
                    let spacing: CGFloat = 2
                    let available = max(1, viewport.size.width - 24 - spacing * CGFloat(max(0, clips.count - 1)))
                    let scale = max(CGFloat(0.75), available / max(CGFloat(1), CGFloat(totalDuration))) * zoom
                    let widths = clips.map { max(72, CGFloat($0.duration) * scale) }
                    let trackWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, clips.count - 1))
                    let canvasWidth = max(viewport.size.width, trackWidth + 24)

                    ScrollView(.horizontal, showsIndicators: canvasWidth > viewport.size.width + 1) {
                        VStack(alignment: .leading, spacing: 7) {
                            ruler(widths: widths, spacing: spacing, width: canvasWidth)
                            ZStack(alignment: .topLeading) {
                                HStack(spacing: spacing) {
                                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                        EditorTimelineClipBlock(
                                            clip: clip,
                                            index: index,
                                            sequenceStart: clips.prefix(index).reduce(0) { $0 + $1.duration },
                                            selected: selectedID == clip.id,
                                            onSelect: { onSelect(clip.id) },
                                            onMoveEarlier: onMoveEarlier.map { callback in { callback(clip.id) } },
                                            onMoveLater: onMoveLater.map { callback in { callback(clip.id) } },
                                            onRemove: onRemove.map { callback in { callback(clip.id) } },
                                            onTrimStart: onTrimStart.map { callback in { callback(clip.id, $0) } },
                                            onTrimEnd: onTrimEnd.map { callback in { callback(clip.id, $0) } }
                                        )
                                        .frame(width: widths[index], height: 104)
                                    }
                                }
                                .padding(.horizontal, 12)

                                insertionPoint(0)
                                    .position(x: 12, y: 52)
                                ForEach(Array(clips.enumerated()), id: \.element.id) { index, _ in
                                    let nextX = CGFloat(12) + widths.prefix(index + 1).reduce(0, +) + spacing * CGFloat(index)
                                    if index < clips.count - 1 {
                                        cutLine.position(x: nextX + spacing / 2, y: 52)
                                        insertionPoint(index + 1).position(x: nextX + spacing / 2, y: 52)
                                    }
                                    if index == clips.count - 1 {
                                        insertionPoint(clips.count).position(x: CGFloat(12) + trackWidth, y: 52)
                                    }
                                }
                            }
                            .frame(width: canvasWidth, height: 104)
                            .background(StudioTheme.background.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.line, lineWidth: 1))
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(height: 140)
            }
        }
        .padding(15)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.line, lineWidth: 1))
    }

    private func metric(_ value: Int, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)").font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(label.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.9)
                .foregroundStyle(StudioTheme.muted)
        }
    }

    private func ruler(widths: [CGFloat], spacing: CGFloat, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, _ in
                let outputStart = clips.prefix(index).reduce(0) { $0 + $1.duration }
                VStack(alignment: .leading, spacing: 4) {
                    Text(timecode(outputStart)).font(.system(size: 9, weight: .medium, design: .monospaced))
                    Rectangle().fill(StudioTheme.line).frame(width: 1, height: 7)
                }
                .frame(width: widths[index], alignment: .leading)
                if index < clips.count - 1 {
                    Rectangle().fill(StudioTheme.line).frame(width: spacing, height: 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 18, alignment: .leading)
        .overlay(alignment: .trailing) {
            Text(timecode(totalDuration))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTheme.muted)
                .padding(.trailing, 2)
        }
        .foregroundStyle(StudioTheme.muted)
        .accessibilityLabel("Линейка времени, длительность \(timecode(totalDuration))")
        .background(alignment: .bottom) { Rectangle().fill(StudioTheme.line).frame(height: 1) }
    }

    private var cutLine: some View {
        Rectangle().fill(StudioTheme.accent.opacity(0.75)).frame(width: 2, height: 82)
            .overlay(alignment: .top) {
                Image(systemName: "scissors.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(StudioTheme.accent)
                    .offset(y: -8)
            }
            .frame(width: 2, height: 104)
    }

    private func insertionPoint(_ index: Int) -> some View {
        Button { onInsertAt(index) } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(Color(hex: "17130D"))
                .frame(width: 23, height: 23)
                .background(StudioTheme.accent, in: Circle())
                .overlay(Circle().stroke(StudioTheme.background, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "Вставить в начало" : index == clips.count ? "Вставить в конец" : "Вставить в этот стык")
        .accessibilityLabel(index == 0 ? "Вставить в начало" : index == clips.count ? "Вставить в конец" : "Вставить между сценами")
    }

    private func sceneLabel(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "сцен" }
        return switch count % 10 { case 1: "сцена"; case 2...4: "сцены"; default: "сцен" }
    }

    private func cutLabel(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "стыков" }
        return switch count % 10 { case 1: "стык"; case 2...4: "стыка"; default: "стыков" }
    }

    fileprivate func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

private struct EditorTimelineClipBlock: View {
    let clip: EditorTimelineClip
    let index: Int
    let sequenceStart: Double
    let selected: Bool
    let onSelect: () -> Void
    let onMoveEarlier: (() -> Void)?
    let onMoveLater: (() -> Void)?
    let onRemove: (() -> Void)?
    let onTrimStart: ((Double) -> Void)?
    let onTrimEnd: ((Double) -> Void)?

    @State private var inOrigin: Double?
    @State private var inWidth: CGFloat = 1
    @State private var inDuration: Double = 1
    @State private var outOrigin: Double?
    @State private var outWidth: CGFloat = 1
    @State private var outDuration: Double = 1

    private var actColor: Color {
        let palette: [Color] = [StudioTheme.accent, Color(hex: "8AB7D9"), Color(hex: "B7A0D8"), Color(hex: "79C99E"), Color(hex: "E79A78")]
        guard let actNumber = clip.actNumber else { return StudioTheme.accent }
        return palette[(actNumber - 1) % palette.count]
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? actColor.opacity(0.2) : StudioTheme.raised)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    if let actNumber = clip.actNumber {
                        Text("АКТ \(actNumber)")
                            .foregroundStyle(actColor)
                    }
                    Text("СЦЕНА \(String(format: "%02d", clip.sceneNumber ?? index + 1))")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 2)
                    if clip.isAdded { Image(systemName: "plus.circle.fill").foregroundStyle(StudioTheme.success) }
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                Text(clip.quote?.trimmed.isEmpty == false ? clip.quote! : (clip.actTitle ?? "Фрагмент фильма"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("В РОЛИКЕ").foregroundStyle(StudioTheme.muted)
                    Text("\(timecode(sequenceStart))–\(timecode(sequenceStart + clip.duration))")
                        .foregroundStyle(.white.opacity(0.92))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
                HStack {
                    Text("ФИЛЬМ  \(timecode(clip.start))–\(timecode(clip.end))")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 2)
                    Text(String(format: "%.1f с", clip.duration))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(actColor)
                }
            }
            .padding(.leading, 13).padding(.trailing, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            HStack(spacing: 0) {
                trimHandle(isLeading: true, blockWidth: geometry.size.width)
                Spacer(minLength: 0)
                trimHandle(isLeading: false, blockWidth: geometry.size.width)
            }
            .padding(.vertical, 11)
        }
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? actColor : StudioTheme.line,
                                                          lineWidth: selected ? 1.5 : 1))
        .contextMenu {
            if let onMoveEarlier { Button("Переместить раньше", systemImage: "arrow.left", action: onMoveEarlier) }
            if let onMoveLater { Button("Переместить позже", systemImage: "arrow.right", action: onMoveLater) }
            if let onRemove { Button("Удалить сцену", systemImage: "trash", role: .destructive, action: onRemove) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.actNumber.map { "Акт \($0), " } ?? "")сцена \(clip.sceneNumber ?? index + 1), \(String(format: "%.1f", clip.duration)) секунд")
        .accessibilityHint("Выбрать сцену. Перетаскивайте края клипа для подрезки.")
        }
    }

    private func trimHandle(isLeading: Bool, blockWidth: CGFloat) -> some View {
        Rectangle().fill(Color.clear).frame(width: 18)
            .overlay {
                Rectangle().fill(selected ? actColor : Color.white.opacity(0.45))
                    .frame(width: 5)
                    .overlay { Capsule().fill(Color.black.opacity(0.75)).frame(width: 1.5, height: 15) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if isLeading {
                            if inOrigin == nil {
                                inOrigin = clip.start
                                inWidth = max(1, blockWidth - 18)
                                inDuration = clip.duration
                            }
                            let seconds = Double(value.translation.width / inWidth) * inDuration
                            onTrimStart?((inOrigin ?? clip.start) + seconds)
                        } else {
                            if outOrigin == nil {
                                outOrigin = clip.end
                                outWidth = max(1, blockWidth - 18)
                                outDuration = clip.duration
                            }
                            let seconds = Double(value.translation.width / outWidth) * outDuration
                            onTrimEnd?((outOrigin ?? clip.end) + seconds)
                        }
                    }
                    .onEnded { _ in
                        if isLeading { inOrigin = nil } else { outOrigin = nil }
                    }
            )
            .help(isLeading ? "Перетащите, чтобы изменить IN" : "Перетащите, чтобы изменить OUT")
    }

    private func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
