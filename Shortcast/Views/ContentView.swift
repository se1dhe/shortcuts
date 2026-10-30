import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace
    @State private var isDropTargeted = false
    @State private var showFirstLaunch = false
    @State private var showSettings = false

    @State private var selectedStage: StudioStage = .film

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            studioHeader
            stageNavigation
            Rectangle().fill(StudioTheme.line).frame(height: 1)
            stageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .frame(minWidth: 1180, minHeight: 860)
        .dropDestination(for: URL.self) { urls, _ in
            guard !workspace.isBusy, let url = urls.first(where: { $0.isFileURL }) else { return false }
            startProcessing(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showFirstLaunch) { FirstLaunchSheet(settings: settings) }
        .sheet(item: $workspace.pendingAudioSelection) { _ in
            AudioTrackSelectionSheet(workspace: workspace, modelManager: modelManager, settings: settings)
        }
        .task { if !settings.hasWorkingDirectory { showFirstLaunch = true } }
        .onChange(of: workspace.phase) { _, phase in
            switch phase {
            case .empty, .processing: selectedStage = .film
            default: selectedStage = .essay
            }
        }
    }

    private var studioHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(StudioTheme.accent)
                .frame(width: 42, height: 42)
                .background(StudioTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("КАДР & СЕНС").font(.system(size: 12, weight: .bold)).tracking(2.4)
                Text("Монтажная выпуска").font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
            }
            Rectangle().fill(StudioTheme.line).frame(width: 1, height: 30).padding(.horizontal, 10)
            Text(workspace.detectedMovie?.title ?? workspace.currentProject?.movieTitle ?? "Новый проект")
                .font(.system(size: 14, weight: .medium)).lineLimit(1)
            if workspace.currentProject != nil {
                Label("Локальный проект", systemImage: "checkmark.icloud")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
            }
            Spacer()
            if workspace.job != nil {
                Button("Новый фильм", systemImage: "plus") {
                    workspace.startOver(); selectedStage = .film
                }.buttonStyle(.bordered).disabled(workspace.isBusy)
            }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 30, height: 30)
            }.buttonStyle(.plain).help("Настройки студии").disabled(workspace.isBusy)
        }.padding(.horizontal, 28).padding(.vertical, 18)
    }

    private var stageNavigation: some View {
        HStack(spacing: 12) {
            ForEach(StudioStage.allCases) { stage in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedStage = stage }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedStage == stage ? StudioTheme.accent : Color.white.opacity(0.04))
                            Image(systemName: stage.symbol)
                                .foregroundStyle(selectedStage == stage ? StudioTheme.background : StudioTheme.muted)
                        }.frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text(String(format: "%02d", stage.rawValue + 1))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(StudioTheme.muted)
                                Text(stage.title).font(.system(size: 14, weight: .semibold))
                            }
                            Text(stage.detail).font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                        }
                        Spacer(minLength: 0)
                        if completed(stage) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green.opacity(0.8))
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedStage == stage ? StudioTheme.raised : StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selectedStage == stage ? StudioTheme.accent.opacity(0.4) : StudioTheme.line))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
                    .disabled(!available(stage) || workspace.isBusy)
                    .opacity(available(stage) ? 1 : 0.85)
                    .help(available(stage) ? stage.detail : "Сначала завершите предыдущий шаг")
            }
        }.padding(.horizontal, 28).padding(.bottom, 22)
    }

    private func available(_ stage: StudioStage) -> Bool {
        switch stage {
        case .film: true
        case .essay: workspace.job != nil
        case .shorts: workspace.longformResult != nil
        case .posting: workspace.currentEssayRelease != nil
        }
    }

    private func completed(_ stage: StudioStage) -> Bool {
        switch stage {
        case .film: workspace.job != nil
        case .essay: workspace.longformResult != nil
        case .shorts: workspace.currentEssayRelease?.hasReadyShorts == true
        case .posting: workspace.currentEssayRelease?.isPublished == true
        }
    }

    @ViewBuilder private var stageContent: some View {
        if workspace.showsPipelineProgress {
            createSectionContent
        } else {
            switch selectedStage {
            case .film:
                if let job = workspace.job {
                    FilmSourceOverview(job: job) { selectedStage = .essay }
                } else {
                    DropZoneView(isDropTargeted: isDropTargeted) { url, metadata in
                        startProcessing(url, sourceMetadata: metadata)
                    }
                }
            case .essay:
                createSectionContent
            case .shorts:
                if let result = workspace.longformResult {
                    EssayShortsStudioView(result: result, onOpenPosting: { selectedStage = .posting })
                }
            case .posting:
                if let result = workspace.longformResult {
                    EssayPostingView(result: result, onBack: { selectedStage = .shorts })
                }
            }
        }
    }

    @ViewBuilder
    private var createSectionContent: some View {
        switch workspace.phase {
        case .empty:
            DropZoneView(isDropTargeted: isDropTargeted) { url, metadata in
                startProcessing(url, sourceMetadata: metadata)
            }
        case .processing:
            ProcessingView()
        case .transcribing:
            FilmAnalysisProgressView()
        case .selectingLongformConcept:
            ThematicConceptSelectionSheet(
                movieTitle: workspace.detectedMovie?.title ?? workspace.job?.effectiveTitle ?? "Фильм",
                concepts: workspace.discoveredConcepts,
                aiReasoning: workspace.thematicReasoning,
                source: workspace.thematicAnalysis?.source ?? .unknown,
                isRegenerating: workspace.isRegeneratingConcepts,
                essayPlan: workspace.thematicAnalysis?.essayPlan,
                planningError: workspace.errorMessage,
                cancelTitle: workspace.longformResult == nil ? "Отмена" : "Открыть готовое эссе",
                onSelect: { concept, confirmedTitle, audioSettings, essayPlan in
                    workspace.confirmLongformConcept(
                        concept,
                        confirmedMovieTitle: confirmedTitle,
                        audioSettings: audioSettings,
                        essayPlan: essayPlan,
                        modelManager: modelManager,
                        settings: settings
                    )
                },
                onCancel: {
                    workspace.cancelLongformSelection()
                },
                onRegenerate: {
                    Task {
                        await workspace.regenerateThematicConcepts(
                            modelManager: modelManager,
                            directorProfile: settings.copywriterModel.directorProfile
                        )
                    }
                }
            )
        case .editingLongformSubtitles:
            if let stagedConcept = workspace.stagedConcept,
               let stagedArc = workspace.stagedArc,
               let transcript = workspace.storedTranscript {
                LongformSubtitleEditorView(
                    arc: stagedArc,
                    concept: stagedConcept,
                    movieTitle: workspace.stagedConfirmedMovieTitle ?? workspace.detectedMovie?.title ?? "Фильм",
                    allSegments: transcript.segments,
                    correctionFilmKey: workspace.subtitleCorrectionFilmKey,
                    correctionLanguage: workspace.subtitleCorrectionLanguage,
                    sourceURL: workspace.job?.url,
                    onConfirm: { updatedSegments in
                        workspace.confirmLongformSubtitlesAndBuild(
                            updatedSegments: updatedSegments,
                            modelManager: modelManager,
                            settings: settings
                        )
                    },
                    onBack: {
                        workspace.returnToConceptSelection()
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Text("Данные субтитров не найдены")
                        .font(.headline)
                    Button("Назад") {
                        workspace.returnToConceptSelection()
                    }
                }
            }
        case .buildingLongform(let fraction, let step):
            VStack(spacing: 20) {
                ProgressView(value: fraction) {
                    Text(step)
                        .font(.headline)
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 480)

                Text("Монтаж кино-эссе · 16:9")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        case .longformResults:
            if let result = workspace.longformResult {
                LongformResultsView(
                    result: result,
                    movieTitle: workspace.detectedMovie?.title ?? workspace.job?.effectiveTitle ?? "Фильм",
                    onChooseAnotherTheme: {
                        workspace.chooseAnotherConcept()
                    },
                    onStartNewMovie: { workspace.startOver() },
                    onOpenShorts: { selectedStage = .shorts }

                )
            } else {
                Text("Ролик не найден")
            }
        }
    }

    private func startProcessing(_ url: URL, sourceMetadata: VideoSourceMetadata? = nil) {
        let accessing = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            await workspace.prepareAndProcess(
                url: url,
                sourceMetadata: sourceMetadata,
                modelManager: modelManager,
                settings: settings)
        }
    }
}

// MARK: - First-launch setup

private struct FirstLaunchSheet: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("Добро пожаловать в КАДР & СЕНС")
                .font(.title2.weight(.bold))

            Text("Выберите рабочую папку. Все загруженные видео, обработанные клипы и кэш будут храниться здесь.\n\nПапка должна находиться на вашем Mac — не на внешнем или сетевом диске.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Выбрать рабочую папку…") {
                selectFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if settings.hasWorkingDirectory {
                Text(settings.workingDirectoryLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(40)
        .frame(width: 500)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Выберите рабочую папку для КАДР & СЕНС"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.workingDirectory = url
                if settings.outputDirectory == nil {
                    settings.outputDirectory = url
                }
                dismiss()
            }
        }
    }
}
