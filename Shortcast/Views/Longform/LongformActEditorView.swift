import AVFoundation
import AVKit
import SwiftUI

/// Редактируемая сцена внутри акта
struct EditableSceneSegment: Identifiable, Equatable {
    let id: UUID
    let sceneIndex: Int
    var start: Double
    var end: Double
    let originalStart: Double
    let originalEnd: Double

    init(id: UUID = UUID(), sceneIndex: Int, start: Double, end: Double) {
        self.id = id
        self.sceneIndex = sceneIndex
        self.start = start
        self.end = end
        self.originalStart = start
        self.originalEnd = end
    }

    var duration: Double {
        max(0.0, end - start)
    }

    var isEdited: Bool {
        abs(start - originalStart) > 0.05 || abs(end - originalEnd) > 0.05
    }

    var diffDuration: Double {
        duration - (originalEnd - originalStart)
    }
}

/// Редактируемый акт драматургической структуры
struct EditableActModel: Identifiable, Equatable {
    let id: String
    let actIndex: Int
    let type: LongformActType
    var title: String
    var dramaticBeat: String
    var scenes: [EditableSceneSegment]

    var duration: Double {
        scenes.reduce(0.0) { $0 + $1.duration }
    }

    var isEdited: Bool {
        scenes.contains { $0.isEdited }
    }

    var diffDuration: Double {
        scenes.reduce(0.0) { $0 + $1.diffDuration }
    }
}

/// Экран точного монтажа актов и сцен кино-эссе (In/Out Trimmer)
/// Позволяет подрезать начало и конец каждого акта, с автоматической
/// подстройкой таймингов титров, музыки и кинематографических фейдов.
struct LongformActEditorView: View {

    let arc: LongformNarrativeArc
    let concept: ThematicConcept
    let movieTitle: String
    let transcriptSegments: [TranscriptSegment]
    let sourceURL: URL?
    let onApply: (LongformNarrativeArc) -> Void
    let onCancel: () -> Void

    @State private var editedActs: [EditableActModel] = []
    @State private var selectedActIndex: Int = 0
    @State private var sourceDuration: Double = .infinity
    @State private var previewPlayer: AVPlayer?
    @State private var previewStopTask: Task<Void, Never>?

    private let minSceneDuration: Double = 3.0

