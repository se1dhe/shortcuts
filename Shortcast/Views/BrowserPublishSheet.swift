import SwiftUI

/// Modal sheet for publishing a generated short directly through local browser automation.
/// Adheres to Single Responsibility Principle (SRP).
struct BrowserPublishSheet: View {
    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlatforms: Set<SocialPlatform> = [.tiktok, .instagram, .youtube]
    @State private var postToTelegram: Bool = true
    @State private var authStatus: BrowserAuthStatus = BrowserAuthStatus()
    @State private var isCheckingAuth: Bool = false
    @State private var isLoggingIn: Bool = false
    @State private var isUploading: Bool = false

    @State private var logs: [String] = []
    @State private var platformStatus: [SocialPlatform: UploadState] = [:]
    @State private var telegramStatus: UploadState = .idle
    @State private var overallError: String?

    private enum UploadState: Equatable {
        case idle
        case inProgress(String)
        case captcha(String)
        case success(String, String?)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Автопубликация через браузер", systemImage: "globe.badge.chevron.backward")
                    .font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Educational Banner
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Публикация без API-ключей")
                                .font(.subheadline.weight(.semibold))
                            Text("Использует ваш локальный Google Chrome. Данные авторизации и cookies хранятся на вашем Mac, загрузка выглядит как обычные действия человека.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 10))

                    // Account Connection Status Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Подключенные аккаунты:")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if isCheckingAuth || isLoggingIn {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Проверить") {
                                    Task { await refreshAuth() }
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack(spacing: 12) {
                            accountBadge(name: "TikTok", isConnected: authStatus.tiktok, icon: "music.note")
                            accountBadge(name: "Instagram", isConnected: authStatus.instagram, icon: "camera")
                            accountBadge(name: "YouTube", isConnected: authStatus.youtube, icon: "play.rectangle.fill")
                        }

                        Button {
                            Task { await openLoginWindow() }
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.plus")
                                Text("Войти в аккаунты (Открыть Google Chrome)…")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.regular)
                        .disabled(isUploading || isLoggingIn)
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

                    // Platforms Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Куда загрузить этот шортс:")
                            .font(.subheadline.weight(.medium))

                        HStack(spacing: 10) {
                            ForEach([SocialPlatform.tiktok, .instagram, .youtube]) { platform in
                                let isSelected = selectedPlatforms.contains(platform)
                                let isAuthed = (platform == .tiktok && authStatus.tiktok) ||
                                               (platform == .instagram && authStatus.instagram) ||
                                               (platform == .youtube && authStatus.youtube)
                                Button {
                                    if isSelected {
                                        selectedPlatforms.remove(platform)
                                    } else {
                                        selectedPlatforms.insert(platform)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                        Text(platform.displayName)
                                            .font(.callout.weight(.medium))
                                        if !isAuthed && !isCheckingAuth {
                                            Text("(не в сети)")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .disabled(isUploading)
                            }
                        }

                        Toggle(isOn: $postToTelegram) {
                            HStack(spacing: 6) {
                                Image(systemName: "paperplane.fill")
                                    .foregroundStyle(Color(hex: "2AABEE"))
                                Text("Опубликовать карточку фильма в Telegram (@telonyx_club)")
                                    .font(.callout.weight(.medium))
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.top, 4)
                        .disabled(isUploading)
                    }

                    // Progress / Status Rows
                    if isUploading || !platformStatus.isEmpty || (postToTelegram && telegramStatus != .idle) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Статус выгрузки:")
                                .font(.subheadline.weight(.medium))

                            ForEach(SocialPlatform.allCases.filter { selectedPlatforms.contains($0) }) { platform in
                                platformStatusRow(platform: platform, state: platformStatus[platform] ?? .idle)
                            }

                            if postToTelegram {
                                telegramStatusRow(state: telegramStatus)
                            }
                        }
                        .padding(12)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    }

                    // Live Log Box
                    if !logs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Журнал автоматизации:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(logs.suffix(12).enumerated()), id: \.offset) { _, log in
                                        Text(log)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(8)
                            }
                            .frame(height: 90)
                            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let err = overallError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer actions
            HStack {
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isUploading)

                Spacer()

                Button {
                    Task { await startBrowserPublish() }
                } label: {
                    HStack(spacing: 6) {
                        if isUploading {
                            ProgressView().controlSize(.small)
                            Text("Публикация…")
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Опубликовать в 1 клик")
                        }
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isUploading || (selectedPlatforms.isEmpty && !postToTelegram) || (clip.clipJob == nil && !selectedPlatforms.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .task {
            await refreshAuth()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func accountBadge(name: String, isConnected: Bool, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(name)
                .font(.caption.weight(.medium))
            Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption2)
                .foregroundStyle(isConnected ? Color.green : Color.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isConnected ? Color.green.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func platformStatusRow(platform: SocialPlatform, state: UploadState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: platform.symbolName)
                .foregroundStyle(Color(hex: platform.tintHex))
                .frame(width: 20)

            Text(platform.displayName)
                .font(.callout.weight(.medium))

            Spacer()

            switch state {
            case .idle:
                Text("В очереди").font(.caption).foregroundStyle(.secondary)
            case .inProgress(let msg):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(msg).font(.caption).foregroundStyle(.tint)
                }
            case .captcha(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.yellow)
                    Text(msg).font(.caption).foregroundStyle(.yellow)
                }
            case .success(let msg, _):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(msg).font(.caption).foregroundStyle(.green)
                }
            case .failed(let err):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func telegramStatusRow(state: UploadState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperplane.fill")
                .foregroundStyle(Color(hex: "2AABEE"))
                .frame(width: 20)

            Text("Telegram (@telonyx_club)")
                .font(.callout.weight(.medium))

            Spacer()

            switch state {
            case .idle:
                Text("В очереди").font(.caption).foregroundStyle(.secondary)
            case .inProgress(let msg):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(msg).font(.caption).foregroundStyle(.tint)
                }
            case .captcha(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(msg).font(.caption).foregroundStyle(.yellow)
                }
            case .success(let msg, _):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(msg).font(.caption).foregroundStyle(.green)
                }
            case .failed(let err):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshAuth() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }
        do {
            authStatus = try await BrowserAutomationService.shared.checkAuthStatus()
            var authed: Set<SocialPlatform> = []
            if authStatus.instagram { authed.insert(.instagram) }
            if authStatus.youtube { authed.insert(.youtube) }
            if authStatus.tiktok { authed.insert(.tiktok) }
            if !authed.isEmpty {
                selectedPlatforms = authed
            }
        } catch {
            logs.append("Проверка сессии: \(error.localizedDescription)")
        }
    }

    private func openLoginWindow() async {
        isLoggingIn = true
        logs.append("Открытие браузера для авторизации...")
        defer { isLoggingIn = false }
        do {
            authStatus = try await BrowserAutomationService.shared.openLoginSession()
            logs.append("Авторизация завершена. Статус сохранён.")
            var authed: Set<SocialPlatform> = []
            if authStatus.instagram { authed.insert(.instagram) }
            if authStatus.youtube { authed.insert(.youtube) }
            if authStatus.tiktok { authed.insert(.tiktok) }
            if !authed.isEmpty {
                selectedPlatforms = authed
            }
        } catch {
            logs.append("Ошибка входа: \(error.localizedDescription)")
        }
    }

    private func startBrowserPublish() async {
        isUploading = true
        overallError = nil
        logs.removeAll()

        for p in selectedPlatforms {
            platformStatus[p] = .inProgress("Подготовка...")
        }
        if postToTelegram {
            telegramStatus = .inProgress("Подготовка...")
        }

        // 1. Publish to Telegram independently
        if postToTelegram {
            if !settings.telegramBotToken.trimmed.isEmpty {
                logs.append("📢 [Telegram] Отправка поста в канал @telonyx_club...")
                telegramStatus = .inProgress("Отправка в канал...")
                do {
                    let msgId = try await TelegramPublishingService.shared.publishMoviePost(
                        clip: clip,
                        botToken: settings.telegramBotToken,
                        channelId: settings.telegramChannelId
                    )
                    telegramStatus = .success("Опубликовано (#\(msgId))", nil)
                    logs.append("✅ [Telegram] Карточка успешно опубликована в канале (сообщение #\(msgId))")
                } catch {
                    telegramStatus = .failed(error.localizedDescription)
                    logs.append("⚠️ [Telegram] Ошибка публикации: \(error.localizedDescription)")
                }
            } else {
                telegramStatus = .failed("Токен бота не указан")
                logs.append("ℹ️ [Telegram] Токен бота не указан в Настройках — отправка пропущена.")
            }
        }

        // 2. Video platform publication via browser automation
        if !selectedPlatforms.isEmpty {
            do {
                logs.append("Рендеринг финального видео (Anti-Copyright Shield)...")
                let (renderedURL, isTemp) = try await clip.makeRenderedFile()
                defer { if isTemp { try? FileManager.default.removeItem(at: renderedURL) } }

                let primaryVariant = clip.variants.first ?? PostVariant(
                    platform: .tiktok,
                    hook: clip.displayTitle,
                    summary: clip.detectedMovieTitle,
                    hashtags: ["кинонавечер", "фильмы", "кино"],
                    pinnedComment: ""
                )

                var platformContentMap: [String: PlatformUploadContent] = [:]
                for p in selectedPlatforms {
                    let variant = clip.variants.first(where: { $0.platform == p }) ?? primaryVariant
                    let title: String = {
                        if p == .youtube {
                            return variant.hook.contains("#Shorts") ? variant.hook : "\(variant.hook) #Shorts"
                        }
                        return variant.hook
                    }()
                    platformContentMap[p.rawValue] = PlatformUploadContent(
                        title: title,
                        caption: variant.summary,
                        hashtags: variant.hashtags
                    )
                }

                let job = BrowserUploadJob(
                    videoURL: renderedURL,
                    platforms: selectedPlatforms,
                    platformContent: platformContentMap,
                    title: clip.displayTitle,
                    caption: primaryVariant.summary,
                    hashtags: primaryVariant.hashtags,
                    isPublic: true,
                    headless: true
                )

                logs.append("Запуск браузерной выгрузки...")

                let stream = BrowserAutomationService.shared.publish(job: job)

                for try await event in stream {
                    switch event {
                    case .progress(let platform, let message):
                        logs.append(message)
                        if let platStr = platform, let sp = SocialPlatform(rawValue: platStr) {
                            platformStatus[sp] = .inProgress(message)
                        }

                    case .captchaDetected(let platform, let message):
                        logs.append("⚠️ [Капча] \(message)")
                        if let sp = SocialPlatform(rawValue: platform) {
                            platformStatus[sp] = .captcha(message)
                        }

                    case .success(let platform, let message, let url):
                        logs.append("✅ [\(platform)] \(message)")
                        if let sp = SocialPlatform(rawValue: platform) {
                            platformStatus[sp] = .success(message, url)
                        }

                    case .failure(let platform, let message):
                        if let platform {
                            logs.append("❌ [\(platform)] \(message)")
                            if let sp = SocialPlatform(rawValue: platform) {
                                platformStatus[sp] = .failed(message)
                            }
                        } else {
                            logs.append("❌ \(message)")
                        }

                    case .finished:
                        logs.append("Выгрузка в видеоплатформы завершена.")
                    }
                }
            } catch {
                overallError = error.localizedDescription
                logs.append("Ошибка видеоплатформ: \(error.localizedDescription)")
            }
        }

        isUploading = false
    }
}
