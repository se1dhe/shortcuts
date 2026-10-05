import SwiftUI
import UniformTypeIdentifiers

/// Main navigation sections in the application sidebar.
enum AppNavigationTab: String, CaseIterable, Identifiable {
    case create = "Создание шортсов"
    case longform = "Кино-эссе (YouTube 16:9)"
    case clips = "Студия шортсов"
    case music = "Фоновая музыка"
    case publish = "Выгрузка в соцсети"
    case history = "История видео"
    case settings = "Настройки"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .create: "scissors"
        case .longform: "film.fill"
        case .clips: "film.stack"
        case .music: "music.note"
        case .publish: "paperplane.fill"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// Root view and macOS-native NavigationSplitView layout.
struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace

    @State private var selectedTab: AppNavigationTab = .create
    @State private var isDropTargeted = false
    @State private var showFirstLaunch = false

    var body: some View {
        @Bindable var workspace = workspace

        mainLayout
            .animation(.smooth(duration: 0.32), value: workspace.phase)
            .frame(minWidth: 1100, minHeight: 740)
            .dropDestination(for: URL.self) { urls, _ in
                guard !workspace.isBusy,
                      let url = urls.first(where: { $0.isFileURL })
                else { return false }
            selectedTab = workspace.inputMode == .longform ? .longform : .create
            startProcessing(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: $showFirstLaunch) {
            FirstLaunchSheet(settings: settings)
        }
        .sheet(item: $workspace.pendingAudioSelection) { _ in
            AudioTrackSelectionSheet(
                workspace: workspace,
                modelManager: modelManager,
                settings: settings
            )
        }
        .task {
            if !settings.hasWorkingDirectory {
                showFirstLaunch = true
            }
        }
        .onChange(of: workspace.phase) { _, newPhase in
            if newPhase == .shortsResults || newPhase == .results {
                selectedTab = .clips
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .longform {
                workspace.inputMode = .longform
            } else if newTab == .create && workspace.inputMode == .longform {
                workspace.inputMode = .shorts
            }
        }
        .onChange(of: workspace.inputMode) { _, newMode in
            if newMode == .longform && selectedTab == .create {
                selectedTab = .longform
            } else if newMode != .longform && selectedTab == .longform {
                selectedTab = .create
            }
        }
    }

    // MARK: - Main Layout

    private var mainLayout: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detailContent
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(selection: $selectedTab) {
            Section("Генерация") {
                NavigationLink(value: AppNavigationTab.create) {
                    Label(AppNavigationTab.create.rawValue, systemImage: AppNavigationTab.create.symbol)
                }

                NavigationLink(value: AppNavigationTab.longform) {
                    Label(AppNavigationTab.longform.rawValue, systemImage: AppNavigationTab.longform.symbol)
                }
                
                NavigationLink(value: AppNavigationTab.clips) {
                    HStack {
                        Label(AppNavigationTab.clips.rawValue, systemImage: AppNavigationTab.clips.symbol)
                        Spacer()
                        if !workspace.clips.isEmpty {
                            Text("\(workspace.clips.count)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            Section("Медиа и продакшн") {
                NavigationLink(value: AppNavigationTab.music) {
                    Label(AppNavigationTab.music.rawValue, systemImage: AppNavigationTab.music.symbol)
                }

                NavigationLink(value: AppNavigationTab.publish) {
                    HStack {
                        Label(AppNavigationTab.publish.rawValue, systemImage: AppNavigationTab.publish.symbol)
                        Spacer()
                        let approved = workspace.approvedReadyCount
                        if approved > 0 {
                            Text("\(approved)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                }

                NavigationLink(value: AppNavigationTab.history) {
                    Label(AppNavigationTab.history.rawValue, systemImage: AppNavigationTab.history.symbol)
                }
            }

            Section("Система") {
                NavigationLink(value: AppNavigationTab.settings) {
                    Label(AppNavigationTab.settings.rawValue, systemImage: AppNavigationTab.settings.symbol)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarBottomInfo
        }
    }

    private let versionService: any AppVersionProviding = AppVersionService.shared

    private var sidebarBottomInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            
            HStack(spacing: 8) {
                Circle()
                    .fill(modelManager.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(modelManager.isReady ? "MLX Движок готов" : "Инициализация…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Text(versionService.displayVersion)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(versionService.detailedVersionInfo)
                .contextMenu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(versionService.detailedVersionInfo, forType: .string)
                    } label: {
                        Label("Скопировать версию", systemImage: "doc.on.doc")
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        if workspace.isBusy {
            busyProgressView
        } else {
            switch selectedTab {
            case .create, .longform:
                createSectionContent
            case .clips:
                clipsSectionContent
            case .music:
                MusicLibraryView()
            case .publish:
                PublishQueueView()
            case .history:
                ProcessedVideoHistoryView()
            case .settings:
                SettingsView()
            }
        }
    }

    @ViewBuilder
    private var busyProgressView: some View {
        switch workspace.phase {
        case .processing:
            ProcessingView()
        case .transcribing, .findingMoments:
            ShortsProgressView()
        case .buildingLongform(let fraction, let step):
            VStack(spacing: 20) {
                ProgressView(value: fraction) {
                    Text(step)
                        .font(.headline)
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 480)

                Text("Монтаж 4-актного кино-эссе (1920x1080 16:9 Shortcast Cinema)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        default:
            ProgressView()
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
        case .transcribing, .findingMoments:
            ShortsProgressView()
        case .selectingLongformConcept:
            ThematicConceptSelectionSheet(
                movieTitle: workspace.detectedMovie?.title ?? workspace.job?.effectiveTitle ?? "Фильм",
                concepts: workspace.discoveredConcepts,
                aiReasoning: workspace.thematicReasoning,
                onSelect: { concept, confirmedTitle, audioSettings in
                    workspace.confirmLongformConcept(
                        concept,
                        confirmedMovieTitle: confirmedTitle,
                        audioSettings: audioSettings,
                        settings: settings
                    )
                },
                onCancel: {
                    workspace.cancelLongformSelection()
                },
                onRegenerate: {
                    Task {
                        await workspace.regenerateThematicConcepts(modelManager: modelManager)
                    }
                }
            )
        case .buildingLongform(let fraction, let step):
            VStack(spacing: 20) {
                ProgressView(value: fraction) {
                    Text(step)
                        .font(.headline)
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 480)

                Text("Монтаж 4-актного кино-эссе (1920x1080 16:9 Shortcast Cinema)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        case .results:
            ResultsView()
        case .shortsResults:
            ShortsResultsView()
        case .longformResults:
            if let result = workspace.longformResult {
                LongformResultsView(
                    result: result,
                    movieTitle: workspace.detectedMovie?.title ?? workspace.job?.effectiveTitle ?? "Фильм",
                    onChooseAnotherTheme: {
                        workspace.chooseAnotherConcept()
                    },
                    onStartNewMovie: {
                        workspace.resetLongform()
                    }
                )
            } else {
                Text("Ролик не найден")
            }
        }
    }

    @ViewBuilder
    private var clipsSectionContent: some View {
        if workspace.clips.isEmpty && workspace.variants.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "film.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Шортсы пока не созданы")
                    .font(.headline)
                Text("Перетащите фильм или длинное видео в разделе 'Создание шортсов'")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Перейти к созданию") {
                    selectedTab = .create
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workspace.phase == .results {
            ResultsView()
        } else {
            ShortsResultsView()
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

            Text("Добро пожаловать в Short Generator")
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
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Выберите рабочую папку для Short Generator"
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
