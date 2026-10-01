import SwiftUI
import UniformTypeIdentifiers

/// Root view and state machine: model gate → drop → processing → results.
struct ContentView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace

    @State private var isDropTargeted = false
    @State private var showFirstLaunch = false

    var body: some View {
        ZStack {
            if modelManager.isReady {
                workspaceContent
                    .transition(.opacity)
            } else {
                ModelDownloadView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.32), value: modelManager.isReady)
        .animation(.smooth(duration: 0.32), value: workspace.phase)
        .frame(minWidth: 1000, minHeight: 720)
        .dropDestination(for: URL.self) { urls, _ in
            guard modelManager.isReady,
                  !workspace.isBusy,
                  let url = urls.first(where: { $0.isFileURL })
            else { return false }
            startProcessing(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showFirstLaunch) {
            FirstLaunchSheet(settings: settings)
        }
        .task {
            if !settings.hasWorkingDirectory {
                showFirstLaunch = true
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspace.phase {
        case .empty:
            DropZoneView(isDropTargeted: isDropTargeted) { url, metadata in
                startProcessing(url, sourceMetadata: metadata)
            }
        case .processing:
            ProcessingView()
        case .results:
            ResultsView()
        case .transcribing, .findingMoments:
            ShortsProgressView()
        case .shortsResults:
            ShortsResultsView()
        }
    }

    private func startProcessing(_ url: URL, sourceMetadata: VideoSourceMetadata? = nil) {
        let accessing = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            await workspace.process(
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

            Text("Welcome to Short Generator")
                .font(.title2.weight(.bold))

            Text("Choose a working folder for the app. All input videos, processed clips and temporary files will be stored here.\n\nThe folder must be on your Mac — not on an external drive or cloud volume.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Choose Working Folder…") {
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
        panel.message = "Choose a working folder for Short Generator"
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
