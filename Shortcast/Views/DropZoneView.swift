import SwiftUI
import UniformTypeIdentifiers

/// The idle state: a big drag-and-drop target for a short video.
struct DropZoneView: View {

    let isDropTargeted: Bool
    let onChooseFile: (URL, VideoSourceMetadata?) -> Void

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @Environment(LanguageManager.self) private var languageManager
    @State private var showingImporter = false
    @State private var showRestartAlert = false

    var body: some View {
        @Bindable var workspace = workspace
        @Bindable var settings = settings


        VStack(spacing: 18) {
            Spacer()

            Picker("Mode", selection: $workspace.inputMode) {
                ForEach(WorkspaceModel.InputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            if workspace.inputMode == .youtube {
                YouTubeContainerView(onVideoReady: onChooseFile)
            } else {
                Toggle(isOn: $settings.transcriptionEnabled) {
                    Label("Транскрибация видео (WhisperKit)", systemImage: "captions.bubble")
                        .font(.callout.weight(.medium))
                }
                .toggleStyle(.switch)
                .help("Выключите транскрибацию, чтобы редактор открывался мгновенно без ожидания Whisper.")

                dropArea
            }


            if let error = workspace.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }

            Spacer()

            Text("Everything runs on your Mac. Your video is never uploaded until you press Publish.")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        languageManager.selectedLanguage = lang
                        showRestartAlert = true
                    } label: {
                        Text(lang.flag)
                            .font(.title3)
                            .opacity(languageManager.selectedLanguage == lang ? 1.0 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .help(lang.label)
                }
            }
            .padding(.top, 4)
        }
        .padding(44)
        .alert("Restart required", isPresented: $showRestartAlert) {
            Button("Restart now") { restartApp() }
            Button("Later", role: .cancel) { }
        } message: {
            Text("The language change will take effect after the app restarts.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie] + [UTType(filenameExtension: "mkv"), UTType(filenameExtension: "webm"), UTType(filenameExtension: "avi")].compactMap { $0 }
        ) { result in
            if case .success(let url) = result { onChooseFile(url, nil) }
        }
    }

    private var dropArea: some View {
        VStack(spacing: 14) {
            Image(systemName: workspace.inputMode.symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            Text(workspace.inputMode.dropTitle)
                .font(.title2.weight(.semibold))

            Text(workspace.inputMode == .shorts
                 ? "MP4, MKV, WebM or AVI — unsupported containers are converted to MP4 on your Mac before processing."
                 : workspace.inputMode.dropSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(workspace.inputMode == .shorts ? "Выбрать фильм…" : "Choose video…") {
                showingImporter = true
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: 560, minHeight: 320)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isDropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                     : AnyShapeStyle(Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private func restartApp() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Short Generator")
        _ = try? Process.run(url, arguments: [])
        NSApplication.shared.terminate(nil)
    }
}
