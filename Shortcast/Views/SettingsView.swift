import SwiftUI
import AppKit
import QuartzCore

/// Folders, Director model and publication accounts for essay releases.
struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss


    private let cleanupService: any ProjectCleanupServiceProtocol = ProjectCleanupService.shared
    @State private var showSupportEditor = false
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

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("Настройки студии")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(L10n.tr("Готово")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20).background(StudioTheme.panel)
            Divider()
            Form {
            Section(L10n.tr("Язык интерфейса")) {
                @Bindable var localization = InterfaceLocalization.shared
                Picker(L10n.tr("Язык приложения"), selection: $localization.language) {
                    ForEach(AppInterfaceLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Text(L10n.tr("Язык интерфейса не меняет озвучку, субтитры и тексты выпуска."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("Аккаунты публикации")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("Эссе и шортсы публикуются в ваши аккаунты YouTube и TikTok. Войдите один раз в открывшемся окне браузера."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            openBrowserLogin()
                        } label: {
                            Label(L10n.tr("Войти в аккаунты"), systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(StudioPrimaryButtonStyle())
                        .tint(StudioTheme.accent)
                        .disabled(isOpeningBrowserLogin)

                        Button(L10n.tr("Проверить статус")) {
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
                            browserPlatformBadge("YouTube", ok: status.youtube)
                        }
                        .padding(.vertical, 4)
                    }

                    if let err = browserAuthError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text(L10n.tr("Профиль и сохранённые сессии хранятся локально: ~/Library/Application Support/Shortcast/BrowserProfile"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section(L10n.tr("Telegram выпуска")) {
                SecureField(L10n.tr("Токен бота Telegram"), text: $settings.telegramBotToken)
                TextField(L10n.tr("Канал (username или ID)"), text: $settings.telegramChannelId)


                Text(L10n.tr("Добавьте бота администратором своего канала с правом публикации. Тексты постов формируются из текущего выпуска."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(L10n.tr("Проверить бота"), action: testTelegramConnection)
                        .disabled(settings.telegramBotToken.trimmed.isEmpty || telegramConnection == .checking)
                    telegramConnectionStatus
                    Spacer()
                    Link(L10n.tr("Создать бота (@BotFather) ↗"), destination: URL(string: "https://t.me/BotFather")!)
                        .foregroundStyle(StudioTheme.accent)
                }
            }

            Section(L10n.tr("Поддержка канала")) {
                TextField(L10n.tr("Ссылка Donatello"), text: $settings.donatelloURL)
                Button(L10n.tr("Благодарности донатерам…"), systemImage: "heart.text.square") { showSupportEditor = true }
                Text(L10n.tr("Настройки используются в новых эссе. Финал готового эссе меняется в его оформлении публикации."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("TMDB") {
                SecureField("TMDB API key", text: $settings.tmdbAPIKey)
                Text(L10n.tr("Данные о фильме: название, год, актёры и постер. Ключ можно получить на themoviedb.org."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("Рабочая папка")) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(settings.workingDirectoryLabel)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L10n.tr("Выбрать…")) { selectWorkingFolder() }
                        .buttonStyle(.borderless)
                    Button { settings.workingDirectory = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.workingDirectory == nil)
                }
                Text(L10n.tr("Здесь хранятся исходники проекта и материалы обработки."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("Папка экспорта")) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(settings.outputDirectoryLabel)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(L10n.tr("Выбрать…")) { selectOutputFolder() }
                        .buttonStyle(.borderless)
                    Button { settings.outputDirectory = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.outputDirectory == nil)
                }
                Text(L10n.tr("Готовые эссе, шортсы и обложки сохраняются в папке экспорта."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("Хранилище")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("Очистка временных файлов"))
                                .font(.callout.weight(.medium))
                            Text(L10n.tr("Удаляет только временные файлы приложения. Фильмы, проекты и готовые выпуски сохраняются."))
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
                                Text(L10n.tr("Очистить"))
                            }
                        }
                        .disabled(isCleaning || workspace.isBusy)
                    }

                    HStack(spacing: 8) {
                        if let bytes = removableSizeBytes {
                            Text(L10n.tr("Можно освободить: **%1$@**", String(describing: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isCalculatingSize {
                            ProgressView().controlSize(.mini)
                            Text(L10n.tr("Подсчитываем временные файлы…"))
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
                    L10n.tr("Очистить временные файлы?"),
                    isPresented: $showCleanupConfirm,
                    titleVisibility: .visible
                ) {
                    Button(L10n.tr("Удалить временные файлы"), role: .destructive) {
                        runDeepClean()
                    }
                    Button(L10n.tr("Отмена"), role: .cancel) {}
                } message: {
                    Text(L10n.tr("Удалятся временные файлы и кэш компиляции. Исходные фильмы, сохранённые проекты, модели и экспортированные видео сохраняются."))
                }
            }

            Section(L10n.tr("Модель режиссёра")) {
                Picker(L10n.tr("Модель"), selection: $settings.copywriterModel) {
                    ForEach(AppSettings.CopywriterModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(L10n.tr("Выбирает тему эссе, сцены и два шортса. Загружается по необходимости."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("Транскрипция")) {
                TextField(L10n.tr("Язык озвучки"), text: $settings.languageOverride, prompt: Text("uk"))
                Text(L10n.tr("Сначала используются субтитры рядом с фильмом. Если их нет — локальная транскрипция WhisperKit."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("Обработка эссе")) {
                Toggle(L10n.tr("Логотип канала"), isOn: $settings.channelLogoWatermarkEnabled)
            }
            Section(L10n.tr("Этот Mac")) {
                LabeledContent(L10n.tr("Память"), value: "\(modelManager.systemRAMGB) GB")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(StudioTheme.background)
        }
        .frame(width: 580, height: 740)
        .sheet(isPresented: $showSupportEditor) {
            EssaySupportEditor(support: settings.essaySupport,
                ctaText: "Обговорімо тему цього есе в Telegram.", theme: "КАДР & СЕНС", defaultsOnly: true) { support in
                settings.donatelloURL = support.donatelloURL
                settings.donorCreditsEnabled = support.creditsEnabled
                settings.donorNicknamesText = support.nicknames.joined(separator: "\n")
            }
        }
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .task(id: settings.workingDirectory) { await refreshRemovableSize() }
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
                telegramConnection = .ok(L10n.tr("Бот %1$@ подключен к «%2$@»", String(describing: botUsername), String(describing: channelTitle)))
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
        panel.message = L10n.tr("Выберите рабочую папку студии")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.workingDirectory = url
            }
        }
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("Выберите папку готовых эссе и шортсов")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.outputDirectory = url
            }
        }
    }

}

/// Shared editor for channel defaults and the current essay's saved finale.
struct EssaySupportEditor: View {
    struct NicknameRow: Identifiable { let id = UUID(); var text: String }
    let original: EssaySupport
    let ctaText: String
    let theme: String
    var defaultsOnly = false
    let onSave: (EssaySupport) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var rows: [NicknameRow]
    @State private var url: String
    @State private var showList = false
    @State private var listText = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focusedNickname: UUID?

    init(support: EssaySupport, ctaText: String, theme: String, defaultsOnly: Bool = false,
         onSave: @escaping (EssaySupport) async throws -> Void) {
        original = support; self.ctaText = ctaText; self.theme = theme
        self.defaultsOnly = defaultsOnly; self.onSave = onSave
        _enabled = State(initialValue: support.creditsEnabled)
        _rows = State(initialValue: support.nicknames.map { NicknameRow(text: $0) })
        _url = State(initialValue: support.donatelloURL)
    }
    private var support: EssaySupport {
        EssaySupport(donatelloURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            creditsEnabled: enabled, nicknames: EssaySupport.names(from: rows.map(\.text).joined(separator: "\n")))
    }
    private var changesVideo: Bool {
        !defaultsOnly && (original.showsCredits != support.showsCredits
            || (support.showsCredits && original.nicknames != support.nicknames))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Поддержка и благодарности")).font(.title2.bold())
                    Text(defaultsOnly ? L10n.tr("Настройки для новых эссе") : L10n.tr("Финальный экран этого эссе"))
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button(L10n.tr("Закрыть")) { dismiss() }.disabled(saving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            TextField(L10n.tr("Ссылка Donatello"), text: $url).textFieldStyle(.roundedBorder)
            Text(L10n.tr("Ссылка добавляется в описание YouTube. Ники появляются в видео только при включённых благодарностях."))
                .font(.caption).foregroundStyle(StudioTheme.muted)
            Toggle(L10n.tr("Благодарить донатеров в конце эссе"), isOn: $enabled).toggleStyle(.switch)
                .onChange(of: enabled) { _, value in if value && rows.isEmpty { addNickname() } }
            if enabled {
                HStack {
                    Text(L10n.tr("Ники · %1$@ / 24", String(describing: support.nicknames.count))).font(.headline)
                    Spacer()
                    Button(L10n.tr("Ввести списком"), systemImage: "list.bullet") { showList = true }
                    Button(L10n.tr("Добавить ник"), systemImage: "plus") { addNickname() }.disabled(rows.count >= 24)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($rows) { $row in
                            HStack {
                                TextField(L10n.tr("Ник донатера"), text: $row.text)
                                    .textFieldStyle(.roundedBorder).focused($focusedNickname, equals: row.id)
                                Button { rows.removeAll { $0.id == row.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.plain).help(L10n.tr("Убрать ник"))
                            }
                        }
                    }.padding(2)
                }.frame(maxHeight: 150)
                Text(L10n.tr("Без сумм и личных данных: только введённые ники. Повторы и пустые строки пропускаются."))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            if let issue = support.validationIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.yellow)
            }
            if let error { Text(L10n.tr(error)).font(.caption).foregroundStyle(.red) }
            if support.validationIssue == nil {
                DonorCreditsPreview(support: support, ctaText: ctaText, theme: theme)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(L10n.tr("Предпросмотр финала · %1$@ с. Благодарности идут одновременно с призывом к обсуждению.", String(format: "%.1f", support.finaleDuration(text: ctaText))))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
                }
            }
            HStack {
                Text(defaultsOnly ? L10n.tr("Настройки будут использованы в новых эссе.") : changesVideo ? L10n.tr("Сохранение пересоберёт видео с новым финалом.") : L10n.tr("Ссылка обновится без пересборки видео."))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
                Spacer()
                Button(saving ? L10n.tr("Сохраняю…") : changesVideo ? L10n.tr("Сохранить и пересобрать") : L10n.tr("Сохранить")) {
                    saving = true; error = nil
                    Task { @MainActor in
                        defer { saving = false }
                        do { try await onSave(support); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(StudioPrimaryButtonStyle()).disabled(saving || support.validationIssue != nil)
            }
        }.padding(24).frame(width: 800, height: enabled ? 850 : 730).studioSurface()
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $showList) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tr("Добавить ники списком")).font(.title2.bold())
                    Text(L10n.tr("Разделяйте ники запятой или переносом строки.")).foregroundStyle(StudioTheme.muted)
                    TextEditor(text: $listText).font(.system(.body, design: .monospaced))
                        .frame(height: 180).scrollContentBackground(.hidden).studioPanel(padding: 10)
                    HStack {
                        Button(L10n.tr("Отмена")) { showList = false }
                        Spacer()
                        Button(L10n.tr("Добавить в список")) {
                            let names = EssaySupport.names(from: (rows.map(\.text) + [listText.replacingOccurrences(of: ",", with: "\n")]).joined(separator: "\n"))
                            rows = names.map { NicknameRow(text: $0) }
                            listText = ""; showList = false
                        }.buttonStyle(StudioPrimaryButtonStyle()).disabled(listText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 600).studioSurface()
            }
    }
    private func addNickname() {
        let row = NicknameRow(text: "")
        rows.append(row); focusedNickname = row.id
    }
}

private struct DonorCreditsPreview: NSViewRepresentable {
    let support: EssaySupport
    let ctaText: String
    let theme: String
    func makeNSView(context: Context) -> DonorCreditsPreviewHost { DonorCreditsPreviewHost() }
    func updateNSView(_ view: DonorCreditsPreviewHost, context: Context) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let card = DonorCreditsRenderer.makeLayer(support: support, ctaText: ctaText, theme: theme,
            start: 0, duration: support.finaleDuration(text: ctaText), loops: true)
        card.beginTime = CACurrentMediaTime()
        view.layer?.sublayers = [card]
        view.needsLayout = true
    }
}

private final class DonorCreditsPreviewHost: NSView {
    override func layout() {
        super.layout()
        layer?.sublayerTransform = CATransform3DMakeScale(bounds.width / 1920, bounds.height / 1080, 1)
    }
}