    init(
        arc: LongformNarrativeArc,
        concept: ThematicConcept,
        movieTitle: String,
        transcriptSegments: [TranscriptSegment],
        sourceURL: URL? = nil,
        onApply: @escaping (LongformNarrativeArc) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.arc = arc
        self.concept = concept
        self.movieTitle = movieTitle
        self.transcriptSegments = transcriptSegments
        self.sourceURL = sourceURL
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private var totalDuration: Double {
        editedActs.reduce(0.0) { $0 + $1.duration }
    }

    private var originalTotalDuration: Double {
        arc.totalDuration
    }

    private var totalDiffSeconds: Double {
        totalDuration - originalTotalDuration
    }

    private var totalEditedCount: Int {
        editedActs.filter(\.isEdited).count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            actTabsBar

            Divider()

            if !editedActs.isEmpty && selectedActIndex < editedActs.count {
                actDetailEditor(actIndex: selectedActIndex)
            } else {
                ContentUnavailableView("Нет актов для редактирования", systemImage: "film.stack")
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadInitialActs()
            preparePreviewPlayer()
        }
        .onDisappear {
            previewStopTask?.cancel()
            previewPlayer?.pause()
            previewPlayer = nil
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 14) {
            Button {
                onCancel()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                    Text("Отмена")
                }
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Монтажный стол кино-эссе")
                        .font(.headline)

                    Text("«\(concept.word.uppercased())»")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.18), in: Capsule())
                        .foregroundStyle(.yellow)

                    if totalEditedCount > 0 {
                        Text("Изменено актов: \(totalEditedCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }

                Text("Фильм «\(movieTitle)» • Обрезайте начало и конец актов — титры и музыка подстроятся автоматически")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Индикатор общего хронометража
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Хронометраж:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatDuration(totalDuration))
                            .font(.callout.monospacedDigit().weight(.bold))
                            .foregroundStyle(.primary)
                    }

                    if abs(totalDiffSeconds) > 0.1 {
                        Text(String(format: "%@%.1fc к исходному", totalDiffSeconds > 0 ? "+" : "", totalDiffSeconds))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(totalDiffSeconds >= 0 ? .green : .orange)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

                Button {
                    resetAllActs()
                } label: {
                    Label("Сбросить всё", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(totalEditedCount == 0)

                Button {
                    applyChangesAndProceed()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Применить и перерендерить")
                    }
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Act Tabs Bar

    private var actTabsBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<editedActs.count, id: \.self) { idx in
                let act = editedActs[idx]
                let isSelected = selectedActIndex == idx

                Button {
                    selectedActIndex = idx
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSelected ? Color.yellow : (act.isEdited ? Color.green : Color.secondary.opacity(0.4)))
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("АКТ \(idx + 1)")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(isSelected ? .yellow : .secondary)

                                if act.isEdited {
                                    Text("✓")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                }
                            }

                            Text(act.type.rawValue)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(isSelected ? .primary : .secondary)

                            HStack(spacing: 4) {
                                Text(formatDuration(act.duration))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                if abs(act.diffDuration) > 0.1 {
                                    Text(String(format: "%@%.1fc", act.diffDuration > 0 ? "+" : "", act.diffDuration))
                                        .font(.caption2.monospacedDigit().weight(.bold))
                                        .foregroundStyle(act.diffDuration >= 0 ? .green : .orange)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.yellow.opacity(0.12) : Color.secondary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.yellow.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - Act Detail Editor

    @ViewBuilder
    private func actDetailEditor(actIndex: Int) -> some View {
        let act = editedActs[actIndex]

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                // Карточка темы акта
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("АКТ \(actIndex + 1): \(act.type.rawValue.uppercased())")
                                .font(.caption.weight(.black))
                                .foregroundStyle(.yellow)

                            Text("•")
                                .foregroundStyle(.secondary)

                            Text(act.title)
                                .font(.headline)
                        }

                        Text(act.dramaticBeat)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        resetAct(actIndex: actIndex)
                    } label: {
                        Label("Сбросить акт", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!act.isEdited)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))

                actInOutCard(actIndex: actIndex)

                if previewPlayer != nil {
                    actPreviewPlayer
                }

                // Сцены акта
                VStack(alignment: .leading, spacing: 12) {
                    Text("Сцены и склейки фильма (\(act.scenes.count)):")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    ForEach(0..<act.scenes.count, id: \.self) { sceneIdx in
                        sceneTrimmerCard(actIndex: actIndex, sceneIndex: sceneIdx)
                    }
                }
            }
            .padding(18)
        }
    }

    // MARK: - Scene Trimmer Card

