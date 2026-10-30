import AVFoundation
import AVKit
import SwiftUI

/// Редактируемая сцена внутри акта
struct EditableSceneSegment: Identifiable, Equatable {
    let id: UUID
    let sceneIndex: Int
    let isAdded: Bool
    let manualSourceRange: TimeSegment?
    var start: Double
    var end: Double
    let originalStart: Double
    let originalEnd: Double

    init(id: UUID = UUID(), sceneIndex: Int, start: Double, end: Double,
         isAdded: Bool = false, manualSourceRange: TimeSegment? = nil) {
        self.id = id
        self.sceneIndex = sceneIndex
        self.isAdded = isAdded
        self.manualSourceRange = manualSourceRange
        self.start = start
        self.end = end
        self.originalStart = start
        self.originalEnd = end
    }

    var duration: Double {
        max(0.0, end - start)
    }

    var isEdited: Bool {
        isAdded || abs(start - originalStart) > 0.05 || abs(end - originalEnd) > 0.05
    }

    var diffDuration: Double {
        duration - (originalEnd - originalStart)
    }
}

private struct SceneInsertionTarget: Identifiable {
    let id = UUID()
    let actIndex: Int
    let index: Int
}

/// Редактируемый акт драматургической структуры
struct EditableActModel: Identifiable, Equatable {
    let id: String
    let actIndex: Int
    let type: LongformActType
    var title: String
    var dramaticBeat: String
    /// Провенанс названия акта — переносится через пересборку арки, иначе редактор
    /// молча терял бы метку «это вывела модель» и UI врал бы про источник.
    var titleProvenance: ActTitleProvenance?
    var scenes: [EditableSceneSegment]

    /// Название акта в глазах UI — то же единственное правило, что у `LongformAct`:
    /// отсутствие поля это `.unknown`, а не «его вывела модель». Своя формулировка
    /// с дефолтом позволяла бы редактору показывать другую метку, чем экран результата.
    var effectiveTitleSource: ActTitleSource { titleProvenance?.source ?? .unknown }

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
    let coldOpenEnabled: Bool
    let onReview: (LongformNarrativeArc) async throws -> LongformNarrativeArc
    let onApply: (LongformNarrativeArc) -> Void
    let onCancel: () -> Void

    @State private var editedActs: [EditableActModel] = []
    @State private var selectedActIndex: Int = 0
    @State private var sourceDuration: Double = .infinity
    @State private var previewPlayer: AVPlayer?
    @State private var previewStopTask: Task<Void, Never>?
    @State private var publicationTitle = ""
    @State private var hookText = ""
    @State private var conclusionText = ""
    @State private var ctaText = ""
    @State private var insertionTarget: SceneInsertionTarget?
    @State private var isReviewing = false
    @State private var reviewMessage: String?
    @State private var reviewedArc: LongformNarrativeArc?

    private let minSceneDuration = EssayDurationPolicy.sceneLength.lowerBound

