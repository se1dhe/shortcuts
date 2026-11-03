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
    let initialMusicSettings: LongformAudioSettings
    @State private var musicSettings: LongformAudioSettings
    @State private var showMusicEditor = false
    let onReview: (LongformNarrativeArc, @Sendable (String) -> Void) async throws -> LongformEditorialReview.Outcome
    let onApply: (LongformNarrativeArc) -> Void
    let onCancel: () -> Void

    @State private var editedActs: [EditableActModel] = []
    @State private var selectedActIndex: Int = 0
    @State private var selectedSceneID: UUID?
    @State private var sourceDuration: Double = .infinity
    @State private var timelinePlayback = MontageTimelinePlayback()
    private var previewPlayer: AVPlayer? { timelinePlayback.player }
    private var previewAudio: MontageScenePreviewAudio { timelinePlayback.audio }
    private var isPreviewBusy: Bool { timelinePlayback.isPreparing }
    @State private var previewError: String?
    @State private var publicationTitle = ""
    @State private var publicationWord = ""
    @State private var coverText = ""
    @State private var viewerPromise = ""
    @State private var hookText = ""
    @State private var conclusionText = ""
    @State private var ctaText = ""
    @State private var insertionTarget: SceneInsertionTarget?
    @State private var isReviewing = false
    @State private var reviewMessage: String?
    @State private var reviewedArc: LongformNarrativeArc?
    @State private var reviewProgress = ""
    @State private var reviewAttempts: [LongformEditorialReview.Attempt] = []
    @State private var reviewEvents: [String] = []
    @State private var reviewChanges: [LongformEditorialReview.SceneChange] = []
    @State private var inTrimStepInput = "0,3"
    @State private var outTrimStepInput = "0,3"

    private let minimumRenderableClipDuration = 0.1

    init(
        arc: LongformNarrativeArc,
        concept: ThematicConcept,
        movieTitle: String,
        transcriptSegments: [TranscriptSegment],
        sourceURL: URL? = nil,
        coldOpenEnabled: Bool = true,
        audioSettings: LongformAudioSettings = LongformAudioSettings(),
        onReview: @escaping (LongformNarrativeArc, @Sendable (String) -> Void) async throws -> LongformEditorialReview.Outcome = { arc, _ in
            LongformEditorialReview.Outcome(arc: arc, attempts: [], changes: [])
        },
        onApply: @escaping (LongformNarrativeArc) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.arc = arc
        self.concept = concept
        self.movieTitle = movieTitle
        self.transcriptSegments = transcriptSegments
        self.sourceURL = sourceURL
        self.coldOpenEnabled = coldOpenEnabled
        self.initialMusicSettings = arc.musicSettings ?? audioSettings
        _musicSettings = State(initialValue: arc.musicSettings ?? audioSettings)
        self.onReview = onReview
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private var musicTimelineArc: LongformNarrativeArc {
        var candidate = arc
        candidate.acts = editedActs.map { act in
            LongformAct(type: act.type, title: act.title, dramaticBeat: act.dramaticBeat,
                        segments: act.scenes.map { TimeSegment(start: $0.start, end: $0.end) })
        }
        candidate.conclusionText = conclusionText
        candidate.ctaText = ctaText
        return candidate
    }

    private var totalDuration: Double {
        LongformTimeline(arc: musicTimelineArc, coldOpenEnabled: coldOpenEnabled).duration
    }

    private var musicSpeechIntervals: [TimeSegment] {
        let timeline = LongformTimeline(arc: musicTimelineArc, coldOpenEnabled: coldOpenEnabled)
        return timeline.placements.flatMap { placement in
            transcriptSegments.compactMap { line -> TimeSegment? in
                let start = max(line.start, placement.source.start)
                let end = min(line.end, placement.source.end)
                guard end > start else { return nil }
                return TimeSegment(start: placement.start + start - placement.source.start,
                                   end: placement.start + end - placement.source.start)
            }
        }
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

    private var selectedLocation: (actIndex: Int, sceneIndex: Int, scene: EditableSceneSegment)? {
        if let selectedSceneID {
            for (actIndex, act) in editedActs.enumerated() {
                if let sceneIndex = act.scenes.firstIndex(where: { $0.id == selectedSceneID }) {
                    return (actIndex, sceneIndex, act.scenes[sceneIndex])
                }
            }
        }
        for (actIndex, act) in editedActs.enumerated() where !act.scenes.isEmpty {
            return (actIndex, 0, act.scenes[0])
        }
        return nil
    }

    private var sequenceClips: [EditorTimelineClip] {
        editedActs.enumerated().flatMap { actIndex, act in
            act.scenes.enumerated().map { sceneIndex, scene in
                let dialogue = phrasesFor(start: scene.start, end: scene.end).first?.text
                return EditorTimelineClip(id: scene.id, start: scene.start, end: scene.end,
                    isAdded: scene.isAdded, actNumber: actIndex + 1, actTitle: act.title,
                    sceneNumber: sceneIndex + 1, quote: dialogue)
            }
        }
    }

    private var completedReviewEvents: [String] {
        isReviewing ? Array(reviewEvents.dropLast()) : reviewEvents
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            actTabsBar
            HStack {
                Label(musicSettings.backgroundMusicURL?.deletingPathExtension().lastPathComponent ?? L10n.tr("Без музыкальной подложки"), systemImage: "music.note")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
                Spacer()
                Button(L10n.tr("Музыка и сведение"), systemImage: "waveform") { stopPreview(); showMusicEditor = true }
                    .buttonStyle(.bordered)
            }.padding(.horizontal, 22).padding(.vertical, 8)
            if !editedActs.isEmpty && selectedActIndex < editedActs.count {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        monitorPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        sceneInspectorPanel
                            .frame(width: 410)
                    }
                    .frame(maxHeight: .infinity)

                    EditorTimelineView(
                        clips: sequenceClips,
                        selectedID: selectedSceneID,
                        onSelect: selectScene,
                        onInsertAt: insertAtSequencePosition,
                        onMoveEarlier: { moveSceneAcrossSequence($0, delta: -1) },
                        onMoveLater: { moveSceneAcrossSequence($0, delta: 1) },
                        onRemove: removeScene,
                        onTrimStart: trimSceneStart,
                        onTrimEnd: trimSceneEnd,
                        playhead: timelinePlayback.currentTime,
                        isPlaying: timelinePlayback.isPlaying,
                        onTogglePlayback: { timelinePlayback.toggle() },
                        onSeek: { timelinePlayback.scrub(to: $0, editing: $1) }
                    )
                    .frame(height: 196)
                }
                .padding(18)
            } else {
                ContentUnavailableView(L10n.tr("Нет актов для редактирования"), systemImage: "film.stack")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isReviewing || !reviewEvents.isEmpty { OperationLogPanel(isActive: isReviewing) }
        }
        .frame(minWidth: 1320, minHeight: 900)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .onAppear {
            loadInitialActs()
            preparePreviewPlayer()
        }
        .sheet(isPresented: $showMusicEditor) {
            MusicBedEditor(settings: $musicSettings, duration: totalDuration,
                suggestedEnvelope: MusicBedMixing.storyEnvelope(for: musicTimelineArc, coldOpenEnabled: coldOpenEnabled),
                speechIntervals: musicSpeechIntervals)
        }
        .sheet(item: $insertionTarget) { target in
            LongformSceneInsertSheet(
                transcriptSegments: transcriptSegments,
                existingRanges: editedActs.flatMap { $0.scenes.map { TimeSegment(start: $0.start, end: $0.end) } },
                allowOverlap: true,
                sourceURL: sourceURL,
                sourceDuration: sourceDuration,
                player: previewPlayer,
                previewAudio: previewAudio,
                onInsert: { range in insertScene(range, at: target) }
            )
            .frame(minWidth: 680, minHeight: 600)
        }
        .onChange(of: editedActs) { _, _ in timelinePlayback.setClips(sequenceClips) }
        .onChange(of: timelinePlayback.activeClipID) { _, id in
            guard let id, let location = sequenceLocation(for: id) else { return }
            selectedSceneID = id; selectedActIndex = location.actIndex
        }
        .onChange(of: timelinePlayback.error) { _, message in
            if let message { previewError = message }
        }
        .onDisappear { timelinePlayback.close() }
        .alert(L10n.tr("Предпросмотр не запустился"), isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button(L10n.tr("Понятно"), role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? L10n.tr("Не удалось воспроизвести выбранный фрагмент."))
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 16) {
            Button {
                onCancel()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "xmark")
                    Text(L10n.tr("Отмена"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Rectangle()
                .fill(StudioTheme.line)
                .frame(width: 1, height: 38)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(L10n.tr("МОНТАЖНЫЙ СТОЛ"))
                        .font(.system(size: 10, weight: .black)).tracking(1.05)

                    Text("«\(concept.displayWord.uppercased())»")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(StudioTheme.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(StudioTheme.accent)

                    if totalEditedCount > 0 {
                        Label(L10n.tr("Изменено актов: %1$@", String(describing: totalEditedCount)), systemImage: "pencil.line")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(StudioTheme.success.opacity(0.12), in: Capsule())
                            .foregroundStyle(StudioTheme.success)
                    }
                }

                Text(movieTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L10n.tr("ХРОНОМЕТРАЖ"))
                        .font(.system(size: 8, weight: .bold)).tracking(0.9)
                        .foregroundStyle(StudioTheme.muted)
                    Text(formatDuration(totalDuration))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                    if abs(totalDiffSeconds) > 0.1 {
                        Text(String(format: L10n.tr("%@%.1f с к исходному"), totalDiffSeconds > 0 ? "+" : "", totalDiffSeconds))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(totalDiffSeconds >= 0 ? StudioTheme.success : StudioTheme.warning)
                    }
                }
                .frame(minWidth: 124, alignment: .trailing)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 10))

                Button {
                    resetAllActs()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(totalEditedCount == 0)
                .help(L10n.tr("Сбросить все изменения"))
                .accessibilityLabel(L10n.tr("Сбросить всё"))

                Button {
                    applyChangesAndProceed()
                } label: {
                    Label(L10n.tr("Сохранить монтаж"), systemImage: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 3)
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(editingProblem != nil)
                .help(L10n.tr("Сохранить правки и пересобрать выпуск"))
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
                    selectAct(idx)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isSelected ? StudioTheme.accent : (act.isEdited ? StudioTheme.success : Color.secondary.opacity(0.4)))
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(L10n.tr("АКТ %1$@", String(describing: idx + 1)))
                                    .font(.caption2.weight(.black))
                                    .foregroundStyle(isSelected ? StudioTheme.accent : .secondary)

                                if act.isEdited {
                                    Text("✓")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.green)
                                }
                            }

                            Text(L10n.tr(act.type.displayName))
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

    private var monitorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("МОНИТОР ИСХОДНИКА"))
                        .font(.system(size: 10, weight: .black)).tracking(1.1)
                        .foregroundStyle(StudioTheme.accent)
                    if let selection = selectedLocation {
                        Text(L10n.tr("АКТ %1$@ · СЦЕНА %2$@", String(describing: selection.actIndex + 1), String(describing: selection.sceneIndex + 1)))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(StudioTheme.muted)
                    }
                }
                Spacer()
                if let selection = selectedLocation {
                    Text(L10n.tr("ФИЛЬМ  %1$@ → %2$@", String(describing: formatTimecode(selection.scene.start)), String(describing: formatTimecode(selection.scene.end))))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            Group {
                if let previewPlayer {
                    StudioPlayerSurface(player: previewPlayer)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(StudioTheme.line, lineWidth: 1))
                } else {
                    ContentUnavailableView(L10n.tr("Нет исходного видео"), systemImage: "film")
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 11))
                }
            }

            HStack(spacing: 8) {
                Button {
                    if let scene = selectedLocation?.scene { playRange(start: scene.start, end: scene.end) }
                } label: {
                    Label(isPreviewBusy ? L10n.tr("Идёт предпросмотр") : L10n.tr("Сцена"),
                          systemImage: isPreviewBusy ? "waveform" : "play.fill")
                }
                .buttonStyle(.borderedProminent).tint(StudioTheme.accent)
                .disabled(selectedLocation == nil || previewPlayer == nil || isPreviewBusy)

                if isPreviewBusy {
                    Button(L10n.tr("Стоп"), systemImage: "stop.fill", action: stopPreview)
                        .buttonStyle(.bordered)
                }

                Button {
                    if let scene = selectedLocation?.scene {
                        playRange(start: scene.start, end: min(scene.start + 4, scene.end))
                    }
                } label: { Label(L10n.tr("Вход"), systemImage: "arrow.right.to.line") }
                    .buttonStyle(.bordered).disabled(selectedLocation == nil || previewPlayer == nil || isPreviewBusy)

                Button {
                    if let scene = selectedLocation?.scene {
                        playRange(start: max(scene.start, scene.end - 4), end: scene.end)
                    }
                } label: { Label(L10n.tr("Выход"), systemImage: "arrow.left.to.line") }
                    .buttonStyle(.bordered).disabled(selectedLocation == nil || previewPlayer == nil || isPreviewBusy)

                Spacer()
                Text(selectedLocation.map { formatDurationWithTenths($0.scene.duration) } ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(StudioTheme.accent)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(StudioTheme.line, lineWidth: 1))
    }

    private var sceneInspectorPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if let selection = selectedLocation {
                    let act = editedActs[selection.actIndex]
                    let scene = selection.scene
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(L10n.tr("ИНСПЕКТОР СЦЕНЫ"), systemImage: "slider.horizontal.3")
                                .font(.system(size: 10, weight: .black)).tracking(1)
                                .foregroundStyle(StudioTheme.accent)
                            Spacer()
                            if scene.isEdited {
                                Text(scene.isAdded ? L10n.tr("ВСТАВЛЕНА") : L10n.tr("ИЗМЕНЕНА"))
                                    .font(.system(size: 8, weight: .black)).tracking(0.5)
                                    .foregroundStyle(StudioTheme.success)
                            }
                        }
                        Text(L10n.tr("Акт %1$@ · Сцена %2$@", String(describing: selection.actIndex + 1), String(describing: selection.sceneIndex + 1)))
                            .font(.title3.weight(.bold))
                        Text(act.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        Text(act.dramaticBeat).font(.caption).foregroundStyle(StudioTheme.muted).lineLimit(3)
                    }
                    .padding(13)
                    .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 11))

                    boundaryRow(title: L10n.tr("IN · НАЧАЛО"), value: scene.start, icon: "arrow.right.to.line",
                        play: { playRange(start: scene.start, end: min(scene.start + 4, scene.end)) },
                        decrement: { adjustStart(actIndex: selection.actIndex, sceneIndex: selection.sceneIndex, delta: -trimStep(from: inTrimStepInput)) },
                        increment: { adjustStart(actIndex: selection.actIndex, sceneIndex: selection.sceneIndex, delta: trimStep(from: inTrimStepInput)) },
                        stepInput: $inTrimStepInput, trimsScene: false)
                    boundaryRow(title: L10n.tr("OUT · КОНЕЦ"), value: scene.end, icon: "arrow.left.to.line",
                        play: { playRange(start: max(scene.start, scene.end - 4), end: scene.end) },
                        decrement: { adjustEnd(actIndex: selection.actIndex, sceneIndex: selection.sceneIndex, delta: -trimStep(from: outTrimStepInput)) },
                        increment: { adjustEnd(actIndex: selection.actIndex, sceneIndex: selection.sceneIndex, delta: trimStep(from: outTrimStepInput)) },
                        stepInput: $outTrimStepInput, trimsScene: true)

                    if let first = phrasesFor(start: scene.start, end: scene.end).first {
                        dialogueExcerpt(title: L10n.tr("ПЕРВАЯ РЕПЛИКА"), phrase: first)
                    }
                    if let last = phrasesFor(start: scene.start, end: scene.end).last,
                       last.start != phrasesFor(start: scene.start, end: scene.end).first?.start {
                        dialogueExcerpt(title: L10n.tr("ПОСЛЕДНЯЯ РЕПЛИКА"), phrase: last)
                    }

                    DisclosureGroup(L10n.tr("Точная подрезка и список реплик")) {
                        VStack(alignment: .leading, spacing: 10) {
                            sceneRangeSliders(actIndex: selection.actIndex, sceneIndex: selection.sceneIndex)
                            Divider()
                            ForEach(phrasesFor(start: scene.start, end: scene.end), id: \.start) { phrase in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(formatTimecode(phrase.start)).font(.caption2.monospacedDigit())
                                        .foregroundStyle(StudioTheme.muted).frame(width: 58, alignment: .leading)
                                    Text(phrase.text).font(.caption).foregroundStyle(.primary)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(11)
                    .background(StudioTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 7) {
                        Button { moveScene(scene.id, in: selection.actIndex, delta: -1) } label: {
                            Label(L10n.tr("Раньше"), systemImage: "arrow.left")
                        }.disabled(selection.sceneIndex == 0)
                        Button { moveScene(scene.id, in: selection.actIndex, delta: 1) } label: {
                            Label(L10n.tr("Позже"), systemImage: "arrow.right")
                        }.disabled(selection.sceneIndex + 1 >= act.scenes.count)
                        Spacer(minLength: 0)
                        Button(role: .destructive) { removeScene(scene.id) } label: {
                            Image(systemName: "trash")
                        }
                        .help(L10n.tr("Удалить фрагмент из монтажа"))
                        .disabled(act.scenes.count <= 1)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    ContentUnavailableView(L10n.tr("Нет выбранной сцены"), systemImage: "film")
                }

                editorialReviewPanel
                publicationTextPanel
            }
            .padding(12)
        }
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(StudioTheme.line, lineWidth: 1))
    }

    private func boundaryRow(title: String, value: Double, icon: String,
                             play: @escaping () -> Void, decrement: @escaping () -> Void,
                             increment: @escaping () -> Void, stepInput: Binding<String>,
                             trimsScene: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(StudioTheme.muted)
                Spacer()
                Text(formatTimecode(value))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Text(L10n.tr("Сдвиг в секундах · %1$@", String(describing: trimsScene ? L10n.tr("− короче · + длиннее") : L10n.tr("− длиннее · + короче"))))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(StudioTheme.muted)
            HStack(spacing: 8) {
                Button(action: play) { Image(systemName: "play.fill") }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .disabled(isPreviewBusy)
                Spacer()
                TextField("0,3", text: stepInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .help(L10n.tr("Величина сдвига в секундах"))
                Text(L10n.tr("с")).font(.caption2).foregroundStyle(StudioTheme.muted)
                Button(L10n.tr("Применить −")) { decrement() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(L10n.tr("Сдвинуть эту границу назад по времени фильма"))
                Button(L10n.tr("Применить +")) { increment() }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(StudioTheme.accent)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(L10n.tr("Сдвинуть эту границу вперёд по времени фильма"))
            }
        }
        .padding(11)
        .background(StudioTheme.raised.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    }

    private func trimStep(from input: String) -> Double {
        let normalized = input.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return 0.2 }
        return value
    }

    private func dialogueExcerpt(title: String, phrase: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8, weight: .black)).tracking(0.8).foregroundStyle(StudioTheme.accent)
            Text("«\(phrase.text)»").font(.system(size: 11, weight: .medium)).lineLimit(3)
            Text(formatTimecode(phrase.start)).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 9))
    }

    private var editorialReviewPanel: some View {
        let notes = (reviewedArc ?? arc).editorialNotes ?? []
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(L10n.tr("РЕДАКТОРСКАЯ ПРОВЕРКА"), systemImage: "sparkles")
                    .font(.system(size: 9, weight: .black)).tracking(0.8).foregroundStyle(StudioTheme.accent)
                Spacer()
                Text(L10n.tr("%1$@ замеч.", String(describing: notes.count))).font(.system(size: 9, weight: .semibold)).foregroundStyle(StudioTheme.muted)
            }
            if !notes.isEmpty {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 7) {
                        Circle().fill(StudioTheme.warning).frame(width: 5, height: 5).padding(.top, 4)
                        Text(note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.83))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(L10n.tr("Замечаний к сценам нет. Можно запустить дополнительную проверку перед сборкой."))
                    .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
            }
            Button { runEditorialReview() } label: {
                Label(isReviewing ? L10n.tr("Ищу монтажное решение…") : L10n.tr("Проверить и исправить"),
                      systemImage: isReviewing ? "hourglass" : "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioPrimaryButtonStyle()).disabled(isReviewing)
            if isReviewing || !reviewEvents.isEmpty || reviewMessage != nil {
                VStack(alignment: .leading, spacing: 7) {
                    if isReviewing {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(reviewProgress.isEmpty ? L10n.tr("Подготовка контекста…") : reviewProgress)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
                        }
                    }
                    ForEach(Array(completedReviewEvents.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(StudioTheme.accent)
                                .padding(.top, 2)
                            Text(event).font(.system(size: 9)).foregroundStyle(StudioTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(reviewAttempts) { attempt in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: attempt.resolved ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundStyle(attempt.resolved ? StudioTheme.success : StudioTheme.warning)
                            Text(L10n.tr("Попытка %1$@: %2$@", String(describing: attempt.id), String(describing: attempt.message)))
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.primary.opacity(0.82))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let reviewMessage, !isReviewing {
                        Text(reviewMessage).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(((reviewedArc?.editorialNotes?.isEmpty ?? false) && reviewAttempts.contains(where: \.accepted))
                                ? StudioTheme.success : StudioTheme.warning)
                    }
                    ForEach(reviewChanges) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Акт %1$@ · сцена %2$@  %3$@–%4$@ → %5$@–%6$@", String(describing: change.act), String(describing: change.scene), String(describing: formatTimecode(change.oldRange.start)), String(describing: formatTimecode(change.oldRange.end)), String(describing: formatTimecode(change.newRange.start)), String(describing: formatTimecode(change.newRange.end))))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                            Text(change.reason).font(.system(size: 9)).foregroundStyle(StudioTheme.muted)
                        }
                    }
                }
                .padding(10)
                .background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(12)
        .background(StudioTheme.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
    }

    private var publicationTextPanel: some View {
        DisclosureGroup(L10n.tr("Текст выпуска и публикации")) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L10n.tr("Тема для публикации"), text: $publicationWord)
                TextField(L10n.tr("Название YouTube"), text: $publicationTitle)
                TextField(L10n.tr("Короткий текст обложки"), text: $coverText)
                TextField(L10n.tr("Что зритель поймёт после просмотра?"), text: $viewerPromise)
                TextField(L10n.tr("Вступительный вопрос"), text: $hookText)
                TextField(L10n.tr("Вывод эссе"), text: $conclusionText)
                TextField(L10n.tr("Призыв к обсуждению"), text: $ctaText)
                ForEach(editedActs.indices, id: \.self) { index in
                    TextField(L10n.tr("Название акта") + " \(index + 1)", text: Binding(
                        get: { editedActs[index].title },
                        set: { title in
                            editedActs[index].title = title
                            editedActs[index].titleProvenance = .init(source: .manual, evidence: nil, modelID: nil)
                        }))
                }
                let suspicious = UkrainianTextReview.suspiciousWords(in: publicationTitle)
                if !suspicious.isEmpty {
                    Text(L10n.tr("Проверьте написание: ") + suspicious.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(StudioTheme.warning)
                }
            }
            .textFieldStyle(.roundedBorder).padding(.top, 8)
        }
        .font(.caption.weight(.semibold))
        .padding(11)
        .background(StudioTheme.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Act Detail Editor

    @ViewBuilder
    private func actDetailEditor(actIndex: Int) -> some View {
        let act = editedActs[actIndex]

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup(L10n.tr("Хук, вывод и текст публикации")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.tr("Название YouTube"), text: $publicationTitle)
                TextField(L10n.tr("Короткий текст обложки"), text: $coverText)
                TextField(L10n.tr("Что зритель поймёт после просмотра?"), text: $viewerPromise)
                        let suspicious = UkrainianTextReview.suspiciousWords(in: publicationTitle)
                        if !suspicious.isEmpty {
                            Text(L10n.tr("Проверьте написание: ") + suspicious.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        TextField(L10n.tr("Вступительный вопрос"), text: $hookText)
                        TextField(L10n.tr("Вывод эссе"), text: $conclusionText)
                        TextField(L10n.tr("Призыв к обсуждению"), text: $ctaText)
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
                        DisclosureGroup(L10n.tr("Замечания редактора (%1$@)", String(describing: notes.count))) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                                Text("• " + note).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.top, 4)
                        }
                        HStack(spacing: 10) {
                            Button {
                                runEditorialReview()
                            } label: {
                                Label(isReviewing ? L10n.tr("Модель ищет решение…") : L10n.tr("Проверить и исправить замечания"),
                                      systemImage: isReviewing ? "progress.indicator" : "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(StudioTheme.accent)
                            .disabled(isReviewing)
                            if let reviewMessage {
                                Text(reviewMessage).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if isReviewing || !reviewAttempts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                if isReviewing {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text(reviewProgress.isEmpty ? L10n.tr("Готовлю замечания и контекст сцен…") : reviewProgress)
                                            .font(.caption.weight(.medium)).foregroundStyle(.primary)
                                    }
                                }
                                ForEach(Array(reviewEvents.enumerated()), id: \.offset) { _, event in
                                    Label(event, systemImage: "arrow.turn.down.right")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                ForEach(reviewAttempts) { attempt in
                                    Label(L10n.tr("Попытка %1$@: %2$@", String(describing: attempt.id), String(describing: attempt.message)),
                                          systemImage: attempt.resolved ? "checkmark.circle" : "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(attempt.resolved ? .green : .yellow)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !reviewChanges.isEmpty {
                                    Divider()
                                    Text(L10n.tr("ПРИМЕНЁННЫЕ ИЗМЕНЕНИЯ"))
                                        .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(StudioTheme.accent)
                                    ForEach(reviewChanges) { change in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(L10n.tr("Акт %1$@ · сцена %2$@: %3$@–%4$@ → %5$@–%6$@", String(describing: change.act), String(describing: change.scene), String(describing: formatTimecode(change.oldRange.start)), String(describing: formatTimecode(change.oldRange.end)), String(describing: formatTimecode(change.newRange.start)), String(describing: formatTimecode(change.newRange.end))))
                                                .font(.caption.monospacedDigit().weight(.semibold))
                                            Text(change.reason).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding(10)
                            .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(StudioTheme.line, lineWidth: 1))
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
                            Text(L10n.tr("АКТ %1$@: %2$@", String(describing: actIndex + 1), String(describing: L10n.tr(act.type.displayName).uppercased())))
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
                            Text(L10n.tr(act.effectiveTitleSource.displayCaption))
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
                        Label(L10n.tr("Сбросить акт"), systemImage: "arrow.counterclockwise")
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
                    EditorTimelineView(
                        clips: act.scenes.map { EditorTimelineClip(id: $0.id, start: $0.start, end: $0.end, isAdded: $0.isAdded) },
                        selectedID: selectedSceneID,
                        onSelect: { id in
                            selectedSceneID = id
                            if let scene = act.scenes.first(where: { $0.id == id }) {
                                playRange(start: scene.start, end: scene.end)
                            }
                        },
                        onInsertAt: { insertionTarget = SceneInsertionTarget(actIndex: actIndex, index: $0) },
                        onMoveEarlier: { moveScene($0, in: actIndex, delta: -1) },
                        onMoveLater: { moveScene($0, in: actIndex, delta: 1) },
                        onRemove: nil,
                        playhead: max(0, timelinePlayback.currentTime - editedActs.prefix(actIndex).reduce(0) { $0 + $1.duration }),
                        isPlaying: timelinePlayback.isPlaying,
                        onTogglePlayback: { timelinePlayback.toggle() },
                        onSeek: { time, editing in
                            timelinePlayback.scrub(to: editedActs.prefix(actIndex).reduce(0) { $0 + $1.duration } + time, editing: editing)
                        }
                    )

                    Text(L10n.tr("Выберите блок для точной подрезки. «+» между блоками открывает поиск сцены по транскрипту."))
                        .font(.caption).foregroundStyle(StudioTheme.muted)

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
                    Text(L10n.tr("Сцена #%1$@", String(describing: sceneIndex + 1)))
                        .font(.subheadline.weight(.bold))

                    Text(L10n.tr("Длительность: %1$@", String(describing: formatDurationWithTenths(scene.duration))))
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
                        Text(scene.isAdded ? L10n.tr("Добавлена вручную") : L10n.tr("Отредактировано"))
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
                    Label(L10n.tr("НАЧАЛО СЦЕНЫ (IN):"), systemImage: "arrow.right.to.line")
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
                        .help(L10n.tr("Проиграть вход сцены"))

                        trimButton(label: L10n.tr("-5с"), delta: -5.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: -5.0) }
                        trimButton(label: L10n.tr("-1с"), delta: -1.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: -1.0) }
                        trimButton(label: L10n.tr("-0.2с"), delta: -0.2) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: -0.2) }
                        trimButton(label: L10n.tr("+0.2с"), delta: 0.2) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: 0.2) }
                        trimButton(label: L10n.tr("+1с"), delta: 1.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: 1.0) }
                        trimButton(label: L10n.tr("+5с"), delta: 5.0) { adjustStart(actIndex: actIndex, sceneIndex: sceneIndex, delta: 5.0) }
                    }
                }

                if let firstLine = includedPhrases.first {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.accent)
                        Text(L10n.tr("Первая фраза входа:"))
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
                    Text(L10n.tr("Речь в начале сцены отсутствует (пауза/действие)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))

            // Панель 2: КОНЕЦ СЦЕНЫ (Out-Point)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L10n.tr("КОНЕЦ СЦЕНЫ (OUT):"), systemImage: "arrow.left.to.line")
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
                        .help(L10n.tr("Проиграть выход сцены"))

                        trimButton(label: L10n.tr("-5с"), delta: -5.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: -5.0) }
                        trimButton(label: L10n.tr("-1с"), delta: -1.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: -1.0) }
                        trimButton(label: L10n.tr("-0.2с"), delta: -0.2) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: -0.2) }
                        trimButton(label: L10n.tr("+0.2с"), delta: 0.2) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: 0.2) }
                        trimButton(label: L10n.tr("+1с"), delta: 1.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: 1.0) }
                        trimButton(label: L10n.tr("+5с"), delta: 5.0) { adjustEnd(actIndex: actIndex, sceneIndex: sceneIndex, delta: 5.0) }
                    }
                }

                if let lastLine = includedPhrases.last {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption2)
                            .foregroundStyle(StudioTheme.accent)
                        Text(L10n.tr("Финальная фраза выхода:"))
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
                    Text(L10n.tr("Речь в конце сцены отсутствует"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))

            sceneRangeSliders(actIndex: actIndex, sceneIndex: sceneIndex)

            // Список всех реплик диалога в этом интервале
            DisclosureGroup(L10n.tr("Диалоги в этой сцене (%1$@ фраз)", String(describing: includedPhrases.count))) {
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
                .strokeBorder(selectedSceneID == scene.id ? StudioTheme.accent : (scene.isEdited ? Color.green.opacity(0.3) : Color.white.opacity(0.05)),
                              lineWidth: selectedSceneID == scene.id ? 1.5 : 1)
        )
        .onTapGesture { selectedSceneID = scene.id }
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
            Text(L10n.tr("Обрезка акта целиком"))
                .font(.subheadline.weight(.bold))

            Text(L10n.tr("Меняет вход первой сцены и выход последней. Титры актов, субтитры и музыка пересчитаются при перерендере."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("НАЧАЛО АКТА (IN)"), systemImage: "arrow.right.to.line")
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
                        trimButton(label: L10n.tr("-1с"), delta: -1.0) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: -1.0) }
                        trimButton(label: L10n.tr("-0.2с"), delta: -0.2) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: -0.2) }
                        trimButton(label: L10n.tr("+0.2с"), delta: 0.2) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: 0.2) }
                        trimButton(label: L10n.tr("+1с"), delta: 1.0) { adjustStart(actIndex: actIndex, sceneIndex: 0, delta: 1.0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("КОНЕЦ АКТА (OUT)"), systemImage: "arrow.left.to.line")
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
                        trimButton(label: L10n.tr("-1с"), delta: -1.0) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: -1.0) }
                        trimButton(label: L10n.tr("-0.2с"), delta: -0.2) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: -0.2) }
                        trimButton(label: L10n.tr("+0.2с"), delta: 0.2) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: 0.2) }
                        trimButton(label: L10n.tr("+1с"), delta: 1.0) { adjustEnd(actIndex: actIndex, sceneIndex: lastIndex, delta: 1.0) }
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
                Text(L10n.tr("Предпросмотр исходника"))
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button(L10n.tr("Стоп")) {
                    stopPreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let previewPlayer {
                StudioPlayerSurface(player: previewPlayer)
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
        let startLower = 0.0
        let startUpper = max(startLower + minimumRenderableClipDuration,
                             min(scene.end - minimumRenderableClipDuration,
                                 sourceDuration.isFinite ? sourceDuration : scene.end))
        let endLower = scene.start + minimumRenderableClipDuration
        let maxBound = sourceDuration.isFinite ? sourceDuration : max(scene.end, endLower + 0.01)

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
        timelinePlayback.open(url: sourceURL, clips: sequenceClips)
        Task {
            let asset = AVURLAsset(url: sourceURL)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
                sourceDuration = duration.seconds
            }
        }
    }

    private func selectAct(_ index: Int) {
        guard editedActs.indices.contains(index) else { return }
        selectedActIndex = index
        if let first = editedActs[index].scenes.first { selectScene(first.id) }
    }

    private func selectScene(_ id: UUID) {
        guard let location = sequenceLocation(for: id) else { return }
        selectedActIndex = location.actIndex; selectedSceneID = id
        timelinePlayback.select(id)
    }

    private func insertAtSequencePosition(_ index: Int) {
        guard !editedActs.isEmpty else { return }
        var offset = 0
        for (actIndex, act) in editedActs.enumerated() {
            let nextOffset = offset + act.scenes.count
            if index <= nextOffset {
                insertionTarget = SceneInsertionTarget(actIndex: actIndex, index: max(0, index - offset))
                return
            }
            offset = nextOffset
        }
        let lastAct = editedActs.count - 1
        insertionTarget = SceneInsertionTarget(actIndex: lastAct, index: editedActs[lastAct].scenes.count)
    }

    private func sequenceLocation(for id: UUID) -> (actIndex: Int, sceneIndex: Int)? {
        for (actIndex, act) in editedActs.enumerated() {
            if let sceneIndex = act.scenes.firstIndex(where: { $0.id == id }) {
                return (actIndex, sceneIndex)
            }
        }
        return nil
    }

    private func moveSceneAcrossSequence(_ id: UUID, delta: Int) {
        guard let location = sequenceLocation(for: id) else { return }
        moveScene(id, in: location.actIndex, delta: delta)
    }

    private func trimSceneStart(_ id: UUID, _ value: Double) {
        guard let location = sequenceLocation(for: id) else { return }
        setStart(actIndex: location.actIndex, sceneIndex: location.sceneIndex, value: value)
        reviewedArc = nil
        reviewMessage = nil
    }

    private func trimSceneEnd(_ id: UUID, _ value: Double) {
        guard let location = sequenceLocation(for: id) else { return }
        setEnd(actIndex: location.actIndex, sceneIndex: location.sceneIndex, value: value)
        reviewedArc = nil
        reviewMessage = nil
    }

    private func removeScene(_ id: UUID) {
        guard let location = sequenceLocation(for: id), editedActs[location.actIndex].scenes.count > 1 else { return }
        editedActs[location.actIndex].scenes.remove(at: location.sceneIndex)
        let remaining = editedActs[location.actIndex].scenes
        selectedSceneID = remaining[min(location.sceneIndex, remaining.count - 1)].id
        selectedActIndex = location.actIndex
        reviewedArc = nil
        reviewMessage = nil
    }

    private func playRange(start: Double, end: Double) {
        timelinePlayback.audition(start: start, end: end, preferredID: selectedSceneID)
    }

    private func stopPreview() { timelinePlayback.pause() }

    private func setStart(actIndex: Int, sceneIndex: Int, value: Double) {
        var current = editedActs[actIndex].scenes[sceneIndex]
        guard value.isFinite else { return }
        current.start = min(max(0, value), current.end - minimumRenderableClipDuration)
        editedActs[actIndex].scenes[sceneIndex] = current
    }

    private func setEnd(actIndex: Int, sceneIndex: Int, value: Double) {
        var current = editedActs[actIndex].scenes[sceneIndex]
        guard value.isFinite else { return }
        let upper = sourceDuration.isFinite ? sourceDuration : value
        current.end = min(max(current.start + minimumRenderableClipDuration, value), upper)
        editedActs[actIndex].scenes[sceneIndex] = current
    }

    private func adjustStart(actIndex: Int, sceneIndex: Int, delta: Double) {
        guard actIndex < editedActs.count, sceneIndex < editedActs[actIndex].scenes.count else { return }
        let current = editedActs[actIndex].scenes[sceneIndex]
        setStart(actIndex: actIndex, sceneIndex: sceneIndex, value: current.start + delta)
        reviewedArc = nil
        reviewMessage = nil
    }

    private func adjustEnd(actIndex: Int, sceneIndex: Int, delta: Double) {
        guard actIndex < editedActs.count, sceneIndex < editedActs[actIndex].scenes.count else { return }
        let current = editedActs[actIndex].scenes[sceneIndex]
        setEnd(actIndex: actIndex, sceneIndex: sceneIndex, value: current.end + delta)
        reviewedArc = nil
        reviewMessage = nil
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
        publicationWord = arc.concept.displayWord
        publicationTitle = arc.publicationTitle ?? arc.concept.suggestedTitle
        coverText = arc.coverText ?? arc.concept.coverText ?? arc.concept.displayWord
        viewerPromise = arc.viewerPromise ?? arc.thesis ?? arc.concept.philosophicalPremise
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
        selectedSceneID = editedActs.first?.scenes.first?.id
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
        stopPreview()
        previewAudio.shutdown()
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
              range.start.isFinite, range.end.isFinite, range.start >= 0,
              range.duration >= minimumRenderableClipDuration,
              sourceDuration.isFinite ? range.end <= sourceDuration : true else { return }
        let scene = EditableSceneSegment(sceneIndex: -1, start: range.start, end: range.end,
                                         isAdded: true, manualSourceRange: range)
        let position = min(max(target.index, 0), editedActs[target.actIndex].scenes.count)
        editedActs[target.actIndex].scenes.insert(scene, at: position)
        selectedActIndex = target.actIndex
        reviewedArc = nil
        reviewMessage = nil
    }

    private func moveScene(_ id: UUID, in actIndex: Int, delta: Int) {
        guard editedActs.indices.contains(actIndex),
              let source = editedActs[actIndex].scenes.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + delta
        guard editedActs[actIndex].scenes.indices.contains(destination) else { return }
        editedActs[actIndex].scenes.swapAt(source, destination)
        selectedSceneID = id
        reviewedArc = nil
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
        let currentRanges = updatedArc.acts.flatMap(\.segments)
        sceneEdits.removeAll { edit in
            !currentRanges.contains(edit.revised)
        }
        updatedArc.sceneEdits = sceneEdits.isEmpty ? nil : sceneEdits
        updatedArc.publicationTitle = publicationTitle.trimmed
        updatedArc.concept.publicationWord = publicationWord.trimmed.isEmpty
            || publicationWord.trimmed == updatedArc.concept.word ? nil : publicationWord.trimmed
        updatedArc.coverText = ThematicConcept.cleanTitle(coverText.trimmed)
        updatedArc.viewerPromise = viewerPromise.trimmed
        updatedArc.hookText = hookText.trimmed
        updatedArc.conclusionText = conclusionText.trimmed
        updatedArc.ctaText = ctaText.trimmed
        if musicSettings != initialMusicSettings || arc.musicSettings != nil {
            updatedArc.musicSettings = MusicBedMixing.resolvedSettings(musicSettings,
                for: updatedArc, coldOpenEnabled: coldOpenEnabled)
        }
        return updatedArc
    }

    private func runEditorialReview() {
        guard !isReviewing else { return }
        OperationJournal.shared.begin(L10n.tr("Редакторская проверка монтажа"))
        isReviewing = true
        reviewMessage = nil
        reviewProgress = L10n.tr("Запускаю редакторскую проверку…")
        reviewAttempts = []
        reviewEvents = []
        reviewChanges = []
        let draft = draftArc()
        Task { @MainActor in
            defer { isReviewing = false }
            do {
                let outcome = try await onReview(draft) { message in
                    Task { @MainActor in
                        OperationJournal.shared.append(message)
                        reviewProgress = message
                        if reviewEvents.last != message { reviewEvents.append(message) }
                    }
                }
                let result = outcome.arc
                reviewAttempts = outcome.attempts
                reviewChanges = outcome.changes
                guard result.acts.count == editedActs.count,
                      zip(result.acts, editedActs).allSatisfy({ $0.0.segments.count == $0.1.scenes.count }) else {
                    reviewMessage = L10n.tr("Ответ модели не совпал со сценами. Монтаж сохранён.")
                    return
                }
                for (actIndex, reviewedAct) in result.acts.enumerated() {
                    for (sceneIndex, range) in reviewedAct.segments.enumerated() {
                        editedActs[actIndex].scenes[sceneIndex].start = range.start
                        editedActs[actIndex].scenes[sceneIndex].end = range.end
                    }
                }
                reviewedArc = result
                reviewMessage = outcome.summary
            } catch {
                OperationJournal.shared.append(error.localizedDescription, level: .error)
                reviewMessage = L10n.tr("Не удалось запустить проверку: %1$@", String(describing: error.localizedDescription))
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
        for range in candidate.segments {
            if !range.start.isFinite || !range.end.isFinite || range.start < 0
                || range.duration < minimumRenderableClipDuration
                || (sourceDuration.isFinite && range.end > sourceDuration) {
                return L10n.tr("Проверьте границы: фрагмент должен находиться внутри исходного фильма и длиться не менее 0,1 секунды.")
            }
        }
        if coverText.trimmed.isEmpty || coverText.count > 42 || coverText.split(whereSeparator: \.isWhitespace).count > 5 {
            return L10n.tr("Текст обложки: от одного до пяти слов, не больше 42 символов.")
        }
        if publicationTitle.count > 120 || hookText.count > 180 || conclusionText.count > 140 || ctaText.count > 200 {
            return L10n.tr("Сократите текст: название до 120, хук до 180, вывод до 140, CTA до 200 символов.")
        }
        return nil
    }

    /// Подсказка обязана описывать ровно тот артефакт, под которым висит: «источник
    /// не зафиксирован» верно только для `.unknown`, а для `.template` источник
    /// записан — просто реплики-доказательства у него нет.
    static func titleSourceHelp(for act: EditableActModel) -> String {
        switch act.effectiveTitleSource {
        case .manual:
            return L10n.tr("изменено вами")
        case .llm, .transcriptLine:
            return act.titleProvenance?.evidence
                ?? L10n.tr("Реплика-основание не записана: метка есть, доказать её нечем")
        case .template:
            return L10n.tr("Название дала формула темы — ни модель, ни реплика акта его не выводили")
        case .unknown:
            return L10n.tr("Источник названия не зафиксирован")
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
