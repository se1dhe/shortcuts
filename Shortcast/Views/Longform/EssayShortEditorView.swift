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
    @State private var draft: EssayShort
    @State private var scenes: [EditableSceneSegment]
    @State private var player: AVPlayer?
    @State private var sourceDuration: Double = 0
    @State private var busy = false
    @State private var error: String?
    @State private var selectedSceneID: UUID?
    @State private var insertionTarget: ShortSceneInsertionTarget?

    init(short: EssayShort, result: LongformBuildResult, transcript: Transcript,
         sourceURL: URL, onSave: @escaping (EssayShort) async throws -> Void) {
        _draft = State(initialValue: short)
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
        result.segments = scenes.map { TimeSegment(start: $0.start, end: $0.end) }
        let manual = scenes.filter(\.isAdded).map { TimeSegment(start: $0.start, end: $0.end) }
        result.manuallyAddedSegments = manual.isEmpty ? nil : manual
        result.captionEdits = draft.captionEdits?.filter { edit in
            selectedCaptions.contains { $0.start == edit.start && $0.end == edit.end }
        }
        return result
    }

    private var captions: [TranscriptSegment] {
        LongformEditorialSupport.captions(transcript.segments, edits: result.arc.captionEdits)
    }
    private var selectedCaptions: [TranscriptSegment] {
        captions.filter { line in scenes.contains { line.start >= $0.start && line.end <= $0.end } }
    }
    private var validationError: String? {
        do { try EssayShortEditing.validate(editedShort, arc: result.arc, sourceDuration: sourceDuration); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Монтаж шортса").font(.title2.bold())
                    Text("\(Int(editedShort.duration.rounded())) с · \(scenes.count) сцен · порядок, границы, хук и субтитры")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { dismiss() }.disabled(busy)
                Button(busy ? "Рендеринг…" : "Сохранить и пересобрать") { save() }
                    .buttonStyle(StudioPrimaryButtonStyle()).disabled(busy || validationError != nil)
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    VideoPlayer(player: player)
                        .frame(width: 470, height: 264)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.line, lineWidth: 1))
                    HStack {
                        Label("Предпросмотр исходника", systemImage: "play.rectangle")
                        Spacer()
                        if let selectedSceneID,
                           let scene = scenes.first(where: { $0.id == selectedSceneID }) {
                            Text("Сцена \(scenes.firstIndex(where: { $0.id == scene.id }).map { $0 + 1 } ?? 1) · \(timecode(scene.duration))")
                                .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(StudioTheme.accent)
                        } else {
                            Text("Выберите сцену на шкале")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }
                .frame(width: 470)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GroupBox("Содержание") {
                            VStack(spacing: 9) {
                                TextField("Название", text: $draft.title)
                                TextField("Хук в видео", text: $draft.hook, axis: .vertical)
                                TextField("Основная мысль", text: $draft.angle, axis: .vertical)
                                TextField("Вопрос зрителю", text: $draft.question, axis: .vertical)
                                TextField("Ключевая реплика", text: $draft.payoffQuote, axis: .vertical)
                            }.textFieldStyle(.roundedBorder).padding(5)
                        }
                        GroupBox("Сцены и точная подрезка") {
                            VStack(spacing: 10) {
                                ForEach($scenes) { scene in sceneRow(scene) }
                            }.padding(5)
                        }
                        GroupBox("Субтитры выбранных сцен") {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Изменения применяются только к этому шортсу.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(selectedCaptions.enumerated()), id: \.offset) { _, segment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(timecode(segment.start))
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 64, alignment: .leading)
                                        Button { preview(TimeSegment(start: segment.start, end: segment.end)) } label: {
                                            Image(systemName: "play.fill")
                                        }.buttonStyle(.borderless)
                                        TextField("Субтитр", text: captionBinding(segment), axis: .vertical)
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
                clips: scenes.map { EditorTimelineClip(id: $0.id, start: $0.start, end: $0.end, isAdded: $0.isAdded) },
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
                onRemove: { id in scenes.removeAll { $0.id == id } }
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if busy || error != nil || validationError != nil {
                HStack {
                    if busy { ProgressView("Сохраняю сцены, субтитры и собираю видео…") }
                    if let message = error ?? validationError {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .disabled(busy)
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
            player = AVPlayer(url: sourceURL)
            do { sourceDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func sceneRow(_ scene: Binding<EditableSceneSegment>) -> some View {
        let id = scene.wrappedValue.id
        let index = scenes.firstIndex { $0.id == id } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Сцена \(index + 1)").bold()
                Spacer()
                Button("Смотреть", systemImage: "play.fill") {
                    preview(TimeSegment(start: scene.wrappedValue.start, end: scene.wrappedValue.end))
                }
                Button {
                    if let current = scenes.firstIndex(where: { $0.id == id }), current > 0 { scenes.swapAt(current, current - 1) }
                } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                Button {
                    if let current = scenes.firstIndex(where: { $0.id == id }), current + 1 < scenes.count { scenes.swapAt(current, current + 1) }
                } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == scenes.count)
                Button(role: .destructive) { scenes.removeAll { $0.id == id } } label: { Image(systemName: "trash") }
            }
            HStack {
                Text("Начало, с")
                TextField("Начало", value: scene.start, format: .number.precision(.fractionLength(2)))
                Text("Конец, с")
                TextField("Конец", value: scene.end, format: .number.precision(.fractionLength(2)))
            }.textFieldStyle(.roundedBorder)
        }.padding(12).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 10))
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

    private func preview(_ range: TimeSegment) {
        guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start else { return }
        player?.pause()
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    private func save() {
        busy = true; error = nil; player?.pause()
        Task { @MainActor in
            defer { busy = false }
            do { try await onSave(editedShort); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}
