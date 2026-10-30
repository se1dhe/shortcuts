import AVKit
import AppKit
import SwiftUI

/// Экран готового длинного ролика (16:9 YouTube Shortcast Cinema)
struct LongformResultsView: View {

    let result: LongformBuildResult
    let movieTitle: String
    let onChooseAnotherTheme: () -> Void
    let onStartNewMovie: () -> Void
    let onOpenShorts: () -> Void

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppSettings.self) private var settings

    @State private var player: AVPlayer? = nil
    @State private var actPlaybackObserver: Any?
    @State private var activeActID: String?
    @State private var copiedTitle = false
    @State private var copiedDescription = false
    @State private var copiedTags = false
    @State private var copiedComment = false

    @State private var showSubtitleEditor = false
    @State private var showActEditor = false
    @State private var editingShort: EssayShort?
    private var publicationMetadata: LongformYouTubeMetadata {
        LongformMetadataGenerator.updatingTelegram(in: result.metadata, channelID: settings.telegramChannelId)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Левая колонка: 16:9 Видеоплеер
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(result.arc.concept.word.uppercased())
                                .font(.caption.weight(.black))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(StudioTheme.accent.opacity(0.18)))
                                .foregroundStyle(StudioTheme.accent)

                            Text("«\(movieTitle)»")
                                .font(.headline)
                        }

                        Text(result.metadata.title)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                    }

                    Spacer()

                        Label(formatDuration(result.duration), systemImage: "clock")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button("Редакторский проход", systemImage: "wand.and.stars") {
                            workspace.improveLongform(existingResult: result, modelManager: modelManager, settings: settings)
                        }
                        .help("Проверить диалоги с соседним контекстом, уточнить границы сцен и пересобрать эссе на той же теме")

                        Button {
                            showSubtitleEditor = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "character.cursor.ibeam")
                                Text("Редактировать субтитры")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.accent)
                        .disabled(workspace.isRefreshingLongformPackaging)
                        .help("Исправить неточности в субтитрах и перерендерить видео с тем же монтажом")

                        Button {
                            showActEditor = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "film.stack")
                                Text("Монтажный стол")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.accent)
                        .help("Обрезать начало и конец актов — титры и музыка подстроятся автоматически")

                        Menu("Монтаж шортсов", systemImage: "scissors") {
                            if let release = workspace.currentEssayRelease, !release.shorts.isEmpty {
                                ForEach(release.shorts) { short in
                                    Button(short.title) { editingShort = short }
                                        .disabled(!EssayShortEditing.canEdit(short, in: release))
                                }
                            } else {
                                Button("Подготовить два шортса") { onOpenShorts() }
                            }
                        }
                        .disabled(workspace.isWorkingOnEssayRelease)
                        .help("Сцены, хук, тексты и субтитры каждого шортса")

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                        } label: {
                            Label("В Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }.fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                if let notes = result.arc.editorialNotes, !notes.isEmpty {
                    DisclosureGroup("Замечания к монтажу (\(notes.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                                    Text("• " + note).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxHeight: 140)
                    }.padding(.horizontal, 20)
                }
                // Сообщение о проблеме плана; причину показывает проверка.
                if let reason = result.arc.degradationReason {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("План требует внимания")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                    .padding(.horizontal, 20)
                }

                // Честный след хронометража: коридор 4:00–8:00 не обсуждается, но
                // молча подрезать заказ из сохранённого плана нельзя.
                if let legacyAsk = result.arc.legacyAskSeconds {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Хронометраж скорректирован")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Проект просил \(EssayDurationPolicy.format(legacyAsk)) — длина эссе рождается из материала темы и ограничена коридором 4:00–8:00.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                    .padding(.horizontal, 20)
                }

                // 16:9 Контейнер плеера
                ZStack {
                    Color.black

                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16/9, contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .padding(.horizontal, 20)

                // Интерактивные главы эссе
                HStack(spacing: 8) {
                    ForEach(Array(result.arc.acts.indices), id: \.self) { index in
                        let act = result.arc.acts[index]
                        Button {
                            seekToAct(at: index)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    if activeActID == act.id {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(StudioTheme.accent)
                                    }
                                    Text(act.type.displayName)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                                Text(act.title)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 3) {
                                    Image(systemName: act.effectiveTitleSource.isTrustworthy
                                          ? "checkmark.seal" : "exclamationmark.seal")
                                    Text(act.effectiveTitleSource.displayCaption).lineLimit(1)
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help(Self.titleSourceHelp(for: act))
                                HStack(spacing: 5) {
                                    Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                                    Text(formatDuration(act.duration)).font(.caption2.monospacedDigit())
                                }
                                .foregroundStyle(activeActID == act.id ? StudioTheme.accent : .secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(activeActID == act.id ? StudioTheme.accent.opacity(0.12) : Color.secondary.opacity(0.1)))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(activeActID == act.id ? StudioTheme.accent.opacity(0.65) : StudioTheme.line,
                                                  lineWidth: activeActID == act.id ? 1.5 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .help("Перейти к акту «\(act.type.displayName)» в эссе")
                    }
                }
                .padding(.horizontal, 20)
                HStack(spacing: 6) {
                    Image(systemName: "cursorarrow.click")
                    Text(activeActTitle.map { "Сейчас: \($0)" } ?? "Нажмите на акт, чтобы перейти к его сценам")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(StudioTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
            .frame(minWidth: 500)

            Divider()

            // Правая колонка: Упаковка, публикация и экспорт
            VStack(alignment: .leading, spacing: 14) {
                Text("Финальный монтаж")
                    .font(.headline)

                // One explicit editorial approval hands the final essay to the
                // short generator and opens the complete publication package.
                VStack(spacing: 8) {
                    Text("Проверьте монтаж и реплики. Когда эссе готово, переходите к двум шортсам на его основе.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        player?.pause()
                        onOpenShorts()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles.tv")
                                .font(.subheadline)
                            Text(workspace.currentEssayRelease?.hasReadyShorts == true
                                 ? "Перейти к шортсам"
                                 : "Эссе готово — к шортсам")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)
                    .disabled(workspace.isBusy)
                    Text("Следом: два шортса → постинг выпуска")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Оформление публикации").font(.headline)
                            Spacer()
                            Button {
                                Task { await workspace.refreshLongformPackaging(modelManager: modelManager) }
                            } label: {
                                if workspace.isRefreshingLongformPackaging {
                                    ProgressView().controlSize(.small)
                                    Text("Проверка героя и обложки…")
                                } else {
                                    Label("Обновить всё", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(workspace.isBusy)
                            .accessibilityLabel("Обновить всё оформление публикации")
                            .help("Обновить обложку и тексты публикации. Видео повторно не рендерится.")
                        }
                        if let warning = workspace.longformPackagingError ?? result.packagingWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        // Обложка по визуальному языку «Кадр & Сенс».
                        if let thumbURL = result.thumbnailURL, let nsImage = NSImage(contentsOf: thumbURL) {
                            thumbnailCard(image: nsImage, fileURL: thumbURL)
                            if let subject = result.thumbnailSubject {
                                Text("Ведущий герой • исходник \(Int(subject.sourceTime) / 60):\(String(format: "%02d", Int(subject.sourceTime) % 60)) • проверка модели")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .help("Проверка по ведущему составу: " + subject.leadingCast.joined(separator: ", "))
                            }
                        }

                        // 1. Заголовок
                        metadataCard(
                            title: "Заголовок видео",
                            content: result.metadata.title,
                            copied: copiedTitle
                        ) {
                            copyToClipboard(result.metadata.title)
                            copiedTitle = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTitle = false }
                        }

                        // 2. Описание
                        metadataCard(
                            title: "Описание эссе",
                            content: publicationMetadata.description,
                            copied: copiedDescription,
                            lineLimit: nil
                        ) {
                            copyToClipboard(publicationMetadata.description)
                            copiedDescription = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDescription = false }
                        }

                        // 3. Теги
                        metadataCard(
                            title: "Хештеги YouTube",
                            content: result.metadata.hashtagText,
                            copied: copiedTags,
                            lineLimit: 3
                        ) {
                            copyToClipboard(result.metadata.hashtagText)
                            copiedTags = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTags = false }
                        }

                        // 4. Закрепленный комментарий
                        metadataCard(
                            title: "Закрепленный комментарий",
                            content: publicationMetadata.pinnedComment,
                            copied: copiedComment,
                            lineLimit: nil
                        ) {
                            copyToClipboard(publicationMetadata.pinnedComment)
                            copiedComment = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedComment = false }
                        }
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        onChooseAnotherTheme()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Выбрать другую тему")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)
                    .help("Выбрать или ввести другую тему без повторного анализа фильма")

                    Button {
                        workspace.regenerateLongformFromScratch(
                            concept: result.arc.concept,
                            movieTitle: movieTitle,
                            modelManager: modelManager,
                            settings: settings
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Пересчитать сцены с AI")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Попросить модель заново выбрать сцены и распределить их по актам на той же теме")

                    Button(role: .destructive) {
                        onStartNewMovie()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Новый фильм")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Сбросить текущий фильм и добавить другой")

                    Spacer()

                    Button {
                        exportFile()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Экспорт…")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
            .frame(width: 400)
        }
        .sheet(item: $editingShort) { short in
            if let source = workspace.job?.url, let transcript = workspace.storedTranscript ?? workspace.currentProject?.transcript {
                EssayShortEditorView(short: short, result: result, transcript: transcript, sourceURL: source) { edited in
                    try await workspace.rebuildEssayShort(edited, settings: settings)
                }
            }
        }
        .sheet(isPresented: $showSubtitleEditor) {
            if let transcript = workspace.storedTranscript {
                LongformSubtitleEditorView(
                    arc: result.arc,
                    concept: result.arc.concept,
                    movieTitle: movieTitle,
                    allSegments: transcript.segments,
                    correctionFilmKey: workspace.subtitleCorrectionFilmKey,
                    correctionLanguage: workspace.subtitleCorrectionLanguage,
                    sourceURL: workspace.job?.url,
                    confirmButtonTitle: "Перерендерить с исправленными субтитрами",
                    backButtonTitle: "Отмена",
                    onConfirm: { updatedSegments in
                        showSubtitleEditor = false
                        workspace.rebuildLongformWithUpdatedSubtitles(
                            updatedSegments: updatedSegments,
                            existingResult: result,
                            modelManager: modelManager,
                            settings: settings
                        )
                    },
                    onBack: {
                        showSubtitleEditor = false
                    }
                )
                .frame(minWidth: 1000, minHeight: 680)
            }
        }
        .sheet(isPresented: $showActEditor) {
            if let transcript = workspace.storedTranscript {
                LongformActEditorView(
                    arc: result.arc,
                    concept: result.arc.concept,
                    movieTitle: movieTitle,
                    transcriptSegments: transcript.segments,
                    sourceURL: workspace.job?.url,
                    coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true,
                    onApply: { modifiedArc in
                        showActEditor = false
                        workspace.rebuildLongformWithModifiedArc(
                            modifiedArc: modifiedArc,
                            existingResult: result,
                            modelManager: modelManager,
                            settings: settings
                        )
                    },
                    onCancel: {
                        showActEditor = false
                    }
                )
            }
        }
        .onAppear {
            let next = AVPlayer(url: result.outputURL)
            player = next
            observeActPlayback(on: next)
        }
        .onChange(of: result.outputURL) { _, newURL in
            removeActPlaybackObserver()
            player?.pause()
            let next = AVPlayer(url: newURL)
            player = next
            activeActID = nil
            observeActPlayback(on: next)
        }
        .onDisappear {
            removeActPlaybackObserver()
            player?.pause()
            player = nil
        }
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
    }

    private var activeActTitle: String? {
        guard let activeActID else { return nil }
        return result.arc.acts.first(where: { $0.id == activeActID })?.type.displayName
    }

    private func seekToAct(at index: Int) {
        guard result.arc.acts.indices.contains(index),
              let start = LongformTimeline(
                arc: result.arc,
                coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true
              ).start(ofAct: index) else { return }
        activeActID = result.arc.acts[index].id
        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func observeActPlayback(on player: AVPlayer) {
        let timeline = LongformTimeline(
            arc: result.arc,
            coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true)
        let acts = result.arc.acts
        actPlaybackObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                let seconds = CMTimeGetSeconds(time)
                let index = timeline.placements.first(where: { seconds >= $0.start && seconds < $0.end })?.actIndex
                let id = index.flatMap { acts.indices.contains($0) ? acts[$0].id : nil }
                Task { @MainActor in
                    if activeActID != id { activeActID = id }
                }
            }
    }

    private func removeActPlaybackObserver() {
        if let actPlaybackObserver, let player {
            player.removeTimeObserver(actPlaybackObserver)
        }
        actPlaybackObserver = nil
    }

    private func thumbnailCard(image: NSImage, fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Обложка YouTube (1920×1080)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await workspace.regenerateLongformCover(modelManager: modelManager) }
                } label: {
                    if workspace.isRegeneratingLongformCover {
                        ProgressView().controlSize(.small)
                        Text("Подбираем кадр…")
                    } else {
                        Label("Другой кадр", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(StudioTheme.accent)
                .disabled(workspace.isBusy)
                .help("Сгенерировать отдельный вариант обложки с другим кадром подтверждённого главного актёра")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label("В Finder", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudioTheme.accent)

                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Label("Открыть", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudioTheme.accent)
            }

            Image(nsImage: image)
                .resizable()
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func metadataCard(
        title: String,
        content: String,
        copied: Bool,
        lineLimit: Int? = nil,
        onCopy: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onCopy()
                } label: {
                    Label(copied ? "Скопировано!" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? StudioTheme.success : StudioTheme.accent)
                .accessibilityLabel((copied ? "Скопировано: " : "Копировать: ") + title)
            }

            Text(content)
                .font(.callout)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    /// Подсказка под бейджем: «источник не зафиксирован» — только когда его
    /// действительно не записали. У шаблонного названия источник зафиксирован
    /// (это формула темы), и врать про незафиксированность он не имеет права.
    static func titleSourceHelp(for act: LongformAct) -> String {
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

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.nameFieldStringValue = result.outputURL.lastPathComponent
        if savePanel.runModal() == .OK, let target = savePanel.url {
            try? FileManager.default.copyItem(at: result.outputURL, to: target)
        }
    }
}