    private func sceneTrimmerCard(actIndex: Int, sceneIndex: Int) -> some View {
        let scene = editedActs[actIndex].scenes[sceneIndex]
        let includedPhrases = phrasesFor(start: scene.start, end: scene.end)

        return VStack(alignment: .leading, spacing: 12) {
            // Заголовок сцены и общий хронометраж
            HStack {
                HStack(spacing: 8) {
                    Text("Сцена #\(sceneIndex + 1)")
                        .font(.subheadline.weight(.bold))

                    Text("Длительность: \(formatDurationWithTenths(scene.duration))")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.yellow)

                    if abs(scene.diffDuration) > 0.1 {
                        Text(String(format: "(%@%.1fc)", scene.diffDuration > 0 ? "+" : "", scene.diffDuration))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(scene.diffDuration >= 0 ? .green : .orange)
                    }
                }

                Spacer()

                if scene.isEdited {
                    Text("Отредактировано")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            Divider()

            // Панель 1: НАЧАЛО СЦЕНЫ (In-Point)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("НАЧАЛО СЦЕНЫ (IN):", systemImage: "arrow.right.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(formatTimecode(scene.start))
                        .font(.callout.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 4) {
                        Button {
                            playRange(start: scene.start, end: min(scene.start + 4.0, scene.end))
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Проиграть вход сцены")

                        trimButton(label: "-5с", delta: -5.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: -5.0) }
                        trimButton(label: "-1с", delta: -1.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: -1.0) }
                        trimButton(label: "-0.2с", delta: -0.2) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: -0.2) }
                        trimButton(label: "+0.2с", delta: 0.2) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: 0.2) }
                        trimButton(label: "+1с", delta: 1.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: 1.0) }
                        trimButton(label: "+5с", delta: 5.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: 5.0) }
                    }
                }

                if let firstLine = includedPhrases.first {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("Первая фраза входа:")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("«\(firstLine.text)»")
                            .font(.caption2.italic())
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text("(\(formatTimecode(firstLine.start)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Речь в начале сцены отсутствует (пауза/действие)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))

            // Панель 2: КОНЕЦ СЦЕНЫ (Out-Point)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("КОНЕЦ СЦЕНЫ (OUT):", systemImage: "arrow.left.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(formatTimecode(scene.end))
                        .font(.callout.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 4) {
                        Button {
                            playRange(start: max(scene.start, scene.end - 4.0), end: scene.end)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Проиграть выход сцены")

                        trimButton(label: "-5с", delta: -5.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: -5.0) }
                        trimButton(label: "-1с", delta: -1.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: -1.0) }
                        trimButton(label: "-0.2с", delta: -0.2) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: -0.2) }
                        trimButton(label: "+0.2с", delta: 0.2) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: 0.2) }
                        trimButton(label: "+1с", delta: 1.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: 1.0) }
                        trimButton(label: "+5с", delta: 5.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: 5.0) }
                    }
                }

                if let lastLine = includedPhrases.last {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("Финальная фраза выхода:")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("«\(lastLine.text)»")
                            .font(.caption2.italic())
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text("(\(formatTimecode(lastLine.end)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Речь в конце сцены отсутствует")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))

            sceneRangeSliders(actIndex: actIndex, sceneIndex: sceneIndex)

            // Список всех реплик диалога в этом интервале
            DisclosureGroup("Диалоги в этой сцене (\(includedPhrases.count) фраз)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(includedPhrases, id: \.start) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Text(formatTimecode(s.start))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .leading)

                            Text(s.text)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(scene.isEdited ? Color.green.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func trimButton(label: String, delta: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.monospacedDigit().weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(delta > 0 ? .yellow : .secondary)
    }

    // MARK: - Act In/Out + Preview

    private func actInOutCard(actIndex: Int) -> some View {
        let act = editedActs[actIndex]
        let first = act.scenes.first
        let last = act.scenes.last
        let lastIndex = max(0, act.scenes.count - 1)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Обрезка акта целиком")
                .font(.subheadline.weight(.bold))

            Text("Меняет вход первой сцены и выход последней. Титры актов, субтитры и музыка пересчитаются при перерендере.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("НАЧАЛО АКТА (IN)", systemImage: "arrow.right.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(formatTimecode(first?.start ?? 0))
                        .font(.callout.monospacedDigit().weight(.bold))
                    HStack(spacing: 4) {
                        Button {
                            if let first {
                                playRange(start: first.start, end: min(first.start + 4.0, first.end))
                            }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        trimButton(label: "-1с", delta: -1.0) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: -1.0) }
                        trimButton(label: "-0.2с", delta: -0.2) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: -0.2) }
                        trimButton(label: "+0.2с", delta: 0.2) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: 0.2) }
                        trimButton(label: "+1с", delta: 1.0) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: 1.0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Label("КОНЕЦ АКТА (OUT)", systemImage: "arrow.left.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(formatTimecode(last?.end ?? 0))
                        .font(.callout.monospacedDigit().weight(.bold))
                    HStack(spacing: 4) {
                        Button {
                            if let last {
                                playRange(start: max(last.start, last.end - 4.0), end: last.end)
                            }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        trimButton(label: "-1с", delta: -1.0) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: -1.0) }
                        trimButton(label: "-0.2с", delta: -0.2) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: -0.2) }
                        trimButton(label: "+0.2с", delta: 0.2) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: 0.2) }
                        trimButton(label: "+1с", delta: 1.0) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: 1.0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
    }

    private var actPreviewPlayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Предпросмотр исходника")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button("Стоп") {
                    previewStopTask?.cancel()
                    previewPlayer?.pause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let previewPlayer {
                VideoPlayer(player: previewPlayer)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func sceneRangeSliders(actIndex: Int, sceneIndex: Int) -> some View {
        let scene = editedActs[actIndex].scenes[sceneIndex]
        let maxBound = sourceDuration.isFinite ? sourceDuration : max(scene.end + 60.0, scene.originalEnd + 60.0)
        let startUpper = max(0.0, scene.end - minSceneDuration)
        let endLower = scene.start + minSceneDuration

        return VStack(spacing: 8) {
            HStack {
                Text("In")
                    .font(.caption2.weight(.bold))
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { scene.start },
                        set: { setStart(actIndex: actIndex, sceneIndex: sceneIndex, value: $0) }
                    ),
                    in: 0...max(0.01, startUpper)
                )
            }
            HStack {
                Text("Out")
                    .font(.caption2.weight(.bold))
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { scene.end },
                        set: { setEnd(actIndex: actIndex, sceneIndex: sceneIndex, value: $0) }
                    ),
                    in: endLower...max(endLower + 0.01, maxBound)
                )
            }
        }
    }

    // MARK: - Trimming Actions

    private func preparePreviewPlayer() {
        guard let sourceURL else { return }
        previewPlayer = AVPlayer(url: sourceURL)
        Task {
            let asset = AVURLAsset(url: sourceURL)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
                sourceDuration = duration.seconds
            }
        }
    }

    private func playRange(start: Double, end: Double) {
        guard let previewPlayer else { return }
        previewStopTask?.cancel()
        let startCM = CMTime(seconds: max(0.0, start), preferredTimescale: 600)
        previewPlayer.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in
                previewPlayer.play()
            }
        }
        let hold = max(0.2, end - start)
        previewStopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            previewPlayer.pause()
        }
    }

    private func setStart(actIndex: Int, sceneIndex: Int, value: Double) {
        var current = editedActs[actIndex].scenes[sceneIndex]
        current.start = min(max(0.0, value), current.end - minSceneDuration)
        editedActs[actIndex].scenes[sceneIndex] = current
    }

    private func setEnd(actIndex: Int, sceneIndex: Int, value: Double) {
        var current = editedActs[actIndex].scenes[sceneIndex]
        let maxEnd = sourceDuration.isFinite ? sourceDuration : value
        current.end = min(max(current.start + minSceneDuration, value), maxEnd)
        editedActs[actIndex].scenes[sceneIndex] = current
    }

    private func adjustStart(actIndex: Int, sceneIndex: Int, delta: Double) {
        guard actIndex < editedActs.count, sceneIndex < editedActs[actIndex].scenes.count else { return }
        let current = editedActs[actIndex].scenes[sceneIndex]
        setStart(actIndex: actIndex, sceneIndex: sceneIndex, value: current.start + delta)
    }

    private func adjustEnd(actIndex: Int, sceneIndex: Int, delta: Double) {
        guard actIndex < editedActs.count, sceneIndex < editedActs[actIndex].scenes.count else { return }
        let current = editedActs[actIndex].scenes[sceneIndex]
        setEnd(actIndex: actIndex, sceneIndex: sceneIndex, value: current.end + delta)
    }

    private func resetAct(actIndex: Int) {
        guard actIndex < arc.acts.count else { return }
        let originalAct = arc.acts[actIndex]
        let originalScenes = originalAct.segments.enumerated().map { idx, seg in
            EditableSceneSegment(sceneIndex: idx, start: seg.start, end: seg.end)
        }
        editedActs[actIndex].scenes = originalScenes
    }

    private func resetAllActs() {
        loadInitialActs()
    }

    private func loadInitialActs() {
        editedActs = arc.acts.enumerated().map { actIdx, act in
            let scenes = act.segments.enumerated().map { segIdx, seg in
                EditableSceneSegment(sceneIndex: segIdx, start: seg.start, end: seg.end)
            }
            return EditableActModel(
                id: act.id,
                actIndex: actIdx,
                type: act.type,
                title: act.title,
                dramaticBeat: act.dramaticBeat,
                scenes: scenes
            )
        }
    }

    private func applyChangesAndProceed() {
        var updatedActs: [LongformAct] = []
        for act in editedActs {
            let segs = act.scenes.map { TimeSegment(start: $0.start, end: $0.end) }
            updatedActs.append(LongformAct(
                type: act.type,
                title: act.title,
                dramaticBeat: act.dramaticBeat,
                segments: segs
            ))
        }

        let updatedArc = LongformNarrativeArc(
            id: arc.id,
            movieTitle: arc.movieTitle,
            concept: arc.concept,
            acts: updatedActs,
            summary: arc.summary,
            mood: arc.mood
        )

        onApply(updatedArc)
    }

    private func phrasesFor(start: Double, end: Double) -> [TranscriptSegment] {
        transcriptSegments.filter { $0.end > start && $0.start < end }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatDurationWithTenths(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let tenths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    private func formatTimecode(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let tenths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }
}
