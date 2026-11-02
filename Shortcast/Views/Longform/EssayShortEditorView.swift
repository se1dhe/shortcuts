import AVKit
import SwiftUI

private struct ShortSceneInsertionTarget: Identifiable {
    let id = UUID()
    let index: Int
}

struct EssayShortEditorView: View {
    let result: LongformBuildResult
    let transcript: Transcript
    let sourceURL: URL
    let onSave: (EssayShort) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceModel.self) private var workspace
    @State private var renderStarted = Date()
    @State private var draft: EssayShort
    @State private var musicSettings: LongformAudioSettings
    @State private var showMusicEditor = false
    @State private var showLayoutPreview = false
    @State private var scenes: [EditableSceneSegment]
    @State private var timelinePlayback = MontageTimelinePlayback()
    private var player: AVPlayer? { timelinePlayback.player }
    private var previewAudio: MontageScenePreviewAudio { timelinePlayback.audio }
    private var isPreviewBusy: Bool { timelinePlayback.isPreparing }
    @State private var sourceDuration: Double = 0
    @State private var busy = false
    @State private var error: String?
    @State private var selectedSceneID: UUID?
    @State private var insertionTarget: ShortSceneInsertionTarget?

    init(short: EssayShort, result: LongformBuildResult, transcript: Transcript,
         sourceURL: URL, onSave: @escaping (EssayShort) async throws -> Void) {
        _draft = State(initialValue: short)
        _musicSettings = State(initialValue: short.musicSettings ?? LongformAudioSettings(backgroundMusicURL: nil))
        _scenes = State(initialValue: short.segments.enumerated().map { item in
            let isManual = short.manuallyAddedSegments?.contains { range in
                abs(range.start - item.element.start) < 0.01 && abs(range.end - item.element.end) < 0.01
            } ?? false
            return EditableSceneSegment(sceneIndex: item.offset, start: item.element.start, end: item.element.end,
                                        isAdded: isManual, manualSourceRange: isManual ? item.element : nil)
        })
        self.result = result; self.transcript = transcript
        self.sourceURL = sourceURL; self.onSave = onSave
    }

    private var editedShort: EssayShort {
        var result = draft
        result.musicSettings = musicSettings
        result.segments = scenes.map { TimeSegment(start: $0.start, end: $0.end) }
        let manual = scenes.filter(\.isAdded).map { TimeSegment(start: $0.start, end: $0.end) }
        result.manuallyAddedSegments = manual.isEmpty ? nil : manual
        result.captionEdits = draft.captionEdits?.filter { edit in
            selectedCaptions.contains { $0.start == edit.start && $0.end == edit.end }
        }
        return result
    }

    private var timelineClips: [EditorTimelineClip] {
        scenes.enumerated().map { index, scene in
            EditorTimelineClip(id: scene.id, start: scene.start, end: scene.end, isAdded: scene.isAdded,
                sceneNumber: index + 1,
                quote: transcript.segments.first(where: { $0.start >= scene.start && $0.end <= scene.end })?.text)
        }
    }

    private var captions: [TranscriptSegment] {
        LongformEditorialSupport.captions(transcript.segments, edits: result.arc.captionEdits)
    }
    private var selectedCaptions: [TranscriptSegment] {
        captions.filter { line in scenes.contains { line.start >= $0.start && line.end <= $0.end } }
    }
    private var musicSpeechIntervals: [TimeSegment] {
        var cursor = 0.0
        var intervals: [TimeSegment] = []
        for scene in scenes {
            for line in transcript.segments {
                let start = max(line.start, scene.start), end = min(line.end, scene.end)
                if end > start {
                    intervals.append(.init(start: cursor + start - scene.start, end: cursor + end - scene.start))
                }
            }
            cursor += scene.duration
        }
        return intervals
    }
    private var validationError: String? {
        do { try EssayShortEditing.validate(editedShort, arc: result.arc, sourceDuration: sourceDuration); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Монтаж шортса")).font(.title2.bold())
                    Text(L10n.tr("%1$@ с · %2$@ сцен · порядок, границы, хук и субтитры", String(describing: Int(editedShort.duration.rounded())), String(describing: scenes.count)))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("Отмена")) { dismiss() }.disabled(busy)
                Button(busy ? L10n.tr("Рендеринг…") : L10n.tr("Сохранить и пересобрать")) { save() }
                    .buttonStyle(StudioPrimaryButtonStyle()).disabled(busy || validationError != nil)
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        if let player {
                            StudioPlayerSurface(player: player)
                        } else {
                            Color.black
                        }
                    }
                    .frame(width: 470, height: 264)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.line, lineWidth: 1))
                    HStack {
                        Label(L10n.tr("Предпросмотр исходника"), systemImage: "play.rectangle")
                        Spacer()
                        if let selectedSceneID,
                           let scene = scenes.first(where: { $0.id == selectedSceneID }) {
                            Text(L10n.tr("Сцена %1$@ · %2$@", String(describing: scenes.firstIndex(where: { $0.id == scene.id }).map { $0 + 1 } ?? 1), String(describing: timecode(scene.duration))))
                                .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(StudioTheme.accent)
                        } else {
                            Text(L10n.tr("Выберите сцену на шкале"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .frame(width: 470)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GroupBox(L10n.tr("Содержание")) {
                            VStack(spacing: 9) {
                                TextField(L10n.tr("Название"), text: $draft.title)
                                TextField(L10n.tr("Хук публикации"), text: $draft.hook, axis: .vertical)
                                Button(L10n.tr("Предпросмотр оформления"), systemImage: "rectangle.portrait") { showLayoutPreview = true }
                                    .sheet(isPresented: $showLayoutPreview) { ShortLayoutPreview(sourceURL: sourceURL, short: editedShort, result: result) }
                                Toggle(L10n.tr("Субтитры в видео"), isOn: Binding(get: { draft.showsSubtitles }, set: { draft.subtitlesEnabled = $0 }))
                                Text(L10n.tr("Первые 2 секунды — карточка фильма. Далее — видео и небольшой логотип.")).font(.caption).foregroundStyle(.secondary)
                                TextField(L10n.tr("Основная мысль"), text: $draft.angle, axis: .vertical)
                                TextField(L10n.tr("Вопрос зрителю"), text: $draft.question, axis: .vertical)
                                TextField(L10n.tr("Ключевая реплика"), text: $draft.payoffQuote, axis: .vertical)
                            }.textFieldStyle(.roundedBorder).padding(5)
                        }
                        GroupBox(L10n.tr("Музыка и сведение")) {
                            HStack {
                                Label(musicSettings.backgroundMusicURL?.deletingPathExtension().lastPathComponent ?? L10n.tr("Без музыки"), systemImage: "music.note")
                                    .font(.callout).lineLimit(2)
                                Spacer()
                                Button(L10n.tr("Настроить"), systemImage: "waveform") {
                                    timelinePlayback.pause()
                                    showMusicEditor = true
                                }
                            }.padding(8)
                        }
                        GroupBox(L10n.tr("Сцены и точная подрезка")) {
                            VStack(spacing: 10) {
                                ForEach($scenes) { scene in sceneRow(scene) }
                            }.padding(5)
                        }
                        GroupBox(L10n.tr("Субтитры выбранных сцен")) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(L10n.tr("Изменения применяются только к этому шортсу."))
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(selectedCaptions.enumerated()), id: \.offset) { _, segment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(timecode(segment.start))
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 64, alignment: .leading)
                                        Button { preview(TimeSegment(start: segment.start, end: segment.end)) } label: {
                                            Image(systemName: "play.fill")
                                        }.buttonStyle(.borderless).disabled(isPreviewBusy)
                                        TextField(L10n.tr("Субтитр"), text: captionBinding(segment), axis: .vertical)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }.padding(5)
                        }
                    }.padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxHeight: .infinity)

            EditorTimelineView(
                clips: timelineClips,
                selectedID: selectedSceneID,
                onSelect: { id in
                    selectedSceneID = id
                    if let scene = scenes.first(where: { $0.id == id }) {
                        preview(TimeSegment(start: scene.start, end: scene.end))
                    }
                },
                onInsertAt: { insertionTarget = ShortSceneInsertionTarget(index: $0) },
                onMoveEarlier: { moveScene($0, delta: -1) },
                onMoveLater: { moveScene($0, delta: 1) },
                onRemove: { id in
                    guard scenes.count > 1 else { return }
                    scenes.removeAll { $0.id == id }
                    if selectedSceneID == id { selectedSceneID = scenes.first?.id }
                },
                onTrimStart: { id, value in
                    guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
                    scenes[index].start = min(max(0, value), scenes[index].end - EssayShortEditing.minimumSceneDuration)
                    selectedSceneID = id
                },
                onTrimEnd: { id, value in
                    guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
                    scenes[index].end = max(scenes[index].start + EssayShortEditing.minimumSceneDuration,
                                            min(sourceDuration, value))
                    selectedSceneID = id
                },
                playhead: timelinePlayback.currentTime,
                isPlaying: timelinePlayback.isPlaying,
                onTogglePlayback: { timelinePlayback.toggle() },
                onSeek: { timelinePlayback.scrub(to: $0, editing: $1) }
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if busy || error != nil || validationError != nil {
                HStack {

                    if let message = error ?? validationError {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .overlay {
            if busy {
                ZStack {
                    StudioTheme.background.opacity(0.97)
                    StudioOperationProgress(title: L10n.tr("Собираем ваш шортс"), detail: workspace.shortRenderDetail,
                        stages: [L10n.tr("Исходник"), L10n.tr("Кадрирование"), L10n.tr("Оформление"), L10n.tr("Экспорт"), "Shield", L10n.tr("Звук и проверка"), L10n.tr("Обложка")],
                        current: workspace.shortRenderStage, started: renderStarted)
                        .frame(width: 760).padding(40)
                }
            }
        }
        .disabled(busy)
        .safeAreaInset(edge: .bottom) {
            if busy || error != nil { OperationLogPanel(isActive: busy) }
        }
        .frame(width: 1280, height: 860)
        .background(StudioTheme.background)
        .tint(StudioTheme.accent)
        .interactiveDismissDisabled(busy)
        .sheet(item: $insertionTarget) { target in
            LongformSceneInsertSheet(
                transcriptSegments: transcript.segments,
                existingRanges: scenes.map { TimeSegment(start: $0.start, end: $0.end) },
                sourceURL: sourceURL,
                sourceDuration: sourceDuration,
                player: player,
                previewAudio: previewAudio,
                onInsert: { range in
                    let scene = EditableSceneSegment(sceneIndex: target.index, start: range.start, end: range.end,
                                                     isAdded: true, manualSourceRange: range)
                    scenes.insert(scene, at: min(target.index, scenes.count))
                    selectedSceneID = scene.id
                }
            )
            .frame(minWidth: 760, minHeight: 600)
        }
        .task {
            timelinePlayback.open(url: sourceURL, clips: timelineClips)
            do { sourceDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds }
            catch { self.error = error.localizedDescription; OperationJournal.shared.append(error.localizedDescription, level: .error) }
        }
        .sheet(isPresented: $showMusicEditor) {
            MusicBedEditor(settings: $musicSettings, duration: editedShort.duration, speechIntervals: musicSpeechIntervals)
        }
        .onChange(of: scenes) { _, _ in timelinePlayback.setClips(timelineClips) }
        .onChange(of: timelinePlayback.activeClipID) { _, id in selectedSceneID = id }
        .onChange(of: timelinePlayback.error) { _, message in
            if let message { error = L10n.tr("Предпросмотр: ") + message }
        }
        .onDisappear { timelinePlayback.close() }
    }

    private func sceneRow(_ scene: Binding<EditableSceneSegment>) -> some View {
        let id = scene.wrappedValue.id
        let index = scenes.firstIndex { $0.id == id } ?? 0
        let current = scene.wrappedValue
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("СЦЕНА %1$@", String(describing: String(format: "%02d", index + 1))))
                        .font(.system(size: 10, weight: .black)).tracking(0.7)
                    Text(L10n.tr("%1$@ → %2$@  ·  %3$@ с", String(describing: timecode(current.start)), String(describing: timecode(current.end)), String(describing: Int(current.duration.rounded()))))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button {
                    selectedSceneID = id
                    preview(TimeSegment(start: current.start, end: current.end))
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.bordered).controlSize(.small).help(L10n.tr("Просмотреть сцену"))
                .disabled(isPreviewBusy)
                Menu {
                    Button(L10n.tr("Переместить раньше"), systemImage: "arrow.up") {
                        moveScene(id, delta: -1)
                    }.disabled(index == 0)
                    Button(L10n.tr("Переместить позже"), systemImage: "arrow.down") {
                        moveScene(id, delta: 1)
                    }.disabled(index + 1 == scenes.count)
                    Divider()
                    Button(L10n.tr("Удалить сцену"), systemImage: "trash", role: .destructive) {
                        guard scenes.count > 1 else { return }
                        scenes.removeAll { $0.id == id }
                    }.disabled(scenes.count <= 1)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .help(L10n.tr("Действия со сценой"))
            }
            HStack(spacing: 8) {
                Label("IN", systemImage: "arrow.right.to.line")
                    .font(.system(size: 8, weight: .black)).foregroundStyle(StudioTheme.muted)
                Text(timecode(current.start)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                Spacer()
                Button("−0.2") { adjustShortBoundary(id, isStart: true, delta: -0.2) }
                    .buttonStyle(.bordered).controlSize(.mini)
                Button("+0.2") { adjustShortBoundary(id, isStart: true, delta: 0.2) }
                    .buttonStyle(.bordered).controlSize(.mini).tint(StudioTheme.accent)
            }
            HStack(spacing: 8) {
                Label("OUT", systemImage: "arrow.left.to.line")
                    .font(.system(size: 8, weight: .black)).foregroundStyle(StudioTheme.muted)
                Text(timecode(current.end)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                Spacer()
                Button("−0.2") { adjustShortBoundary(id, isStart: false, delta: -0.2) }
                    .buttonStyle(.bordered).controlSize(.mini)
                Button("+0.2") { adjustShortBoundary(id, isStart: false, delta: 0.2) }
                    .buttonStyle(.bordered).controlSize(.mini).tint(StudioTheme.accent)
            }
        }
        .padding(12)
        .background(selectedSceneID == id ? StudioTheme.accent.opacity(0.1) : StudioTheme.panel,
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(selectedSceneID == id ? StudioTheme.accent.opacity(0.65) : StudioTheme.line,
                    lineWidth: selectedSceneID == id ? 1.2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { selectedSceneID = id }
    }

    private func captionBinding(_ segment: TranscriptSegment) -> Binding<String> {
        Binding(get: {
            draft.captionEdits?.first { $0.start == segment.start && $0.end == segment.end && $0.original == segment.text }?.replacement ?? segment.text
        }, set: { text in
            var edits = draft.captionEdits ?? []
            edits.removeAll { $0.start == segment.start && $0.end == segment.end }
            if text != segment.text {
                edits.append(LongformCaptionEdit(start: segment.start, end: segment.end, original: segment.text, replacement: text))
            }
            draft.captionEdits = edits.isEmpty ? nil : edits
        })
    }

    private func moveScene(_ id: UUID, delta: Int) {
        guard let source = scenes.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + delta
        guard scenes.indices.contains(destination) else { return }
        scenes.swapAt(source, destination)
    }

    private func adjustShortBoundary(_ id: UUID, isStart: Bool, delta: Double) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        let minimum = EssayShortEditing.minimumSceneDuration
        if isStart {
            scenes[index].start = min(scenes[index].end - minimum,
                                      max(0, scenes[index].start + delta))
        } else {
            scenes[index].end = max(scenes[index].start + minimum,
                                    min(sourceDuration, scenes[index].end + delta))
        }
        selectedSceneID = id
    }

    private func preview(_ range: TimeSegment) {
        timelinePlayback.audition(start: range.start, end: range.end, preferredID: selectedSceneID)
    }

    private func save() {
        renderStarted = Date(); workspace.shortRenderStage = 0; workspace.shortRenderDetail = L10n.tr("Подготовка исходника")
        OperationJournal.shared.begin(L10n.tr("Пересборка шортса"))
        busy = true; error = nil; timelinePlayback.pause()
        Task { @MainActor in
            defer { busy = false }
            do { try await onSave(editedShort); dismiss() }
            catch { self.error = error.localizedDescription; OperationJournal.shared.append(error.localizedDescription, level: .error) }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}
