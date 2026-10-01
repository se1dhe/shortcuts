import SwiftUI

@main
struct ShortcastApp: App {

    init() {
        setenv("OS_ACTIVITY_MODE", "disable", 1)
        
        // Workaround for e5rt/MPSGraph crash when loading WhisperKit models:
        // Clear the e5bundlecache to force recompilation of the Metal graph.
        if let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let bundleID = Bundle.main.bundleIdentifier ?? "app.shortcast.Shortcast"
            let e5rtCacheURL = cacheURL.appendingPathComponent(bundleID).appendingPathComponent("com.apple.e5rt.e5bundlecache")
            try? FileManager.default.removeItem(at: e5rtCacheURL)
        }

        FontDownloadService.shared.registerBundledFonts()
    }

    @State private var settings = AppSettings()
    @State private var modelManager = ModelManager()
    @State private var workspace = WorkspaceModel()
    @State private var languageManager = LanguageManager()
    @State private var movieShorts = MovieShortsBrowserModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(modelManager)
                .environment(workspace)
                .environment(languageManager)
                .environment(movieShorts)
                .task {
                    workspace.cleanUpOrphanedInputFiles(settings: settings)
                    await FontDownloadService.shared.ensureFontsInstalled()
                    await modelManager.prepareIfNeeded()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(modelManager)
                .environment(languageManager)
        }
    }
}
