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

    @State private var showPackagingExperiments = false
    @State private var playbackAudio = EssayResultPlaybackAudio()
    @State private var player: AVPlayer? = nil
    @State private var actPlaybackObserver: Any?
    @State private var activeActID: String?
    @State private var playbackTime: Double = 0
    @State private var isVideoPlaying = false
    @State private var fullscreenPlayerWindow: NSWindow?
    @State private var copiedTitle = false
    @State private var copiedDescription = false
    @State private var copiedTags = false
    @State private var copiedComment = false

    @State private var showSupportEditor = false
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
                            Text(result.arc.concept.displayWord.uppercased())
                                .font(.caption.weight(.black))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(StudioTheme.accent.opacity(0.18)))
                                .foregroundStyle(StudioTheme.accent)

                            Text("«\(movieTitle)»")
                                .font(.headline)
                        }

                        Text(L10n.tr(result.arc.concept.format.title)).font(.caption).foregroundStyle(.secondary)
                        if let job = workspace.job, !FileManager.default.fileExists(atPath: job.url.path) {
                            Label(L10n.tr("Исходник удалён. Сохранённый монтаж доступен; для предпросмотра и рендера нужен видеофайл."), systemImage: "externaldrive.badge.exclamationmark")
                                .font(.caption).foregroundStyle(StudioTheme.warning)
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
                        Button(L10n.tr("Редакторский проход"), systemImage: "wand.and.stars") {
                            workspace.improveLongform(existingResult: result, modelManager: modelManager, settings: settings)
                        }
                        .help(L10n.tr("Проверить диалоги с соседним контекстом, уточнить границы сцен и пересобрать эссе на той же теме"))

                        Button {
                            suspendResultsPlayback()
                            showSubtitleEditor = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "character.cursor.ibeam")
                                Text(L10n.tr("Редактировать субтитры"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.accent)
                        .disabled(workspace.isRefreshingLongformPackaging)
                        .help(L10n.tr("Исправить неточности в субтитрах и перерендерить видео с тем же монтажом"))

                        Button {
                            suspendResultsPlayback()
                            showActEditor = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "film.stack")
                                Text(L10n.tr("Монтажный стол"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioTheme.accent)
                        .help(L10n.tr("Обрезать начало и конец актов — титры и музыка подстроятся автоматически"))

                        Menu(L10n.tr("Монтаж шортсов"), systemImage: "scissors") {
                            if let release = workspace.currentEssayRelease, !release.shorts.isEmpty {
                                ForEach(release.shorts) { short in
                                    Button(short.title) {
                                        suspendResultsPlayback()
                                        editingShort = short
                                    }
                                        .disabled(!EssayShortEditing.canEdit(short, in: release))
                                }
                            } else {
                                Button(L10n.tr("Подготовить два шортса")) { onOpenShorts() }
                            }
                        }
                        .disabled(workspace.isWorkingOnEssayRelease)
                        .help(L10n.tr("Сцены, хук, тексты и субтитры каждого шортса"))

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                        } label: {
                            Label(L10n.tr("В Finder"), systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }.fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                if let rebuildError = workspace.errorMessage {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("Пересборка не завершилась"))
                                .font(.subheadline.weight(.bold))
                            Text(L10n.tr("Показан предыдущий экспорт длительностью %1$@. Новая версия не сохранена.", String(describing: formatDuration(result.duration))))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            if workspace.stagedArc != nil {
                                Text(L10n.tr("Черновик таймингов сохранён. Откройте «Монтажный стол», чтобы продолжить с него."))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudioTheme.accent)
                                Button(L10n.tr("Повторить сборку"), systemImage: "arrow.clockwise") {
                                    guard let draft = workspace.stagedArc else { return }
                                    workspace.rebuildLongformWithModifiedArc(
                                        modifiedArc: draft,
                                        existingResult: result,
                                        modelManager: modelManager,
                                        settings: settings
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(StudioTheme.accent)
                            }
                            Text(rebuildError)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                    .padding(.horizontal, 20)
                } else if workspace.stagedArc != nil {
                    Label(L10n.tr("Черновик монтажа сохранён и ждёт сборки. Откройте «Монтажный стол», чтобы продолжить."),
                          systemImage: "film.stack")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                }

                if let notes = result.arc.editorialNotes, !notes.isEmpty {
                    DisclosureGroup(L10n.tr("Замечания к монтажу (%1$@)", String(describing: notes.count))) {
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
                            Text(L10n.tr("План требует внимания"))
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
                            Text(L10n.tr("Хронометраж скорректирован"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(L10n.tr("Проект просил %1$@ — длина эссе рождается из материала темы и ограничена коридором 4:00–8:00.", String(describing: EssayDurationPolicy.format(legacyAsk))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                    .padding(.horizontal, 20)
                }

                playerPanel
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
                                    Text(L10n.tr(act.type.displayName))
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
                                    Text(L10n.tr(act.effectiveTitleSource.displayCaption)).lineLimit(1)
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
                        .help(L10n.tr("Перейти к акту «%1$@» в эссе", String(describing: L10n.tr(act.type.displayName))))
                    }
                }
                .padding(.horizontal, 20)
                HStack(spacing: 6) {
                    Image(systemName: "cursorarrow.click")
                    Text(activeActTitle.map { L10n.tr("Сейчас: %1$@", String(describing: $0)) } ?? L10n.tr("Нажмите на акт, чтобы перейти к его сценам"))
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
                Text(L10n.tr("Финальный монтаж"))
                    .font(.headline)

                // One explicit editorial approval hands the final essay to the
                // short generator and opens the complete publication package.
                VStack(spacing: 8) {
                    Text(L10n.tr("Проверьте монтаж и реплики. Когда эссе готово, переходите к подбору двух сильных моментов всего фильма."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        player?.pause()
                        onOpenShorts()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles.tv")
                                .font(.subheadline)
                            Text(workspace.currentEssayRelease?.hasReadyShorts == true
                                 ? L10n.tr("Перейти к шортсам")
                                 : L10n.tr("Эссе готово — к шортсам"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)
                    .disabled(workspace.isBusy)
                    Text(L10n.tr("Следом: два шортса → постинг выпуска"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(L10n.tr("Оформление публикации")).font(.headline)
                            Spacer()
                            Button {
                                Task { await workspace.refreshLongformPackaging(modelManager: modelManager) }
                            } label: {
                                if workspace.isRefreshingLongformPackaging {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.tr("Проверка героя и обложки…"))
                                } else {
                                    Label(L10n.tr("Обновить всё"), systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(workspace.isBusy)
                            .accessibilityLabel(L10n.tr("Обновить всё оформление публикации"))
                            .help(L10n.tr("Обновить обложку и тексты публикации. Видео повторно не рендерится."))
                        }
                        Button(L10n.tr("Варианты упаковки и результаты"), systemImage: "rectangle.on.rectangle") {
                            suspendResultsPlayback(); showPackagingExperiments = true
                        }.disabled(workspace.isBusy)
                        .sheet(isPresented: $showPackagingExperiments) { PackagingExperimentsView() }
                        Button(L10n.tr("Поддержка и благодарности"), systemImage: "heart.text.square") {
                            suspendResultsPlayback()
                            showSupportEditor = true
                        }.disabled(workspace.isBusy)
                        if let warning = workspace.longformPackagingError ?? result.packagingWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                        // Обложка по визуальному языку «Кадр & Сенс».
                        if let thumbURL = result.thumbnailURL, let nsImage = NSImage(contentsOf: thumbURL) {
                            thumbnailCard(image: nsImage, fileURL: thumbURL)
                            if let subject = result.thumbnailSubject {
                                Text(L10n.tr("Ведущий герой • исходник %1$@:%2$@ • проверка модели", String(describing: Int(subject.sourceTime) / 60), String(describing: String(format: "%02d", Int(subject.sourceTime) % 60))))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .help(L10n.tr("Проверка по ведущему составу: ") + subject.leadingCast.joined(separator: ", "))
                            }
                        }

                        // 1. Заголовок
                        metadataCard(
                            title: L10n.tr("Заголовок видео"),
                            content: result.metadata.title,
                            copied: copiedTitle
                        ) {
                            copyToClipboard(result.metadata.title)
                            copiedTitle = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTitle = false }
                        }

                        // 2. Описание
                        metadataCard(
                            title: L10n.tr("Описание эссе"),
                            content: publicationMetadata.description,
                            copied: copiedDescription,
                            lineLimit: nil
                        ) {
                            copyToClipboard(publicationMetadata.description)
                            copiedDescription = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDescription = false }
                        }

                        metadataCard(
                            title: L10n.tr("Теги YouTube · ключевые слова"),
                            content: result.metadata.tags.joined(separator: ", "),
                            copied: copiedTags,
                            lineLimit: 3
                        ) {
                            copyToClipboard(result.metadata.tags.joined(separator: ", "))
                            copiedTags = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTags = false }
                        }

                        // Хештеги в описании — отдельное поле от keyword tags API.
                        metadataCard(
                            title: L10n.tr("Хештеги YouTube"),
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
                            title: L10n.tr("Закрепленный комментарий"),
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
                            Text(L10n.tr("Выбрать другую тему"))
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioTheme.accent)
                    .help(L10n.tr("Выбрать или ввести другую тему без повторного анализа фильма"))

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
                            Text(L10n.tr("Пересчитать сцены с AI"))
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help(L10n.tr("Попросить модель заново выбрать сцены и распределить их по актам на той же теме"))

                    Button(role: .destructive) {
                        onStartNewMovie()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text(L10n.tr("Новый фильм"))
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("Сбросить текущий фильм и добавить другой"))

                    Spacer()

                    Button {
                        exportFile()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text(L10n.tr("Экспорт…"))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
            .frame(width: 400)
        }
        .sheet(isPresented: $showSupportEditor, onDismiss: resumeResultsPlayback) {
            EssaySupportEditor(support: result.arc.support ?? EssaySupport(donatelloURL: settings.donatelloURL,
                    creditsEnabled: false, nicknames: settings.essaySupport.nicknames),
                ctaText: LongformEditorialSupport.finalCard(for: result.arc), theme: result.arc.concept.displayWord) { support in
                try await workspace.saveEssaySupport(support, modelManager: modelManager, settings: settings)
            }
        }
        .sheet(item: $editingShort, onDismiss: resumeResultsPlayback) { short in
            if let source = workspace.job?.url, let transcript = workspace.storedTranscript ?? workspace.currentProject?.transcript {
                EssayShortEditorView(short: short, result: result, transcript: transcript, sourceURL: source) { edited in
                    try await workspace.rebuildEssayShort(edited, settings: settings)
                }
            }
        }
        .sheet(isPresented: $showSubtitleEditor, onDismiss: resumeResultsPlayback) {
            if let transcript = workspace.storedTranscript {
                let editorArc = workspace.stagedArc ?? result.arc
                LongformSubtitleEditorView(
                    arc: editorArc,
                    concept: editorArc.concept,
                    movieTitle: movieTitle,
                    allSegments: transcript.segments,
                    correctionFilmKey: workspace.subtitleCorrectionFilmKey,
                    correctionLanguage: workspace.subtitleCorrectionLanguage,
                    sourceURL: workspace.job?.url,
                    confirmButtonTitle: L10n.tr("Перерендерить с исправленными субтитрами"),
                    backButtonTitle: L10n.tr("Отмена"),
                    onAutoCorrect: { input, progress in
                        try await workspace.correctLongformSubtitleDraft(
                            input,
                            movieTitle: movieTitle,
                            language: workspace.subtitleCorrectionLanguage,
                            modelManager: modelManager,
                            settings: settings,
                            progress: progress
                        )
                    },
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
        .sheet(isPresented: $showActEditor, onDismiss: {
            if case .longformResults = workspace.phase {
                resumeResultsPlayback()
            }
        }) {
            if let transcript = workspace.storedTranscript {
                let editorArc = workspace.stagedArc ?? result.arc
                LongformActEditorView(
                    arc: editorArc,
                    concept: editorArc.concept,
                    movieTitle: movieTitle,
                    transcriptSegments: transcript.segments,
                    sourceURL: workspace.job?.url,
                    coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true,
                    audioSettings: result.audioSettings ?? LongformAudioSettings(),
                    onReview: { draft, progress in
                        try await workspace.reviewLongformEditorDraft(
                            draft, modelManager: modelManager, settings: settings, progress: progress)
                    },
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
                        resumeResultsPlayback()
                    }
                )
            }
        }
        .onAppear {
            resumeResultsPlayback()
        }
        .onChange(of: result.outputURL) { _, newURL in
            removeActPlaybackObserver()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playbackAudio.stop()
            let next = MontageVideoPreviewPlayer.makeVideoOnlyPlayer(url: newURL)
            player = next
            playbackTime = 0
            isVideoPlaying = false
            activeActID = nil
            observeActPlayback(on: next)
        }
        .onDisappear {
            suspendResultsPlayback()
        }
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
    }

    private var playerPanel: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let player {
                if fullscreenPlayerWindow == nil {
                    StudioPlayerSurface(player: player)
                }
                VStack {
                    if playbackAudio.isPreparing { Text(L10n.tr("Подготавливаю звук…")).padding(8).background(.black.opacity(0.8)) }
                    if let error = playbackAudio.error { Text(L10n.tr(error)).foregroundStyle(.orange).padding(8) }
                    playerControls
                }.padding(14)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private var playerControls: some View {
        HStack(spacing: 12) {
            Button {
                guard let player else { return }
                playbackAudio.toggle(player: player, url: result.outputURL, duration: result.duration)
            } label: {
                Image(systemName: playbackAudio.isPreparing ? "hourglass" : (isVideoPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.accent)
            .help(isVideoPlaying ? L10n.tr("Пауза") : L10n.tr("Воспроизвести"))

            Text(formatDuration(playbackTime))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Slider(value: Binding(
                get: { playbackTime },
                set: { value in
                    playbackTime = value
                }
            ), in: 0...max(result.duration, 0.1), onEditingChanged: { editing in
                guard !editing else { return }
                if let player { playbackAudio.seek(player: player, url: result.outputURL, time: playbackTime, duration: result.duration) }
            })
            .tint(StudioTheme.accent)

            Text(formatDuration(result.duration))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))

            Button {
                openFullscreenPlayer()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(L10n.tr("На весь экран"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
    }

    private func openFullscreenPlayer() {
        guard let player, fullscreenPlayerWindow == nil else { return }
        let content = FullscreenEssayPlayerView(player: player, duration: result.duration, onToggle: {
            playbackAudio.toggle(player: player, url: result.outputURL, duration: result.duration)
        }, onSeek: { time in
            playbackAudio.seek(player: player, url: result.outputURL, time: time, duration: result.duration)
        }) {
            let window = fullscreenPlayerWindow
            fullscreenPlayerWindow = nil
            window?.close()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("КАДР & СЕНС · %1$@", String(describing: movieTitle))
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        fullscreenPlayerWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.toggleFullScreen(nil) }
    }

    /// Editors create their own source-film preview player. Tear down the result
    /// player's item before presenting one so macOS never has two active audio
    /// queues competing during seek/preroll.
    private func suspendResultsPlayback() {
        removeActPlaybackObserver()
        playbackAudio.stop()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isVideoPlaying = false
    }

    private func resumeResultsPlayback() {
        guard player == nil else { return }
        let next = MontageVideoPreviewPlayer.makeVideoOnlyPlayer(url: result.outputURL)
        player = next
        observeActPlayback(on: next)
    }

    private var activeActTitle: String? {
        guard let activeActID else { return nil }
        return result.arc.acts.first(where: { $0.id == activeActID }).map { L10n.tr($0.type.displayName) }
    }

    private func seekToAct(at index: Int) {
        guard result.arc.acts.indices.contains(index),
              let start = LongformTimeline(
                arc: result.arc,
                coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true
              ).start(ofAct: index) else { return }
        activeActID = result.arc.acts[index].id
        if let player { playbackAudio.seek(player: player, url: result.outputURL, time: start, duration: result.duration) }
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
                    if seconds.isFinite { playbackTime = max(0, min(seconds, result.duration)) }
                    let playing = player.timeControlStatus == .playing
                    if isVideoPlaying != playing { isVideoPlaying = playing }
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
                Text(L10n.tr("Обложка YouTube (1920×1080)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await workspace.regenerateLongformCover(modelManager: modelManager) }
                } label: {
                    if workspace.isRegeneratingLongformCover {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Подбираем кадр…"))
                    } else {
                        Label(L10n.tr("Другой кадр"), systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(StudioTheme.accent)
                .disabled(workspace.isBusy)
                .help(L10n.tr("Сгенерировать отдельный вариант обложки с другим кадром подтверждённого главного актёра"))

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(L10n.tr("В Finder"), systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(StudioTheme.accent)

                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Label(L10n.tr("Открыть"), systemImage: "arrow.up.forward.app")
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
                    Label(copied ? L10n.tr("Скопировано!") : L10n.tr("Копировать"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? StudioTheme.success : StudioTheme.accent)
                .accessibilityLabel((copied ? L10n.tr("Скопировано: ") : L10n.tr("Копировать: ")) + title)
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