    init(
        arc: LongformNarrativeArc,
        concept: ThematicConcept,
        movieTitle: String,
        transcriptSegments: [TranscriptSegment],
        sourceURL: URL? = nil,
        coldOpenEnabled: Bool = true,
        onReview: @escaping (LongformNarrativeArc) async throws -> LongformNarrativeArc = { $0 },
        onApply: @escaping (LongformNarrativeArc) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.arc = arc
        self.concept = concept
        self.movieTitle = movieTitle
        self.transcriptSegments = transcriptSegments
        self.sourceURL = sourceURL
        self.coldOpenEnabled = coldOpenEnabled
        self.onReview = onReview
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private var totalDuration: Double {
        var candidate = arc
        candidate.acts = editedActs.map { act in
            LongformAct(type: act.type, title: act.title, dramaticBeat: act.dramaticBeat,
                        segments: act.scenes.map { TimeSegment(start: $0.start, end: $0.end) })
        }
        candidate.conclusionText = conclusionText
        candidate.ctaText = ctaText
        return LongformTimeline(arc: candidate, coldOpenEnabled: coldOpenEnabled).duration
    }

    private var originalTotalDuration: Double {
        LongformTimeline(arc: arc, coldOpenEnabled: coldOpenEnabled).duration
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
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .onAppear {
            loadInitialActs()
            preparePreviewPlayer()
        }
        .sheet(item: $insertionTarget) { target in
            LongformSceneInsertSheet(
                transcriptSegments: transcriptSegments,
                existingRanges: editedActs.flatMap { $0.scenes.map { TimeSegment(start: $0.start, end: $0.end) } },
                sourceURL: sourceURL,
                sourceDuration: sourceDuration,
                onInsert: { range in insertScene(range, at: target) }
            )
            .frame(minWidth: 680, minHeight: 600)
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
                        .background(StudioTheme.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(StudioTheme.accent)

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
                .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.raised))

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
                .tint(StudioTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(editingProblem != nil)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(StudioTheme.panel)
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
                            .fill(isSelected ? StudioTheme.accent : (act.isEdited ? StudioTheme.success : Color.secondary.opacity(0.4)))
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("АКТ \(idx + 1)")
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(isSelected ? StudioTheme.accent : .secondary)

                                if act.isEdited {
                                    Text("✓")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                }
                            }

                            Text(act.type.displayName)
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
                            .fill(isSelected ? StudioTheme.accent.opacity(0.12) : StudioTheme.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? StudioTheme.accent.opacity(0.45) : StudioTheme.line, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(StudioTheme.panel)
    }

    // MARK: - Act Detail Editor

    @ViewBuilder
    private func actDetailEditor(actIndex: Int) -> some View {
        let act = editedActs[actIndex]

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup("Хук, вывод и текст публикации") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название YouTube", text: $publicationTitle)
                        let suspicious = UkrainianTextReview.suspiciousWords(in: publicationTitle)
                        if !suspicious.isEmpty {
                            Text("Проверьте написание: " + suspicious.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        TextField("Вступительный вопрос", text: $hookText)
                        TextField("Вывод эссе", text: $conclusionText)
                        TextField("Призыв к обсуждению", text: $ctaText)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
                }
                if let problem = editingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let notes = (reviewedArc ?? arc).editorialNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        DisclosureGroup("Замечания редактора (\(notes.count))") {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                                Text("• " + note).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.top, 4)
                        }
                        HStack(spacing: 10) {
                            Button {
                                runEditorialReview()
                            } label: {
                                Label(isReviewing ? "Модель проверяет сцены…" : "Проверить и исправить замечания",
                                      systemImage: isReviewing ? "hourglass" : "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(StudioTheme.accent)
                            .disabled(isReviewing)
                            if let reviewMessage {
                                Text(reviewMessage).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let reviewMessage, (reviewedArc ?? arc).editorialNotes?.isEmpty == true {
                    Label(reviewMessage, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Карточка темы акта
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("АКТ \(actIndex + 1): \(act.type.displayName.uppercased())")
                                .font(.caption.weight(.black))
                                .foregroundStyle(StudioTheme.accent)

                            Text("•")
                                .foregroundStyle(.secondary)

                            Text(act.title)
                                .font(.headline)
                        }

                        // Провенанс названия: честная подпись под строкой, которую зритель судит
                        // как «работу ИИ». На видео её нет — раскладка эссе заморожена, отчётность
                        // живёт только здесь. Бейдж описывает ровно ту строку, что показана выше:
                        // источник из провенанса акта, а не из анализа целиком и не из дефолта.
                        HStack(spacing: 5) {
                            Image(systemName: act.effectiveTitleSource.isTrustworthy
                                  ? "checkmark.seal" : "exclamationmark.seal")
                                .font(.caption2)
                            Text(act.effectiveTitleSource.displayCaption)
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                        .help(Self.titleSourceHelp(for: act))

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

                    insertionButton(actIndex: actIndex, index: 0, title: "Добавить сцену в начало акта")

                    ForEach(0..<act.scenes.count, id: \.self) { sceneIdx in
                        sceneTrimmerCard(actIndex: actIndex, sceneIndex: sceneIdx)
                        insertionButton(actIndex: actIndex, index: sceneIdx + 1,
                                        title: sceneIdx == act.scenes.count - 1
                                            ? "Добавить сцену в конец акта"
                                            : "Вставить сцену после сцены \(sceneIdx + 1)")
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
                        .foregroundStyle(StudioTheme.accent)

                    if abs(scene.diffDuration) > 0.1 {
                        Text(String(format: "(%@%.1fc)", scene.diffDuration > 0 ? "+" : "", scene.diffDuration))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(scene.diffDuration >= 0 ? .green : .orange)
                    }
                }

                Spacer()

                if scene.isEdited {
                        Text(scene.isAdded ? "Добавлена вручную" : "Отредактировано")
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
                            .foregroundStyle(StudioTheme.accent)
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
                            .foregroundStyle(StudioTheme.accent)
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
        .tint(delta > 0 ? StudioTheme.accent : .secondary)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.accent.opacity(0.08)))
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
        let anchor = sceneAnchor(actIndex: actIndex, sceneIndex: sceneIndex)
        let startLower = max(0, anchor.start - 8, scene.end - 40)
        let startUpper = max(startLower + 0.01, min(anchor.start + 8, scene.end - minSceneDuration))
        let endLower = max(anchor.end - 8, scene.start + minSceneDuration)
        let maxBound = max(endLower + 0.01, min(anchor.end + 8, scene.start + 40, sourceDuration))

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
                    in: startLower...startUpper
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
        let anchor = sceneAnchor(actIndex: actIndex, sceneIndex: sceneIndex)
        let lower = max(0, anchor.start - 8, current.end - 40)
        let upper = min(anchor.start + 8, current.end - minSceneDuration)
        guard upper >= lower else { return }
        current.start = min(max(lower, value), upper)
        editedActs[actIndex].scenes[sceneIndex] = current
    }

    private func setEnd(actIndex: Int, sceneIndex: Int, value: Double) {
        var current = editedActs[actIndex].scenes[sceneIndex]
        let anchor = sceneAnchor(actIndex: actIndex, sceneIndex: sceneIndex)
        let lower = max(anchor.end - 8, current.start + minSceneDuration)
        let upper = min(anchor.end + 8, current.start + 40, sourceDuration)
        guard upper >= lower else { return }
        current.end = min(max(lower, value), upper)
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
        let originalScenes = editableScenes(for: originalAct)
        editedActs[actIndex].scenes = originalScenes
        reviewedArc = nil
        reviewMessage = nil
    }

    private func resetAllActs() {
        loadInitialActs()
        reviewedArc = nil
        reviewMessage = nil
    }

    private func loadInitialActs() {
        publicationTitle = arc.publicationTitle ?? arc.concept.suggestedTitle
        hookText = arc.hookText ?? ""
        conclusionText = arc.conclusionText ?? ""
        ctaText = arc.ctaText ?? ""
        editedActs = arc.acts.enumerated().map { actIdx, act in
            return EditableActModel(
                id: act.id,
                actIndex: actIdx,
                type: act.type,
                title: act.title,
                dramaticBeat: act.dramaticBeat,
                titleProvenance: act.titleProvenance,
                scenes: editableScenes(for: act)
            )
        }
    }

    private func editableScenes(for act: LongformAct) -> [EditableSceneSegment] {
        act.segments.enumerated().map { index, segment in
            let manualSource = arc.sceneEdits?.first(where: {
                $0.role == act.type && $0.revised == segment
                    && $0.reason == LongformSceneEdit.manualAdditionReason
            })?.original
            return EditableSceneSegment(sceneIndex: manualSource == nil ? index : -1,
                start: segment.start, end: segment.end, isAdded: manualSource != nil,
                manualSourceRange: manualSource)
        }
    }

    private func applyChangesAndProceed() {
        onApply(draftArc())
    }

    private func sceneAnchor(actIndex: Int, sceneIndex: Int) -> TimeSegment {
        let scene = editedActs[actIndex].scenes[sceneIndex]
        if scene.isAdded {
            return scene.manualSourceRange ?? TimeSegment(start: scene.start, end: scene.end)
        }
        guard arc.acts.indices.contains(actIndex), arc.acts[actIndex].segments.indices.contains(scene.sceneIndex) else {
            return TimeSegment(start: scene.start, end: scene.end)
        }
        let range = arc.acts[actIndex].segments[scene.sceneIndex]
        return LongformEditorialSupport.anchor(for: range, role: arc.acts[actIndex].type, in: arc)
    }

    private func insertionButton(actIndex: Int, index: Int, title: String) -> some View {
        Button {
            insertionTarget = SceneInsertionTarget(actIndex: actIndex, index: index)
        } label: {
            Label(title, systemImage: "plus.circle")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTheme.accent)
        .padding(.vertical, 2)
    }

    private func insertScene(_ range: TimeSegment, at target: SceneInsertionTarget) {
        guard editedActs.indices.contains(target.actIndex),
              EssayDurationPolicy.sceneLength.contains(range.duration),
              sourceDuration.isFinite ? range.end <= sourceDuration : true else { return }
        let allRanges = editedActs.flatMap { $0.scenes.map { TimeSegment(start: $0.start, end: $0.end) } }
        guard allRanges.allSatisfy({ $0.end <= range.start || range.end <= $0.start }) else { return }
        let scene = EditableSceneSegment(sceneIndex: -1, start: range.start, end: range.end,
                                         isAdded: true, manualSourceRange: range)
        let position = min(max(target.index, 0), editedActs[target.actIndex].scenes.count)
        editedActs[target.actIndex].scenes.insert(scene, at: position)
        selectedActIndex = target.actIndex
        reviewedArc = nil
        reviewMessage = nil
    }

    private func draftArc() -> LongformNarrativeArc {
        var updatedArc = reviewedArc ?? arc
        updatedArc.acts = editedActs.map { act in
            LongformAct(type: act.type, title: act.title, dramaticBeat: act.dramaticBeat,
                        segments: act.scenes.map { TimeSegment(start: $0.start, end: $0.end) },
                        titleProvenance: act.titleProvenance)
        }

        var sceneEdits = updatedArc.sceneEdits ?? []
        for (actIndex, act) in editedActs.enumerated() where arc.acts.indices.contains(actIndex) {
            for scene in act.scenes {
                let revised = TimeSegment(start: scene.start, end: scene.end)
                if scene.isAdded {
                    let source = scene.manualSourceRange ?? revised
                    sceneEdits.removeAll {
                        $0.role == act.type && $0.original == source
                            && $0.reason == LongformSceneEdit.manualAdditionReason
                    }
                    sceneEdits.append(LongformSceneEdit(role: act.type, original: source, revised: revised,
                        reason: LongformSceneEdit.manualAdditionReason))
                    continue
                }
                guard arc.acts[actIndex].segments.indices.contains(scene.sceneIndex) else { continue }
                let original = arc.acts[actIndex].segments[scene.sceneIndex]
                let anchor = LongformEditorialSupport.anchor(for: original, role: act.type, in: arc)
                sceneEdits.removeAll { $0.role == act.type && $0.original == anchor }
                if revised != original {
                    sceneEdits.append(LongformSceneEdit(role: act.type, original: anchor, revised: revised,
                        reason: "Границы изменены пользователем в монтажном столе"))
                }
            }
        }
        updatedArc.sceneEdits = sceneEdits.isEmpty ? nil : sceneEdits
        updatedArc.publicationTitle = publicationTitle.trimmed
        updatedArc.hookText = hookText.trimmed
        updatedArc.conclusionText = conclusionText.trimmed
        updatedArc.ctaText = ctaText.trimmed
        return updatedArc
    }

    private func runEditorialReview() {
        guard !isReviewing else { return }
        isReviewing = true
        reviewMessage = nil
        let draft = draftArc()
        Task { @MainActor in
            defer { isReviewing = false }
            do {
                let result = try await onReview(draft)
                guard result.acts.count == editedActs.count,
                      zip(result.acts, editedActs).allSatisfy({ $0.0.segments.count == $0.1.scenes.count }) else {
                    reviewMessage = "Ответ модели не совпал со сценами. Монтаж сохранён."
                    return
                }
                for (actIndex, reviewedAct) in result.acts.enumerated() {
                    for (sceneIndex, range) in reviewedAct.segments.enumerated() {
                        editedActs[actIndex].scenes[sceneIndex].start = range.start
                        editedActs[actIndex].scenes[sceneIndex].end = range.end
                    }
                }
                reviewedArc = result
                let unresolved = result.editorialNotes?.count ?? 0
                reviewMessage = result.editorialReviewModelID == nil
                    ? "Модель не применила проверенные правки; монтаж сохранён."
                    : (unresolved == 0 ? "Проверка завершена, замечаний не осталось."
                       : "Проверка завершена; осталось замечаний: \(unresolved).")
            } catch {
                reviewMessage = "Не удалось запустить проверку: \(error.localizedDescription)"
            }
        }
    }

    private var editingProblem: String? {
        var candidate = arc
        candidate.acts = editedActs.map { act in
            LongformAct(type: act.type, title: act.title, dramaticBeat: act.dramaticBeat,
                        segments: act.scenes.map { TimeSegment(start: $0.start, end: $0.end) })
        }
        candidate.conclusionText = conclusionText
        candidate.ctaText = ctaText
        if !EssayDurationPolicy.rendered.contains(LongformTimeline(arc: candidate, coldOpenEnabled: coldOpenEnabled).duration) {
            return "После правок эссе должно оставаться в пределах 4:00–8:00."
        }
        let scenes = candidate.segments.sorted { $0.start < $1.start }
        if zip(scenes, scenes.dropFirst()).contains(where: { $0.end > $1.start }) {
            return "Сцены пересекаются: один фрагмент фильма попадёт в ролик дважды."
        }
        for (ai, act) in candidate.acts.enumerated() {
            for (si, range) in act.segments.enumerated() {
                if !LongformEditorialSupport.allowed(range, around: sceneAnchor(actIndex: ai, sceneIndex: si)) {
                    return "Сцена должна длиться 18–40 с; локальная правка границ — не более 8 с."
                }
            }
        }
        if publicationTitle.count > 120 || hookText.count > 180 || conclusionText.count > 140 || ctaText.count > 200 {
            return "Сократите текст: название до 120, хук до 180, вывод до 140, CTA до 200 символов."
        }
        return nil
    }

    /// Подсказка обязана описывать ровно тот артефакт, под которым висит: «источник
    /// не зафиксирован» верно только для `.unknown`, а для `.template` источник
    /// записан — просто реплики-доказательства у него нет.
    static func titleSourceHelp(for act: EditableActModel) -> String {
        switch act.effectiveTitleSource {
        case .llm, .transcriptLine:
            return act.titleProvenance?.evidence
                ?? "Реплика-основание не записана: метка есть, доказать её нечем"
        case .template:
            return "Название дала формула темы — ни модель, ни реплика акта его не выводили"
        case .unknown:
            return "Источник названия не зафиксирован"
        }
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
