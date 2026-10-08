import SwiftUI
import AppKit

/// The single configuration screen (⌘,): Upload-Post account, caption style,
/// publishing options, and model status.
struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager

    private enum ConnectionState: Equatable {
        case idle, checking, ok, failed(String)
    }
    @State private var connection: ConnectionState = .idle

    private let cleanupService: any ProjectCleanupServiceProtocol = ProjectCleanupService.shared
    @State private var removableSizeBytes: Int64?
    @State private var isCalculatingSize = false
    @State private var isCleaning = false
    @State private var cleanupResult: CleanupReport?
    @State private var showCleanupConfirm = false

    @State private var isOpeningBrowserLogin = false
    @State private var isCheckingBrowserAuth = false
    @State private var browserAuthStatus: BrowserAuthStatus?
    @State private var browserAuthError: String?

    private enum TelegramConnectionState: Equatable {
        case idle, checking, ok(String), failed(String)
    }
    @State private var telegramConnection: TelegramConnectionState = .idle

    @State private var showCorrectionsDictionary = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Браузерная публикация (Без API-ключей)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Автономная публикация шортсов напрямую через локальный Google Chrome. Не требует платных агрегаторов, прохождения строгой модерации Meta / TikTok или developer API-ключей.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            openBrowserLogin()
                        } label: {
                            Label("Войти в аккаунты", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isOpeningBrowserLogin)

                        Button("Проверить статус") {
                            checkBrowserAuth()
                        }
                        .disabled(isCheckingBrowserAuth)

                        if isOpeningBrowserLogin || isCheckingBrowserAuth {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if let status = browserAuthStatus {
                        HStack(spacing: 16) {
                            browserPlatformBadge("TikTok", ok: status.tiktok)
                            browserPlatformBadge("Instagram", ok: status.instagram)
                            browserPlatformBadge("YouTube", ok: status.youtube)
                        }
                        .padding(.vertical, 4)
                    }

                    if let err = browserAuthError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("Профиль и сохранённые сессии хранятся локально: ~/Library/Application Support/Shortcast/BrowserProfile")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Telegram-канал") {
                SecureField("Токен бота Telegram", text: $settings.telegramBotToken)
                TextField("Канал (username или ID)", text: $settings.telegramChannelId)

                Toggle("Автопубликация при экспорте", isOn: $settings.autoPostToTelegram)

                Text("Для автоматической публикации шортсов и карточек фильмов в ваш Telegram-канал создайте бота в @BotFather, скопируйте токен и добавьте бота администратором в ваш канал с правом публикации сообщений.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Проверить бота", action: testTelegramConnection)
                        .disabled(settings.telegramBotToken.trimmed.isEmpty || telegramConnection == .checking)
                    telegramConnectionStatus
                    Spacer()
                    Link("Создать бота (@BotFather) ↗", destination: URL(string: "https://t.me/BotFather")!)
                }
            }

            Section("Upload-Post account") {
                SecureField("API key", text: $settings.apiKey)
                TextField("Profile name", text: $settings.profileName)

                Text("Create an API key and a profile in the Upload-Post dashboard. The profile name is the one from **Manage Users** — not your social handle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Test connection", action: testConnection)
                        .disabled(settings.apiKey.trimmed.isEmpty || connection == .checking)
                    connectionStatus
                    Spacer()
                    Link("Connect accounts ↗", destination: URL(string: "https://app.upload-post.com")!)
                }
            }

            Section("TMDB") {
                SecureField("TMDB API key", text: $settings.tmdbAPIKey)
                Text("Used in the Cinema preset to look up movie metadata (title, year, genres) for better hashtags and context. Get a free key at themoviedb.org.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("YouTube Data API") {
                SecureField("YouTube API key", text: $settings.youtubeAPIKey)
                Text("Used to discover trending Russian movie Shorts in the YouTube → Movie Shorts tab. Get a free key at Google Cloud Console, enable YouTube Data API v3, and paste it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Open Google Cloud Console ↗", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
            }

            Section("YouTube cookies") {
                TextField("Cookies file path", text: $settings.youtubeCookiesPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("For age-restricted videos. Export cookies from your browser:\n\n1. Run this in Terminal:\n   yt-dlp --cookies-from-browser safari --cookies ~/Desktop/cookies.txt --skip-download \"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"\n2. Wait a few seconds — cookies.txt will appear on your Desktop.\n3. Paste the file path above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Captions") {
                TextField(
                    "Language",
                    text: $settings.languageOverride,
                    prompt: Text("Auto-detect from the video"))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your style examples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.styleExamples)
                        .font(.body)
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    Text("Optional. Paste a few captions you like — the model will match your voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Publishing") {
                Toggle("Upload TikTok as a draft", isOn: $settings.tiktokAsDraft)
                Text("Drafts land in the TikTok inbox so you can finish editing in the app before posting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Защита от Content ID (TikTok Shield)") {
                Toggle("Включить защиту по умолчанию", isOn: $settings.antiCopyrightEnabled)
                if settings.antiCopyrightEnabled {
                    Picker("Пресет по умолчанию", selection: $settings.antiCopyrightPreset) {
                        ForEach(AntiCopyrightPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                }
                Text("Автоматически применяет акустический питч-шифт (+14¢), зеркалирование, 35мм микро-зерно и спектральный EQ ко всем шортсам. Защищает от блокировок звука и теневых банов в TikTok.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Working folder") {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(settings.workingDirectoryLabel)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { selectWorkingFolder() }
                        .buttonStyle(.borderless)
                    Button { settings.workingDirectory = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.workingDirectory == nil)
                }
                Text("Input videos are copied here before processing to avoid sandbox limitations. Processed clips and temporary files also live in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Movie Library") {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .foregroundStyle(.secondary)
                    Text(settings.movieLibraryLabel)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { selectMovieLibraryFolder() }
                        .buttonStyle(.borderless)
                    Button { settings.movieLibraryURL = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.movieLibraryURL == nil)
                }
                Text("Папка с локальной коллекцией фильмов. Вкладка «Библиотека фильмов» сканирует её, находит MKV/MP4/MOV/AVI/WebM и нормализует контейнер до MP4 перед обработкой.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Транскрибация") {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.checkmark")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Словарь исправлений Whisper")
                            .font(.callout)
                        Text("Правки субтитров накапливаются и передаются в Whisper как контекст — самообучение модели.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Открыть словарь…") { showCorrectionsDictionary = true }
                        .buttonStyle(.borderless)
                }
            }

            Section("Background Music folder") {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                    Text(settings.customMusicDirectoryLabel)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { selectCustomMusicFolder() }
                        .buttonStyle(.borderless)
                    Button { settings.customMusicDirectory = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.customMusicDirectory == nil)
                }
                Text("Select a folder containing .mp3/.wav files. The AI will randomly pick a track and duck it under the speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output folder") {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(settings.outputDirectoryLabel)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { selectOutputFolder() }
                        .buttonStyle(.borderless)
                    Button { settings.outputDirectory = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.outputDirectory == nil)
                }
                Text("YouTube downloads and exported videos are saved here. Uses the system temporary folder by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Project storage & cleanup") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Deep clean project")
                                .font(.callout.weight(.medium))
                            Text("Deletes render cache, intermediate clip cuts, input copies, and compiler caches to reclaim disk space.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            showCleanupConfirm = true
                        } label: {
                            if isCleaning {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Clean Now")
                            }
                        }
                        .disabled(isCleaning)
                    }

                    HStack(spacing: 8) {
                        if let bytes = removableSizeBytes {
                            Text("Removable cache size: **\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))**")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isCalculatingSize {
                            ProgressView().controlSize(.mini)
                            Text("Calculating cache size…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task { await refreshRemovableSize() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isCleaning || isCalculatingSize)
                        .help("Refresh cache size")
                    }

                    if let result = cleanupResult {
                        Label("Freed \(result.formattedBytesFreed) (\(result.filesRemovedCount) files removed)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .confirmationDialog(
                    "Deep Clean Project?",
                    isPresented: $showCleanupConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete Cached and Temporary Files", role: .destructive) {
                        runDeepClean()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will delete all cached renders, temporary cuts, and copies of videos in the input folder. Your original media and exported files in the output directory will not be touched.")
                }
            }

            Section("How a long video becomes shorts") {
                pipelineRole(
                    step: "1", icon: "waveform",
                    title: "Transcribe",
                    model: "WhisperKit · large-v3-turbo",
                    detail: "Turns the audio into text. Runs only when the video has no .srt/.vtt next to it.",
                    status: nil)
                pipelineRole(
                    step: "2", icon: "wand.and.stars",
                    title: "Find the viral moments",
                    model: settings.copywriterModel.directorProfile.displayName,
                    detail: "Reads the whole transcript and picks the best clips. Follows your model choice below.",
                    status: directorStatus)
                pipelineRole(
                    step: "3", icon: "text.bubble",
                    title: "Write the captions",
                    model: settings.copywriterModel.displayName,
                    detail: "You choose this one ↓",
                    status: settings.copywriterModel.watchesClips ? modelStatus : directorStatus)
            }

            Section("Режим поиска киномоментов (Жанр)") {
                Picker("Направление поиска", selection: $settings.cinemaGenreMode) {
                    ForEach(CinemaGenreMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.cinemaGenreMode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Caption writer") {
                Picker("Model", selection: $settings.copywriterModel) {
                    ForEach(AppSettings.CopywriterModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(settings.copywriterModel.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Picks the model that finds the moments and writes the captions for shorts cut from a long video. Captioning a single short video always uses Gemma E4B (it watches the clip directly).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.copywriterModel.watchesClips && modelManager.systemRAMGB < 24 {
                    Label("On this Mac, Short Generator frees the moment-finder before captioning to stay within memory.",
                          systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Text hook overlay") {
                Toggle("Burn an AI text hook into each short", isOn: $settings.burnHookOverlay)
                Text("Shows a short hook over the top of each clip for the first few seconds. The default for new shorts — you can flip it per clip. The text is rendered into the video when you publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vertical reframing") {
                Toggle("Auto-convert horizontal clips to vertical 9:16", isOn: $settings.reframeToVertical)
                Text("Tracks the speaker with on-device Vision and reframes 16:9 → 9:16, falling back to a blurred background when there's no clear face. The default for new horizontal clips — you can flip it per clip. Applied when you publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bot promo") {
                Toggle("Show RedQueen bot promo on shorts", isOn: $settings.promoOverlayEnabled)

                if settings.promoOverlayEnabled {
                    HStack {
                        Text("Banner duration")
                        Spacer()
                        TextField("0", value: $settings.promoDurationSeconds,
                                  format: .number.precision(.fractionLength(0)))
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Text("sec").foregroundStyle(.secondary)
                    }
                    Text("How long the banner stays before it slides back up. 0 = half the video.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("Burns a slim, animated @RedQueenSecurity_Bot promo chip at the top of each short — a crimson shield with a light sweep, kept small so it never covers the content. Default for new clips — you can flip it per clip in the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Toggle("Transcribe audio (WhisperKit)", isOn: $settings.transcriptionEnabled)
                if settings.transcriptionEnabled {
                    Text("Runs WhisperKit on the video's audio to produce a transcript. Required for subtitles and on-device captions. Disable to skip this step — the editor opens immediately after download, but subtitles will be unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Subtitles are disabled when transcription is off.", systemImage: "captions.bubble")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Subtitles") {
                Toggle("Burn transcript subtitles into each short", isOn: $settings.burnSubtitles)
                    .disabled(!settings.transcriptionEnabled)
                Text("Show timed subtitles from the transcription burned directly into the video. The default for new shorts — you can flip it per clip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SubtitleAppearanceEditor(appearance: $settings.subtitleAppearance)
                    .disabled(!settings.transcriptionEnabled)
                    .opacity(settings.transcriptionEnabled ? 1 : 0.4)
            }


            Section("Watermark") {
                Toggle("Show watermark on shorts", isOn: $settings.watermarkEnabled)
                Toggle("Show watermark on full video", isOn: $settings.watermarkFullVideoEnabled)

                if settings.watermarkEnabled || settings.watermarkFullVideoEnabled {
                    TextField("Watermark text",
                              text: $settings.watermarkText,
                              prompt: Text("@yourhandle"))
                        .font(.callout)

                    WatermarkAppearanceEditor(appearance: $settings.watermarkAppearance)
                }

                Text("Burns a configurable watermark (typewriter / fade / static) into shorts and full video exports. The text is rendered as a monospace overlay in the chosen corner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("This Mac") {
                LabeledContent("Memory", value: "\(modelManager.systemRAMGB) GB")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
        .task(id: settings.workingDirectory) {
            await refreshRemovableSize()
        }
        .task {
            checkBrowserAuth()
        }
        .sheet(isPresented: $showCorrectionsDictionary) {
            CorrectionsDictionaryView()
        }
    }

    // MARK: - Browser Publishing Actions

    @ViewBuilder
    private func browserPlatformBadge(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }

    private func checkBrowserAuth() {
        isCheckingBrowserAuth = true
        browserAuthError = nil
        Task {
            do {
                let status = try await BrowserAutomationService.shared.checkAuthStatus()
                await MainActor.run {
                    browserAuthStatus = status
                    isCheckingBrowserAuth = false
                }
            } catch {
                await MainActor.run {
                    browserAuthError = error.localizedDescription
                    isCheckingBrowserAuth = false
                }
            }
        }
    }

    private func openBrowserLogin() {
        isOpeningBrowserLogin = true
        browserAuthError = nil
        Task {
            do {
                let status = try await BrowserAutomationService.shared.openLoginSession()
                await MainActor.run {
                    browserAuthStatus = status
                    isOpeningBrowserLogin = false
                }
            } catch {
                await MainActor.run {
                    browserAuthError = error.localizedDescription
                    isOpeningBrowserLogin = false
                }
            }
        }
    }

    // MARK: - Cleanup actions

    private func refreshRemovableSize() async {
        isCalculatingSize = true
        removableSizeBytes = await cleanupService.calculateRemovableSize(workingDirectory: settings.workingDirectory)
        isCalculatingSize = false
    }

    private func runDeepClean() {
        isCleaning = true
        cleanupResult = nil
        Task {
            do {
                let report = try await cleanupService.performDeepClean(workingDirectory: settings.workingDirectory)
                cleanupResult = report
                removableSizeBytes = await cleanupService.calculateRemovableSize(workingDirectory: settings.workingDirectory)
            } catch {
                // Non-fatal cleanup error
            }
            isCleaning = false
        }
    }

    // MARK: - Connection test

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func testConnection() {
        connection = .checking
        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        Task {
            do {
                try await client.checkConnection()
                connection = .ok
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var telegramConnectionStatus: some View {
        switch telegramConnection {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let info):
            Label(info, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func testTelegramConnection() {
        telegramConnection = .checking
        let botToken = settings.telegramBotToken
        let channelId = settings.telegramChannelId
        Task {
            do {
                let (botUsername, channelTitle) = try await TelegramPublishingService.shared.testConnection(
                    botToken: botToken,
                    channelId: channelId
                )
                telegramConnection = .ok("Бот \(botUsername) подключен к «\(channelTitle)»")
            } catch {
                telegramConnection = .failed(error.localizedDescription)
            }
        }
    }

    private func selectWorkingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a working folder for Short Generator"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.workingDirectory = url
            }
        }
    }

    private func selectCustomMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing background music files"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.customMusicDirectory = url
            }
        }
    }

    private func selectMovieLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку с коллекцией фильмов"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.movieLibraryURL = url
            }
        }
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for downloaded YouTube videos and exported clips"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.outputDirectory = url
            }
        }
    }

    @ViewBuilder
    private func pipelineRole(step: String, icon: String, title: LocalizedStringKey,
                              model: String, detail: LocalizedStringKey, status: LocalizedStringKey?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: step + ". ")
                        .font(.callout.weight(.semibold))
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(model).font(.callout).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let status {
                    Text(status).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, format: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var modelStatus: LocalizedStringKey {
        switch modelManager.phase {
        case .idle:                          "Not loaded"
        case .downloading(let fraction, _):  "Downloading \(Int(fraction * 100))%"
        case .loading:                       "Loading…"
        case .ready:                         "Ready"
        case .failed:                        "Failed to load"
        }
    }

    private var directorStatus: LocalizedStringKey {
        switch modelManager.momentFinder.phase {
        case .idle:                        "Loads on first long video"
        case .downloading(let fraction):   "Downloading \(Int(fraction * 100))%"
        case .loading:                     "Loading…"
        case .ready:                       "Ready"
        case .failed:                      "Failed to load"
        }
    }
}

// MARK: - Watermark appearance editor

private struct WatermarkAppearanceEditor: View {

    @Binding var appearance: WatermarkAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Position") {
                Picker("", selection: $appearance.positionRaw) {
                    ForEach(WatermarkAppearance.WatermarkPosition.allCases) { pos in
                        Text(LocalizedStringKey(pos.displayName)).tag(pos.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            row("Animation") {
                Picker("", selection: $appearance.animationRaw) {
                    ForEach(WatermarkAppearance.WatermarkAnimation.allCases) { anim in
                        Text(LocalizedStringKey(anim.displayName)).tag(anim.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if appearance.animationRaw == "typewriter" {
                row("Speed") {
                    Slider(value: $appearance.typingDuration, in: 0.5...3.0, step: 0.25)
                        .controlSize(.small)
                    Text("\(appearance.typingDuration, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }

            if appearance.animationRaw != "static" {
                row("Duration") {
                    Slider(value: $appearance.holdDuration, in: 0.5...8.0, step: 0.25)
                        .controlSize(.small)
                    Text("\(appearance.holdDuration, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }

            row("Opacity") {
                Slider(value: $appearance.opacity, in: 0.3...1.0, step: 0.05)
                    .controlSize(.small)
                Text("\(Int(appearance.opacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            row("Size") {
                Slider(value: $appearance.fontSizeScale, in: 0.015...0.045, step: 0.002)
                    .controlSize(.small)
                Text(LocalizedStringKey(sizeLabel))
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sizeLabel: String {
        if appearance.fontSizeScale < 0.025 { return "Small" }
        if appearance.fontSizeScale < 0.035 { return "Medium" }
        return "Large"
    }
}
