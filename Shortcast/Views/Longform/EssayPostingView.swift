import SwiftUI
import AVKit

struct EssayPostingView: View {
    let result: LongformBuildResult
    let onBack: () -> Void
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?
    @State private var youtubeURL = ""
    @State private var recoveredURLs: [String: String] = [:]
    @State private var browserAuth: BrowserAuthStatus?
    @State private var connectionMessage = ""
    private var release: EssayRelease? { workspace.currentEssayRelease }
    private var telegramURL: String? { LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId) }
    private var publicationMetadata: LongformYouTubeMetadata {
        LongformMetadataGenerator.updatingTelegram(in: result.metadata, channelID: settings.telegramChannelId)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ФИНАЛЬНЫЙ ШАГ").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Text("История готова к выходу.").font(.system(size: 30, weight: .medium, design: .serif))
                    Text(result.metadata.title).font(.system(size: 13)).foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button("К шортсам", systemImage: "arrow.left", action: onBack).disabled(busy)
            }.padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                    releaseOverview
                    if let address = release?.essayYouTubeURL, let url = URL(string: address) {
                        Link("Эссе на YouTube · ссылка сохранена", destination: url).foregroundStyle(StudioTheme.accent)
                    }
                    connectionsCard
                    if let release {
                        Toggle("Публиковать шортсы также в TikTok", isOn: Binding(
                            get: { workspace.currentEssayRelease?.wantsTikTok ?? true },
                            set: { value in
                                run {
                                    guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                    next.includeTikTok = value
                                    try await workspace.saveEssayRelease(next, projectID: id)
                                    status = value ? "TikTok включён в выпуск" : "TikTok отложен. YouTube и Telegram можно опубликовать сейчас."
                                }
                            }))
                            .disabled(busy)
                        if !release.wantsTikTok {
                            Text("TikTok отложен: вход в него не требуется. Позже включите этот переключатель и снова нажмите публикацию — уже отправленные эссе, Telegram-пост и YouTube Shorts пропустятся.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Если эссе уже опубликовано вне этого выпуска") {
                        HStack {
                            TextField("Точная ссылка YouTube", text: $youtubeURL).textFieldStyle(.roundedBorder)
                            Button("Сохранить ссылку") {
                                run {
                                    guard let id = workspace.currentProject?.id else { return }
                                    try await workspace.recordEssayYouTubeURL(youtubeURL, result: result, projectID: id)
                                    status = "Ссылка эссе сохранена"
                                }
                            }
                        }.disabled(busy)
                    }.disabled(busy)
                    Text(release?.wantsTikTok == false
                         ? "Порядок: YouTube-эссе → RichMessage-анонс в Telegram → два YouTube Shorts → закреплённые комментарии. TikTok — позже. Уже подтверждённые отправки пропускаются."
                         : "Порядок: YouTube-эссе → RichMessage-анонс в Telegram → два Shorts на YouTube и TikTok → закреплённые комментарии. Уже подтверждённые отправки пропускаются. Результат неизвестной отправки нужно проверить перед повтором.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let release {
                        ForEach(release.receipts.keys.sorted(), id: \.self) { key in
                            if let receipt = release.receipts[key] {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(targetTitle(key)): \(receipt.message)").font(.caption).textSelection(.enabled)
                                    if let link = receipt.url, let url = URL(string: link) { Link("Открыть публикацию", destination: url).foregroundStyle(StudioTheme.accent) }
                                    if receipt.state == .needsReview {
                                        HStack {
                                            TextField("Ссылка на уже созданную публикацию", text: Binding(
                                                get: { recoveredURLs[key] ?? "" }, set: { recoveredURLs[key] = $0 }))
                                                .textFieldStyle(.roundedBorder)
                                            Button("Подтвердить адрес") {
                                                run {
                                                    guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                                    let platform = key.hasPrefix("telegram.") ? "telegram" : (key.hasSuffix(".tiktok") ? "tiktok" : "youtube")
                                                    guard let address = key.hasSuffix(".comment") ? EssayRelease.youtubeCommentURL(recoveredURLs[key] ?? "") : EssayRelease.publicationURL(recoveredURLs[key] ?? "", platform: platform) else {
                                                        throw EssayReleaseError.invalid("Нужна точная ссылка на опубликованное видео или сообщение.")
                                                    }
                                                    next.receipts[key] = .init(state: .published, url: address, message: "Адрес проверен пользователем")
                                                    if key == "essay.youtube" { next.essayYouTubeURL = address; youtubeURL = address }
                                                    try await workspace.saveEssayRelease(next, projectID: id)
                                                }
                                            }
                                        }.disabled(busy)
                                        Button("Проверил площадку: публикации нет — разрешить повтор") {
                                            run {
                                                guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                                next.receipts[key] = .init(state: .failed, message: "Пользователь проверил отсутствие публикации")
                                                try await workspace.saveEssayRelease(next, projectID: id)
                                            }
                                        }.font(.caption).disabled(busy)
                                    }
                                }.padding(10).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        ForEach(release.shorts) { short in
                            if let url = release.receipts["\(short.id).youtube"]?.url {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(short.id == "short1" ? "Шортс 1" : "Шортс 2"): привязать полное эссе как «Связанное видео» в YouTube Studio").font(.caption.bold())
                                    Text("Эта настройка требует расширенных функций канала. Приложение не отмечает её выполненной по одному факту загрузки.").font(.caption).foregroundStyle(.secondary)
                                    if let address = URL(string: url) { Link("Открыть опубликованный Short", destination: address).foregroundStyle(StudioTheme.accent) }
                                    Toggle("Связанное видео проверено в Studio", isOn: Binding(get: {
                                        workspace.currentEssayRelease?.relatedVideoConfirmed.contains(short.id) == true
                                    }, set: { value in
                                        run {
                                            guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                            if value { next.relatedVideoConfirmed.insert(short.id) } else { next.relatedVideoConfirmed.remove(short.id) }
                                            try await workspace.saveEssayRelease(next, projectID: id)
                                        }
                                    })).disabled(busy)
                                }
                            }
                        }
                        Divider()
                        Text("Telegram · посты выпуска").font(.headline)
                        Text("Обложка выпуска, заголовок, цитатный блок, мысль эссе и кнопка просмотра. Отдельный пост продолжает обсуждение; его можно отправить позже.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach([false, true], id: \.self) { discussion in
                            richPostCard(release, discussion: discussion)
                        }

                    }
                }.padding(28)
            }
            Divider()
            HStack(spacing: 14) {
                if busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.isEmpty ? "Все материалы подставляются автоматически" : status).font(.callout)
                    Text(release?.wantsTikTok == false
                         ? "YouTube · Telegram · YouTube Shorts · закреплённые комментарии · TikTok позже"
                         : "YouTube · Telegram · YouTube Shorts · TikTok · закреплённые комментарии")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(release?.wantsTikTok == false ? "Опубликовать YouTube + Telegram" : "Опубликовать весь выпуск") { run { try await publishRelease() } }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .disabled(busy || release?.hasReadyShorts != true)
            }.padding(18)
        }
        .frame(minWidth: 860, minHeight: 580)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .interactiveDismissDisabled(busy || workspace.isWorkingOnEssayRelease)
        .onAppear { youtubeURL = release?.essayYouTubeURL ?? "" }
    }

    private var releaseOverview: some View {
        HStack(spacing: 20) {
            if let thumbnail = result.thumbnailURL, let image = NSImage(contentsOf: thumbnail) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 190).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Один проект. Все материалы выпуска.").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 18) {
                    Label("Эссе 16:9", systemImage: "checkmark.circle")
                    Label("Два шортса 9:16", systemImage: release?.hasReadyShorts == true ? "checkmark.circle" : "clock")
                    Label("Обложки и тексты", systemImage: "photo.on.rectangle")
                }.font(.system(size: 12)).foregroundStyle(StudioTheme.accent)
                Text("YouTube → Telegram → Shorts. Ссылка на полное эссе добавится в публикации автоматически.")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
                DisclosureGroup("Текст эссе и закреплённый комментарий") {
                    Text(publicationMetadata.description + "\n\n" + publicationMetadata.pinnedComment)
                        .font(.caption).textSelection(.enabled)
                }.font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).studioPanel()
    }

    private var connectionsCard: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Аккаунты и канал").font(.subheadline.bold())
                Spacer()
                if let browserAuth {
                    Label("YouTube", systemImage: browserAuth.youtube ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(browserAuth.youtube ? .green : .secondary)
                    Label("TikTok", systemImage: browserAuth.tiktok ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(browserAuth.tiktok ? .green : .secondary)
                }
            }.font(.caption)
            Text("Telegram: \(settings.telegramChannelId.isEmpty ? "канал не задан" : settings.telegramChannelId) · \(settings.telegramBotToken.trimmed.isEmpty ? "бот не подключён" : "токен сохранён")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Войти в YouTube / TikTok…") {
                    run {
                        browserAuth = try await BrowserAutomationService.shared.openLoginSession()
                        connectionMessage = "Сессия сохранена. При входе выберите нужный канал YouTube и аккаунт TikTok."
                    }
                }
                Button("Проверить подключения") {
                    run {
                        browserAuth = try await BrowserAutomationService.shared.checkAuthStatus()
                        let (_, title) = try await TelegramPublishingService.shared.testConnection(botToken: settings.telegramBotToken, channelId: settings.telegramChannelId)
                        connectionMessage = "Telegram: \(title). Статус YouTube и TikTok показан выше."
                    }
                }
            }
            if !connectionMessage.isEmpty { Text(connectionMessage).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Подключить или изменить Telegram") {
                SecureField("Токен бота Telegram", text: $settings.telegramBotToken).textFieldStyle(.roundedBorder)
                TextField("Канал Telegram", text: $settings.telegramChannelId).textFieldStyle(.roundedBorder)
                Text("Настраивается один раз. Бот должен быть администратором канала с правом публикации. Если адрес канала изменён, пересоздайте шортсы: он присутствует в самом видео.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(busy).padding(14)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func richPostCard(_ release: EssayRelease, discussion: Bool) -> some View {
        let post = try? EssayRichPost.make(result: result, release: release, discussion: discussion)
        let key = discussion ? "telegram.discussion" : "telegram.announcement"
        return VStack(alignment: .leading, spacing: 12) {
            if let cover = result.thumbnailURL, let image = NSImage(contentsOf: cover) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(discussion ? "Пост для обсуждения" : "Анонс эссе").font(.caption).foregroundStyle(.secondary)
            Text(post?.title ?? "«\(result.arc.movieTitle)» — \(discussion ? (release.shorts.last?.angle ?? "продовжуємо розмову") : (result.arc.publicationTitle ?? result.arc.concept.suggestedTitle))").font(.title3.bold())
            Text(post?.quote ?? result.arc.hookText ?? result.arc.concept.tagline).italic().padding(.leading, 12)
            Text(post?.body ?? result.arc.thesis ?? result.arc.concept.philosophicalPremise)
            Text(post?.question ?? release.shorts.last?.question ?? "").bold()
            if let post, let url = URL(string: post.youtubeURL) { Link("Дивитися повне есе ↗", destination: url).buttonStyle(.borderedProminent).tint(StudioTheme.accent) }
            else { Text("Кнопка просмотра появится после сохранения ссылки эссе").font(.caption).foregroundStyle(.secondary) }
            Button(release.receipts[key]?.state == .published ? "Пост опубликован" : "Опубликовать этот RichMessage") {
                run { try await publishPost(discussion: discussion) }
            }.disabled(busy || post == nil || release.receipts[key]?.state == .published)
        }.padding(18).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }

    private func targetTitle(_ key: String) -> String {
        if key.hasSuffix(".comment") {
            return key.hasPrefix("essay.") ? "Эссе · Закреплённый комментарий" : "Шортс \(key.hasPrefix("short1.") ? "1" : "2") · Закреплённый комментарий"
        }
        if key == "essay.youtube" { return "Эссе · YouTube" }
        if key == "telegram.announcement" { return "Telegram · Анонс" }
        if key == "telegram.discussion" { return "Telegram · Обсуждение" }
        let number = key.hasPrefix("short1.") ? "1" : "2"
        return "Шортс \(number) · " + (key.hasSuffix(".youtube") ? "YouTube Shorts" : "TikTok")
    }

    private func publishRelease() async throws {
        guard let release, let id = workspace.currentProject?.id else { return }
        workspace.isWorkingOnEssayRelease = true; defer { workspace.isWorkingOnEssayRelease = false }
        _ = try await EssayReleasePublisher().publish(release, result: result,
            botToken: settings.telegramBotToken, channelId: settings.telegramChannelId,
            progress: { status = $0 }, checkpoint: { try await workspace.saveEssayRelease($0, projectID: id) })
        youtubeURL = workspace.currentEssayRelease?.essayYouTubeURL ?? ""
        status = release.wantsTikTok
            ? "Отправки завершены. Проверьте привязку связанных видео в YouTube Studio."
            : "YouTube и Telegram опубликованы, комментарии закреплены. TikTok отложен."
    }

    private func publishPost(discussion: Bool) async throws {
        guard !settings.telegramBotToken.trimmed.isEmpty, !settings.telegramChannelId.trimmed.isEmpty else {
            throw EssayReleaseError.invalid("Укажите токен Telegram и канал в Настройках.")
        }
        guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
        let key = discussion ? "telegram.discussion" : "telegram.announcement"
        try EssayReleasePublisher.requireRetryAllowed(next.receipts[key])
        let post = try EssayRichPost.make(result: result, release: next, discussion: discussion)
        next.receipts[key] = .init(state: .sending, message: "Отправка RichMessage")
        try await workspace.saveEssayRelease(next, projectID: id)
        do {
            let messageID = try await TelegramPublishingService.shared.publishRichPost(post, botToken: settings.telegramBotToken, channelId: settings.telegramChannelId)
            next.receipts[key] = .init(state: .published, url: telegramURL.map { $0 + "/\(messageID)" }, message: "Сообщение #\(messageID)")
            try await workspace.saveEssayRelease(next, projectID: id)
        } catch {
            let message = error.localizedDescription.replacingOccurrences(of: settings.telegramBotToken, with: "[скрыто]")
            next.receipts[key] = .init(state: .needsReview, message: message)
            try await workspace.saveEssayRelease(next, projectID: id); throw EssayReleaseError.invalid(message)
        }
    }
}
