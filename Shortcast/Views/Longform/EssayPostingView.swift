import SwiftUI
import AVKit

struct EssayPostingView: View {
    let result: LongformBuildResult
    let onBack: () -> Void
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(AppSettings.self) private var settings
    @State private var busy = false
    @State private var showManualTikTok = false
    @State private var copiedTikTokField: String?
    @State private var postingStarted: Date?
    @State private var postingFinished: Date?
    @State private var stepStarted = Date()
    @State private var activeKey: String?
    @State private var journal: [(Date, String)] = []
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
                    Text(L10n.tr("ФИНАЛЬНЫЙ ШАГ")).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Text(L10n.tr("Публикация выпуска")).font(.system(size: 26, weight: .medium, design: .serif))
                    Text(result.metadata.title).font(.system(size: 13)).foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button(L10n.tr("К шортсам"), systemImage: "arrow.left", action: onBack).disabled(busy)
            }.padding(20)
            Divider()
            HStack(spacing: 8) {
                postingTab(L10n.tr("Очередь выпуска"), systemImage: "list.number", manual: false)
                postingTab(L10n.tr("TikTok · вручную"), systemImage: "music.note", manual: true)
                Spacer()
                Text(showManualTikTok ? L10n.tr("Тексты и файлы для самостоятельной публикации") : L10n.tr("Статусы, ссылки и проверка площадок"))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error { Label(L10n.tr(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                    if showManualTikTok { manualTikTokWorkspace } else {
                    publicationRoadmap
                    DisclosureGroup(L10n.tr("Материалы выпуска и тексты")) { releaseOverview }
                    if let address = release?.essayYouTubeURL, let url = URL(string: address) {
                        Link(L10n.tr("Эссе на YouTube · ссылка сохранена"), destination: url).foregroundStyle(StudioTheme.accent)
                    }
                    DisclosureGroup(L10n.tr("Начать публикацию заново")) {
                        Text(L10n.tr("Если старые публикации удалены: сбросьте локальные статусы и ссылки. Видео, монтаж и субтитры сохранятся; прежние квитанции попадут в publication-history рядом с экспортом."))
                            .font(.caption).foregroundStyle(StudioTheme.muted)
                        Button(L10n.tr("Сбросить все статусы на «Не опубликовано»")) {
                            run {
                                try await workspace.resetEssayPublicationState()
                                youtubeURL = ""; recoveredURLs = [:]; journal = []; activeKey = nil; postingStarted = nil; postingFinished = nil
                                status = L10n.tr("Все статусы сброшены. Можно начать с публикации эссе.")
                            }
                        }.disabled(busy)
                    }
                    connectionsCard
                    if let release {
                        Toggle(L10n.tr("Публиковать шортсы также в TikTok"), isOn: Binding(
                            get: { workspace.currentEssayRelease?.wantsTikTok ?? true },
                            set: { value in
                                run {
                                    guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                    next.includeTikTok = value
                                    try await workspace.saveEssayRelease(next, projectID: id)
                                    status = value ? L10n.tr("TikTok включён в выпуск") : L10n.tr("TikTok отложен. YouTube и Telegram можно опубликовать сейчас.")
                                }
                            }))
                            .disabled(busy)
                        if !release.wantsTikTok {
                            Text(L10n.tr("TikTok отложен: вход в него не требуется. Позже включите этот переключатель и снова нажмите публикацию — уже отправленные эссе, Telegram-пост и YouTube Shorts пропустятся."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup(L10n.tr("Если эссе уже опубликовано вне этого выпуска")) {
                        HStack {
                            TextField(L10n.tr("Точная ссылка YouTube"), text: $youtubeURL).textFieldStyle(.roundedBorder)
                            Button(L10n.tr("Сохранить ссылку")) {
                                run {
                                    guard let id = workspace.currentProject?.id else { return }
                                    try await workspace.recordEssayYouTubeURL(youtubeURL, result: result, projectID: id)
                                    status = L10n.tr("Ссылка эссе сохранена")
                                }
                            }
                        }.disabled(busy)
                    }.disabled(busy)
                    if let release {
                        ForEach(deliveryKeys.filter { release.receipts[$0] != nil && release.receipts[$0]?.state != .published }, id: \.self) { key in
                            if let receipt = release.receipts[key] {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(targetTitle(key)): \(receipt.message)").font(.caption).textSelection(.enabled)
                                    if let link = receipt.url, let url = URL(string: link) { Link(L10n.tr("Открыть публикацию"), destination: url).foregroundStyle(StudioTheme.accent) }
                                    if receipt.state == .needsReview {
                                        HStack {
                                            TextField(L10n.tr("Ссылка на уже созданную публикацию"), text: Binding(
                                                get: { recoveredURLs[key] ?? "" }, set: { recoveredURLs[key] = $0 }))
                                                .textFieldStyle(.roundedBorder)
                                            Button(L10n.tr("Подтвердить адрес")) {
                                                run {
                                                    guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                                    let platform = key.hasPrefix("telegram.") ? "telegram" : (key.hasSuffix(".tiktok") ? "tiktok" : "youtube")
                                                    guard let address = key.hasSuffix(".comment") ? EssayRelease.youtubeCommentURL(recoveredURLs[key] ?? "") : EssayRelease.publicationURL(recoveredURLs[key] ?? "", platform: platform) else {
                                                        throw EssayReleaseError.invalid(L10n.tr("Нужна точная ссылка на опубликованное видео или сообщение."))
                                                    }
                                                    next.receipts[key] = .init(state: .published, url: address, message: L10n.tr("Адрес проверен пользователем"))
                                                    if key == "essay.youtube" { next.essayYouTubeURL = address; youtubeURL = address }
                                                    try await workspace.saveEssayRelease(next, projectID: id)
                                                }
                                            }
                                        }.disabled(busy)
                                        Button(L10n.tr("Проверил площадку: публикации нет — разрешить повтор")) {
                                            run {
                                                guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                                                next.receipts[key] = .init(state: .failed, message: L10n.tr("Пользователь проверил отсутствие публикации"))
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
                                    Text(L10n.tr("%1$@: привязать полное эссе как «Связанное видео» в YouTube Studio", String(describing: short.isMontage ? L10n.tr("Эдит 3") : (short.id == "short1" ? L10n.tr("Шортс 1") : L10n.tr("Шортс 2"))))).font(.caption.bold())
                                    Text(L10n.tr("Эта настройка требует расширенных функций канала. Приложение не отмечает её выполненной по одному факту загрузки.")).font(.caption).foregroundStyle(.secondary)
                                    if let address = URL(string: url) { Link(L10n.tr("Открыть опубликованный Short"), destination: address).foregroundStyle(StudioTheme.accent) }
                                    Toggle(L10n.tr("Связанное видео проверено в Studio"), isOn: Binding(get: {
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
                        Text(L10n.tr("Telegram · посты выпуска")).font(.headline)
                        Text(L10n.tr("Обложка выпуска, заголовок, цитатный блок, мысль эссе и кнопка просмотра. Отдельный пост продолжает обсуждение; его можно отправить позже."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach([false, true], id: \.self) { discussion in
                            richPostCard(release, discussion: discussion)
                        }

                    }
                    }
                }.padding(28)
            }
            Divider()
            if showManualTikTok {
                Label(L10n.tr("Публикуйте ролики самостоятельно. Копирование текстов и открытие файлов ничего не отправляют в TikTok."), systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(StudioTheme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            } else {
            HStack(spacing: 14) {
                if busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.isEmpty ? L10n.tr("Все материалы подставляются автоматически") : status).font(.callout).lineLimit(2)
                    Text(release?.wantsTikTok == false
                         ? L10n.tr("YouTube · Telegram · YouTube Shorts · закреплённые комментарии · TikTok позже")
                         : L10n.tr("YouTube · Telegram · YouTube Shorts · TikTok · закреплённые комментарии"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(release?.isPublished == true ? L10n.tr("Выпуск опубликован") : busy ? (workspace.isWorkingOnEssayRelease ? L10n.tr("Идёт публикация…") : L10n.tr("Подождите…")) : release?.receipts.isEmpty == false ? L10n.tr("Продолжить публикацию") : L10n.tr("Опубликовать выпуск")) { run { try await publishRelease() } }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .disabled(busy || release?.hasReadyShorts != true || release?.isPublished == true)
            }.padding(18)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .interactiveDismissDisabled(busy || workspace.isWorkingOnEssayRelease)
        .onAppear {
            youtubeURL = release?.essayYouTubeURL ?? ""
            showManualTikTok = release?.isPublished == true && release?.wantsTikTok == false
        }
    }

    private func postingTab(_ title: String, systemImage: String, manual: Bool) -> some View {
        Button { showManualTikTok = manual } label: {
            Label(title, systemImage: systemImage).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 15).padding(.vertical, 10)
                .foregroundStyle(showManualTikTok == manual ? StudioTheme.accent : StudioTheme.muted)
                .background(showManualTikTok == manual ? StudioTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(busy)
    }

    private var manualTikTokWorkspace: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("TIKTOK / РУЧНАЯ ПУБЛИКАЦИЯ")).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                Text(L10n.tr("Ваши ролики. Готовые тексты.")).font(.system(size: 29, weight: .medium, design: .serif))
                Text(L10n.tr("Откройте MP4, загрузите его в TikTok и скопируйте подготовленный текст. Материалы остаются здесь после публикации эссе, YouTube Shorts и Telegram-поста."))
                    .font(.callout).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let release, !release.shorts.isEmpty {
                ForEach(Array(release.shorts.enumerated()), id: \.element.id) { index, short in
                    manualTikTokCard(short, index: index, release: release)
                }
            } else {
                Label(L10n.tr("Сначала подготовьте шортсы на шаге «Шортсы»."), systemImage: "film.stack")
                    .foregroundStyle(StudioTheme.muted).studioPanel()
            }
        }
    }

    private func manualTikTokCard(_ short: EssayShort, index: Int, release: EssayRelease) -> some View {
        let post = short.post(platform: .tiktok, movieTitle: result.arc.movieTitle, release: release, telegramURL: telegramURL)
        let tags = post.hashtags.map { "#" + $0 }.joined(separator: " ")
        let fullText = post.hook + "\n\n" + post.summary + "\n\n" + tags
        let key = short.id + ".tiktok"
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                if let url = short.coverURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 80, height: 142)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("ШОРТС %1$@ / 9:16 / %2$@ С", String(describing: index + 1), String(describing: Int(short.duration.rounded()))))
                        .font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(StudioTheme.accent)
                    Text(short.title).font(.system(size: 23, weight: .medium, design: .serif))
                    HStack(spacing: 12) {
                        if let url = short.outputURL {
                            Button(L10n.tr("Видео в Finder"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button(L10n.tr("Открыть MP4"), systemImage: "play.rectangle") { NSWorkspace.shared.open(url) }
                        }
                        if let url = short.coverURL {
                            Button(L10n.tr("Обложка"), systemImage: "photo") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }.font(.caption)
                    Button { copyTikTok(fullText, key: key + ".all") } label: {
                        Label(copiedTikTokField == key + ".all" ? L10n.tr("Текст скопирован") : L10n.tr("Скопировать весь текст для TikTok"),
                              systemImage: copiedTikTokField == key + ".all" ? "checkmark" : "doc.on.doc")
                    }.buttonStyle(StudioPrimaryButtonStyle())
                }
                Spacer(minLength: 0)
            }
            tikTokTextField(L10n.tr("Название"), value: post.hook, key: key + ".title")
            tikTokTextField(L10n.tr("Описание"), value: post.summary, key: key + ".description")
            tikTokTextField(L10n.tr("Хештеги TikTok"), value: tags, key: key + ".hashtags")
            tikTokTextField(L10n.tr("Комментарий со ссылкой на полное эссе"), value: post.pinnedComment, key: key + ".comment")
            Divider()
            if let address = release.receipts[key]?.url, let url = URL(string: address) {
                Link(L10n.tr("Ролик опубликован в TikTok ↗"), destination: url).foregroundStyle(StudioTheme.success)
            } else {
                Text(L10n.tr("После ручной публикации можно сохранить ссылку, чтобы она осталась в проекте."))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
                HStack {
                    TextField(L10n.tr("Ссылка на ваш ролик TikTok"), text: Binding(get: { recoveredURLs[key] ?? "" }, set: { recoveredURLs[key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.tr("Сохранить ссылку")) {
                        run {
                            guard let address = EssayRelease.publicationURL(recoveredURLs[key] ?? "", platform: "tiktok") else {
                                throw EssayReleaseError.invalid(L10n.tr("Вставьте ссылку вида https://www.tiktok.com/@аккаунт/video/номер."))
                            }
                            guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
                            next.receipts[key] = .init(state: .published, url: address, message: L10n.tr("Опубликовано вручную в TikTok"))
                            try await workspace.saveEssayRelease(next, projectID: id)
                        }
                    }.disabled(busy)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioPanel(padding: 24)
    }

    private func tikTokTextField(_ title: String, value: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.muted)
                Spacer()
                Button { copyTikTok(value, key: key) } label: {
                    Label(copiedTikTokField == key ? L10n.tr("Скопировано") : L10n.tr("Копировать"), systemImage: copiedTikTokField == key ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.borderless).foregroundStyle(StudioTheme.accent).font(.caption)
                    .accessibilityLabel(L10n.tr("Копировать TikTok: ") + title)
            }
            Text(value).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15).background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func copyTikTok(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTikTokField = key
    }

    private var deliveryKeys: [String] {
        ["essay.youtube", "telegram.announcement"]
        + (release?.shorts ?? []).flatMap { short in
            [short.id + ".youtube"] + (release?.wantsTikTok == true ? [short.id + ".tiktok"] : [])
        }
        + ["essay.youtube.comment"]
        + (release?.shorts ?? []).map { $0.id + ".youtube.comment" }
    }

    private func recordProgress(_ message: String) {
        OperationJournal.shared.append(message)
        status = publicationSummary(message)
        if journal.last?.1 != message { journal.append((Date(), message)) }
    }

    private func publicationSummary(_ message: String) -> String {
        if message.hasPrefix("Обработка и проверка контента:") {
            let phase = message.components(separatedBy: " · ").first ?? message
            return phase.replacingOccurrences(of: "Проверки начнутся после обработки видео в SD-качестве.", with: "")
                .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message
    }

    private var publicationRoadmap: some View {
        let keys = deliveryKeys
        let completed = keys.filter { release?.receipts[$0]?.state == .published }.count
        let pending = keys.first { release?.receipts[$0]?.state != .published }
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("ПУЛЬТ ПУБЛИКАЦИИ")).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                        Text(completed == keys.count ? L10n.tr("Выпуск опубликован") : pending.map { (busy ? L10n.tr("Сейчас: ") : release?.receipts[$0]?.state == .needsReview ? L10n.tr("Проверьте: ") : L10n.tr("Далее: ")) + targetTitle($0) } ?? L10n.tr("Очередь выпуска"))
                            .font(.system(size: 25, weight: .medium, design: .serif))
                    }
                    Spacer()
                    Text("\(completed) / \(keys.count)").font(.system(size: 24, weight: .medium, design: .monospaced))
                    if let postingStarted {
                        Text(StudioOperationProgress.clock((postingFinished ?? context.date).timeIntervalSince(postingStarted)))
                            .monospacedDigit().foregroundStyle(StudioTheme.muted)
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioTheme.raised)
                        Capsule().fill(StudioTheme.accent).frame(width: proxy.size.width * CGFloat(completed) / CGFloat(max(1, keys.count)))
                    }
                }.frame(height: 4).padding(.vertical, 6)
                ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                    let receipt = release?.receipts[key]
                    let done = receipt?.state == .published
                    let sending = receipt?.state == .sending
                    let review = receipt?.state == .needsReview || receipt?.state == .failed
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle().fill(done ? StudioTheme.success.opacity(0.12) : StudioTheme.raised).frame(width: 34, height: 34)
                            if sending && busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: done ? "checkmark" : review ? "exclamationmark" : key.hasSuffix("comment") ? "pin" : "arrow.up.right")
                                    .foregroundStyle(done ? StudioTheme.success : review ? StudioTheme.warning : StudioTheme.muted) }
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(targetTitle(key)).font(.system(size: 14, weight: .semibold))
                            Text(sending && busy && activeKey == key ? status : done ? L10n.tr("Публикация подтверждена") : review ? L10n.tr("Нужна проверка результата · подробности ниже") : key == pending ? L10n.tr("Следующий шаг") : L10n.tr("В очереди"))
                                .font(.caption).foregroundStyle(review ? StudioTheme.warning : StudioTheme.muted).lineLimit(2)
                        }
                        Spacer()
                        if sending && busy && activeKey == key {
                            Text(StudioOperationProgress.clock(context.date.timeIntervalSince(stepStarted))).monospacedDigit().foregroundStyle(StudioTheme.accent)
                        }
                        if let address = receipt?.url, let url = URL(string: address) {
                            Link(destination: url) { Label(L10n.tr("Открыть"), systemImage: "arrow.up.right") }.foregroundStyle(StudioTheme.accent)
                        } else { Text(String(format: "%02d", index + 1)).font(.system(.caption, design: .monospaced)).foregroundStyle(StudioTheme.muted) }
                    }
                    .padding(8).background(sending ? StudioTheme.accent.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }
                Text(L10n.tr("Приложение проходит очередь сверху вниз. Подтверждённые отправки пропускаются при повторном запуске. Пост для обсуждения отправляется отдельно ниже; связанные видео проверяются вручную в YouTube Studio."))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
                if busy && (workspace.isWorkingOnEssayRelease || activeKey != nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(status, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(StudioTheme.accent)
                        Text(L10n.tr("Площадка подтверждает результат. Процент загрузки показывается только если его сообщает площадка."))
                            .foregroundStyle(StudioTheme.muted)
                        ForEach(Array(journal.suffix(4).enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .top) {
                                Text(event.0, style: .time).monospacedDigit().foregroundStyle(StudioTheme.muted)
                                Text(publicationSummary(event.1)).lineLimit(2)
                            }
                        }
                    }.font(.caption).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                }

            }.studioPanel()
        }
    }

    private var releaseOverview: some View {
        HStack(spacing: 20) {
            if let thumbnail = result.thumbnailURL, let image = NSImage(contentsOf: thumbnail) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 190).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("Один проект. Все материалы выпуска.")).font(.system(size: 17, weight: .semibold))
                HStack(spacing: 18) {
                    Label(L10n.tr("Эссе 16:9"), systemImage: "checkmark.circle")
                    Label(L10n.tr(release?.includesMontage == true ? "Два шортса и музыкальный эдит 9:16" : "Два шортса 9:16"), systemImage: release?.hasReadyShorts == true ? "checkmark.circle" : "clock")
                    Label(L10n.tr("Обложки и тексты"), systemImage: "photo.on.rectangle")
                }.font(.system(size: 12)).foregroundStyle(StudioTheme.accent)
                Text(L10n.tr("YouTube → Telegram → Shorts. Ссылка на полное эссе добавится в публикации автоматически."))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
                DisclosureGroup(L10n.tr("Текст эссе и закреплённый комментарий")) {
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
                Text(L10n.tr("Аккаунты и канал")).font(.subheadline.bold())
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
                Button(L10n.tr("Войти в YouTube / TikTok…")) {
                    run {
                        browserAuth = try await BrowserAutomationService.shared.openLoginSession()
                        connectionMessage = L10n.tr("Сессия сохранена. При входе выберите нужный канал YouTube и аккаунт TikTok.")
                    }
                }
                Button(L10n.tr("Проверить подключения")) {
                    run {
                        browserAuth = try await BrowserAutomationService.shared.checkAuthStatus()
                        let (_, title) = try await TelegramPublishingService.shared.testConnection(botToken: settings.telegramBotToken, channelId: settings.telegramChannelId)
                        connectionMessage = L10n.tr("Telegram: %1$@. Статус YouTube и TikTok показан выше.", String(describing: title))
                    }
                }
            }
            if !connectionMessage.isEmpty { Text(connectionMessage).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup(L10n.tr("Подключить или изменить Telegram")) {
                SecureField(L10n.tr("Токен бота Telegram"), text: $settings.telegramBotToken).textFieldStyle(.roundedBorder)
                TextField(L10n.tr("Канал Telegram"), text: $settings.telegramChannelId).textFieldStyle(.roundedBorder)
                Text(L10n.tr("Настраивается один раз. Бот должен быть администратором канала с правом публикации. Если адрес канала изменён, пересоздайте шортсы: он присутствует в самом видео."))
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
            Text(discussion ? L10n.tr("Пост для обсуждения") : L10n.tr("Анонс эссе")).font(.caption).foregroundStyle(.secondary)
            Text(post?.title ?? "«\(result.arc.movieTitle)» — \(discussion ? (release.shorts.last?.angle ?? "продовжуємо розмову") : (result.arc.publicationTitle ?? result.arc.concept.suggestedTitle))").font(.title3.bold())
            Text(post?.quote ?? result.arc.hookText ?? result.arc.concept.tagline).italic().padding(.leading, 12)
            Text(post?.body ?? result.arc.thesis ?? result.arc.concept.philosophicalPremise)
            Text(post?.question ?? release.shorts.last?.question ?? "").bold()
            if let post, let url = URL(string: post.youtubeURL) { Link(L10n.tr("Дивитися повне есе ↗"), destination: url).buttonStyle(.borderedProminent).tint(StudioTheme.accent) }
            else { Text(L10n.tr("Кнопка просмотра появится после сохранения ссылки эссе")).font(.caption).foregroundStyle(.secondary) }
            Button(release.receipts[key]?.state == .published ? L10n.tr("Пост опубликован") : L10n.tr("Опубликовать этот RichMessage")) {
                run { try await publishPost(discussion: discussion) }
            }.disabled(busy || post == nil || release.receipts[key]?.state == .published)
        }.padding(18).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        OperationJournal.shared.begin(L10n.tr("Публикация выпуска"))
        Task { @MainActor in
            defer { busy = false }
            do {
                try await operation()
                OperationJournal.shared.append(status.isEmpty ? L10n.tr("Действие завершено") : status)
            } catch {
                self.error = error.localizedDescription
                OperationJournal.shared.append(error.localizedDescription, level: .error)
            }
        }
    }

    private func targetTitle(_ key: String) -> String {
        if key.hasSuffix(".comment") {
            return key.hasPrefix("essay.") ? L10n.tr("Эссе · Закреплённый комментарий") : L10n.tr("Шортс %1$@ · Закреплённый комментарий", String(describing: key.hasPrefix("short1.") ? "1" : (key.hasPrefix("short3.") ? "3" : "2")))
        }
        if key == "essay.youtube" { return L10n.tr("Эссе · YouTube") }
        if key == "telegram.announcement" { return L10n.tr("Telegram · Анонс") }
        if key == "telegram.discussion" { return L10n.tr("Telegram · Обсуждение") }
        let number = key.hasPrefix("short1.") ? "1" : (key.hasPrefix("short3.") ? "3" : "2")
        return L10n.tr("Шортс %1$@ · ", String(describing: number)) + (key.hasSuffix(".youtube") ? "YouTube Shorts" : "TikTok")
    }

    private func publishRelease() async throws {
        guard let release, let id = workspace.currentProject?.id else { return }
        postingStarted = Date(); postingFinished = nil; journal = []; recordProgress(L10n.tr("Проверяю подключения и готовность материалов"))
        workspace.isWorkingOnEssayRelease = true; defer { workspace.isWorkingOnEssayRelease = false; postingFinished = Date() }
        _ = try await EssayReleasePublisher().publish(release, result: result,
            botToken: settings.telegramBotToken, channelId: settings.telegramChannelId,
            progress: { recordProgress($0) }, checkpoint: { next in
                let sending = deliveryKeys.first { next.receipts[$0]?.state == .sending }
                if sending != activeKey {
                    activeKey = sending; stepStarted = Date()
                    if let sending { recordProgress(L10n.tr("Начинаем: ") + targetTitle(sending)) }
                }
                for key in deliveryKeys where next.receipts[key]?.state == .published && workspace.currentEssayRelease?.receipts[key]?.state != .published {
                    recordProgress(L10n.tr("Подтверждено: ") + targetTitle(key))
                }
                try await workspace.saveEssayRelease(next, projectID: id)
            })
        youtubeURL = workspace.currentEssayRelease?.essayYouTubeURL ?? ""
        status = release.wantsTikTok
            ? L10n.tr("Отправки завершены. Проверьте привязку связанных видео в YouTube Studio.")
            : L10n.tr("YouTube и Telegram опубликованы, комментарии закреплены. TikTok отложен.")
    }

    private func publishPost(discussion: Bool) async throws {
        guard !settings.telegramBotToken.trimmed.isEmpty, !settings.telegramChannelId.trimmed.isEmpty else {
            throw EssayReleaseError.invalid(L10n.tr("Укажите токен Telegram и канал в Настройках."))
        }
        guard var next = workspace.currentEssayRelease, let id = workspace.currentProject?.id else { return }
        let key = discussion ? "telegram.discussion" : "telegram.announcement"
        postingStarted = Date(); postingFinished = nil; stepStarted = Date(); activeKey = key; journal = []
        defer { activeKey = nil; postingFinished = Date() }
        recordProgress(L10n.tr("Проверяю обложку, текст и кнопку просмотра для Telegram"))
        try EssayReleasePublisher.requireRetryAllowed(next.receipts[key])
        let post = try EssayRichPost.make(result: result, release: next, discussion: discussion)
        next.receipts[key] = .init(state: .sending, message: L10n.tr("Отправка RichMessage"))
        try await workspace.saveEssayRelease(next, projectID: id)
        do {
            recordProgress(L10n.tr("Отправляю обложку и RichMessage в Telegram…"))
            let messageID = try await TelegramPublishingService.shared.publishRichPost(post, botToken: settings.telegramBotToken, channelId: settings.telegramChannelId)
            next.receipts[key] = .init(state: .published, url: telegramURL.map { $0 + "/\(messageID)" }, message: L10n.tr("Сообщение #%1$@", String(describing: messageID)))
            try await workspace.saveEssayRelease(next, projectID: id)
            recordProgress(L10n.tr("Telegram подтвердил публикацию · сообщение #%1$@", String(describing: messageID)))
        } catch {
            let message = error.localizedDescription.replacingOccurrences(of: settings.telegramBotToken, with: L10n.tr("[скрыто]"))
            next.receipts[key] = .init(state: .needsReview, message: message)
            try await workspace.saveEssayRelease(next, projectID: id); throw EssayReleaseError.invalid(message)
        }
    }
}
