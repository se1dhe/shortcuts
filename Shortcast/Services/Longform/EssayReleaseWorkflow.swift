import Foundation

extension WorkspaceModel {
    var currentEssayRelease: EssayRelease? {
        guard let result = longformResult, let release = currentProject?.essayRelease,
              release.essayKey == EssayRelease.key(for: result.arc) else { return nil }
        return release
    }

    /// The review-to-release handoff is idempotent. Reopening a prepared release
    /// must not ask the model for another pair or replace approved exports.
    func prepareEssayRelease(modelManager: ModelManager, settings: AppSettings,
                             progress: (String) -> Void) async throws {
        if currentEssayRelease?.hasReadyShorts == true {
            progress("Выпуск готов: эссе, два шортса, обложки и тексты")
            return
        }
        try await generateEssayRelease(modelManager: modelManager, settings: settings, reuseExistingPlans: true, progress: progress)
    }

    func saveEssayRelease(_ release: EssayRelease, projectID: UUID) async throws {
        guard var project = currentProject, project.id == projectID,
              let result = longformResult, release.essayKey == EssayRelease.key(for: result.arc) else {
            throw EssayReleaseError.invalid("Проект или тема изменились. Результат не записан поверх другого выпуска.")
        }
        project.essayRelease = release
        try await filmProjectService.saveProject(project)
        currentProject = project
    }

    func rebuildEssayShort(_ edited: EssayShort, settings: AppSettings) async throws {
        guard !isWorkingOnEssayRelease, var release = currentEssayRelease,
              let index = release.shorts.firstIndex(where: { $0.id == edited.id }),
              let result = longformResult, let project = currentProject,
              let transcript = storedTranscript ?? project.transcript, let job else {
            throw EssayReleaseError.invalid("Откройте готовый выпуск и исходный фильм.")
        }
        guard EssayShortEditing.canEdit(edited, in: release) else {
            throw EssayReleaseError.invalid("Этот шортс уже отправлялся на площадку. Сначала проверьте его публикации.")
        }
        try EssayShortEditing.validate(edited, arc: result.arc, sourceDuration: job.durationSeconds)
        isWorkingOnEssayRelease = true
        defer { isWorkingOnEssayRelease = false }
        let old = release.shorts[index]
        let directory = try ExportLayout.shortsDirectory(in: result.outputURL.deletingLastPathComponent())
        let rendered = try await EssayShortRenderer().render(edited, sourceURL: job.url, result: result,
            transcript: transcript, telegramURL: LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId),
            directory: directory)
        release.shorts[index] = rendered
        do {
            try await saveEssayRelease(release, projectID: project.id)
        } catch {
            removeManagedShortFiles(rendered, directory: directory)
            throw error
        }
        removeManagedShortFiles(old, directory: directory)
    }

    private func removeManagedShortFiles(_ short: EssayShort, directory: URL) {
        for url in [short.outputURL, short.coverURL].compactMap({ $0 }) {
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  url.lastPathComponent.hasPrefix("essay_" + short.id + "_") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func recordEssayYouTubeURL(_ value: String, result: LongformBuildResult, projectID: UUID) async throws {
        guard let url = EssayRelease.youtubeURL(value), let active = longformResult,
              active.arc == result.arc else { throw EssayReleaseError.invalid("Нужна точная HTTPS-ссылка на это эссе YouTube.") }
        var release = currentEssayRelease ?? EssayRelease(essayKey: EssayRelease.key(for: result.arc))
        if let old = release.essayYouTubeURL, old != url,
           release.receipts.contains(where: { $0.key != "essay.youtube" && $0.value.state == .published }) {
            throw EssayReleaseError.invalid("Этот выпуск уже опубликован со старой ссылкой. Сначала проверьте связанные публикации.")
        }
        release.essayYouTubeURL = url
        release.receipts["essay.youtube"] = .init(state: .published, url: url, message: "Ссылка эссе сохранена")
        try await saveEssayRelease(release, projectID: projectID)
    }

    func generateEssayRelease(modelManager: ModelManager, settings: AppSettings, reuseExistingPlans: Bool = false,
                              progress: (String) -> Void) async throws {
        guard !isWorkingOnEssayRelease, let result = longformResult, let project = currentProject,
              let transcript = storedTranscript ?? project.transcript, let source = job?.url else {
            throw EssayReleaseError.invalid("Откройте готовое эссе и его исходный фильм.")
        }
        if let existing = currentEssayRelease, existing.receipts.contains(where: { $0.key != "essay.youtube" && $0.value.state != .failed }) {
            throw EssayReleaseError.invalid("Выпуск уже отправлялся на площадки. Его нельзя молча заменить новыми шортсами.")
        }
        isWorkingOnEssayRelease = true; defer { isWorkingOnEssayRelease = false }
        let language = transcript.contentLanguage ?? transcript.language ?? ""
        guard language.lowercased().hasPrefix("uk") else {
            throw EssayReleaseError.invalid("Для этого выпуска нужна транскрипция украинской озвучки. Проверьте выбранную аудиодорожку.")
        }
        var release = currentEssayRelease ?? EssayRelease(essayKey: EssayRelease.key(for: result.arc))
        if release.shorts.count != 2 || (!reuseExistingPlans && release.shorts.allSatisfy({ $0.outputURL != nil })) {
            progress("Модель выбирает два самостоятельных сюжета по теме эссе…")
            try await modelManager.requireDirector(profile: settings.copywriterModel.directorProfile)
            let finder = modelManager.momentFinder
            let profile = settings.copywriterModel.directorProfile
            let gateway = DirectorChatGateway(readiness: { await finder.isReady }, identifier: { profile.modelID },
                completion: { instructions, prompt, tokens in
                    await finder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: tokens)
                })
            let planned = try await EssayShortDirector(model: gateway).plan(arc: result.arc, transcript: transcript)
        // Keep completed renders if generation is interrupted, rather than lose
        // all progress after the second export fails.
            release.shorts = planned
            try await saveEssayRelease(release, projectID: project.id)
            modelManager.freeDirectorIfMemoryTight()
        }
        let film = result.outputURL.deletingLastPathComponent()
        let directory = try ExportLayout.shortsDirectory(in: film)
        let telegram = LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId)
        for index in release.shorts.indices {
            if let output = release.shorts[index].outputURL, FileManager.default.fileExists(atPath: output.path) { continue }
            progress("Монтаж вертикального шортса \(index + 1) из 2…")
            release.shorts[index] = try await EssayShortRenderer().render(release.shorts[index], sourceURL: source,
                result: result, transcript: transcript, telegramURL: telegram, directory: directory)
            try await saveEssayRelease(release, projectID: project.id)
        }
        progress("Два шортса и тексты выпуска готовы")
    }
}

@MainActor
struct EssayReleasePublisher {
    let browser: any BrowserPublishingProtocol
    let telegram: TelegramPublishingService

    init(browser: any BrowserPublishingProtocol = BrowserAutomationService.shared,
         telegram: TelegramPublishingService = .shared) { self.browser = browser; self.telegram = telegram }

    func publish(_ original: EssayRelease, result: LongformBuildResult, botToken: String, channelId: String,
                 progress: (String) -> Void, checkpoint: (EssayRelease) async throws -> Void) async throws -> EssayRelease {
        guard original.essayKey == EssayRelease.key(for: result.arc), original.shorts.count == 2,
              original.shorts.allSatisfy({ $0.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } == true }) else {
            throw EssayReleaseError.invalid("Сначала дождитесь готовности обоих шортсов.")
        }
        guard !botToken.trimmed.isEmpty, !channelId.trimmed.isEmpty else {
            throw EssayReleaseError.invalid("Для всего выпуска нужны токен Telegram и канал в Настройках.")
        }
        let needsYouTube = original.essayYouTubeURL == nil || original.receipts["essay.youtube.comment"]?.state != .published || original.shorts.contains {
            original.receipts["\($0.id).youtube"]?.state != .published || original.receipts["\($0.id).youtube.comment"]?.state != .published
        }
        let needsTikTok = original.wantsTikTok && original.shorts.contains {
            original.receipts["\($0.id).tiktok"]?.state != .published
        }
        if needsYouTube || needsTikTok {
            let auth = try await browser.checkAuthStatus()
            if needsYouTube && !auth.youtube {
                throw EssayReleaseError.invalid("Подключите YouTube через кнопку входа в браузер.")
            }
            if needsTikTok && !auth.tiktok {
                throw EssayReleaseError.invalid("TikTok не подключён. Можно отложить TikTok в этом окне и опубликовать YouTube + Telegram сейчас.")
            }
        }
        var release = original
        if release.essayYouTubeURL == nil {
            let metadata = LongformMetadataGenerator.updatingTelegram(in: result.metadata, channelID: channelId)
            let job = BrowserUploadJob(videoURL: result.outputURL, thumbnailURL: result.thumbnailURL, platforms: [.youtube],
                title: metadata.title, caption: metadata.description, hashtags: [], isPublic: true, headless: false)
            release = try await send(job, key: "essay.youtube", release: release, progress: progress, checkpoint: checkpoint)
            guard let url = release.receipts["essay.youtube"]?.url.flatMap(EssayRelease.youtubeURL) else {
                throw EssayReleaseError.invalid("YouTube не вернул ссылку эссе. Сохраните её вручную перед продолжением.")
            }
            release.essayYouTubeURL = url; try await checkpoint(release)
        }
        let telegramURL = LongformEditorialSupport.telegramURL(channelID: channelId)
        let key = "telegram.announcement"
        if release.receipts[key]?.state != .published {
            try Self.requireRetryAllowed(release.receipts[key])
            let post = try EssayRichPost.make(result: result, release: release, discussion: false)
            release.receipts[key] = .init(state: .sending, message: "Отправка RichMessage")
            try await checkpoint(release); progress("Публикация RichMessage в Telegram…")
            do {
                let id = try await telegram.publishRichPost(post, botToken: botToken, channelId: channelId)
                let url = telegramURL.map { $0 + "/\(id)" }
                release.receipts[key] = .init(state: .published, url: url, message: "Telegram, сообщение #\(id)")
                try await checkpoint(release)
            } catch {
                let message = error.localizedDescription.replacingOccurrences(of: botToken, with: "[скрыто]")
                release.receipts[key] = .init(state: .needsReview, message: "Проверьте канал перед повтором: \(message)")
                try await checkpoint(release); throw EssayReleaseError.invalid(message)
            }
        }
        let platforms: [SocialPlatform] = release.wantsTikTok ? [.youtube, .tiktok] : [.youtube]
        for short in release.shorts {
            for platform in platforms {
                let post = short.post(platform: platform, movieTitle: result.arc.movieTitle, release: release, telegramURL: telegramURL)
                let job = BrowserUploadJob(videoURL: short.outputURL!, thumbnailURL: short.coverURL, platforms: [platform],
                    title: post.hook, caption: post.summary, hashtags: post.hashtags, isPublic: true, headless: false, isShort: true)
                release = try await send(job, key: "\(short.id).\(platform.rawValue)", release: release,
                    progress: progress, checkpoint: checkpoint)
            }
        }
        // Finish primary deliveries first; a pin failure must not hold back
        // the announcement or other videos. Comments have separate receipts.
        let metadata = LongformMetadataGenerator.updatingTelegram(in: result.metadata, channelID: channelId)
        var comments: [(String, String, String)] = [("essay.youtube.comment", release.essayYouTubeURL!, metadata.pinnedComment)]
        for short in release.shorts {
            if let url = release.receipts["\(short.id).youtube"]?.url {
                comments.append(("\(short.id).youtube.comment", url,
                    short.post(platform: .youtube, movieTitle: result.arc.movieTitle, release: release, telegramURL: telegramURL).pinnedComment))
            }
        }
        var commentErrors: [String] = []
        for (key, url, text) in comments where release.receipts[key]?.state != .published {
            let job = BrowserUploadJob(videoURL: result.outputURL, platforms: [.youtube], title: result.metadata.title,
                caption: "", headless: false, action: "youtube-comment", targetVideoURL: url, pinnedComment: text)
            do {
                release = try await send(job, key: key, release: release, progress: progress, checkpoint: checkpoint)
            } catch {
                release.receipts[key] = .init(state: .needsReview, message: error.localizedDescription)
                try await checkpoint(release)
                commentErrors.append("\(key): \(error.localizedDescription)")
            }
        }
        if !commentErrors.isEmpty {
            throw EssayReleaseError.invalid("Видео и посты опубликованы; не завершены закреплённые комментарии: " + commentErrors.joined(separator: "; "))
        }
        return release
    }

    private func send(_ job: BrowserUploadJob, key: String, release original: EssayRelease,
                      progress: (String) -> Void, checkpoint: (EssayRelease) async throws -> Void) async throws -> EssayRelease {
        if original.receipts[key]?.state == .published { return original }
        // The comment action reconciles an exact existing own comment before
        // posting, so it can recover safely from an interrupted pin attempt.
        if job.action != "youtube-comment" { try Self.requireRetryAllowed(original.receipts[key]) }
        var release = original
        release.receipts[key] = .init(state: .sending, message: "Отправка на площадку")
        try await checkpoint(release)
        do {
            var received = false
            for try await event in browser.publish(job: job) {
                switch event {
                case .progress(_, let message): progress(message)
                case .success(let platform, let message, let url):
                    guard job.platforms.contains(platform), let url,
                          (job.action == "youtube-comment" ? EssayRelease.youtubeCommentURL(url) : EssayRelease.publicationURL(url, platform: platform)) != nil else {
                        throw EssayReleaseError.invalid("Площадка не вернула подтверждённую ссылку. Проверьте результат вручную.")
                    }
                    release.receipts[key] = .init(state: .published, url: url, message: message)
                    try await checkpoint(release); received = true
                case .failure(_, let message), .captchaDetected(_, let message): throw EssayReleaseError.invalid(message)
                case .finished: break
                }
            }
            guard received else { throw EssayReleaseError.invalid("Нет подтверждения публикации. Проверьте площадку перед повтором.") }
            return release
        } catch {
            if release.receipts[key]?.state != .published {
                release.receipts[key] = .init(state: .needsReview, message: error.localizedDescription)
                try await checkpoint(release)
            }
            throw error
        }
    }

    static func requireRetryAllowed(_ receipt: EssayRelease.Receipt?) throws {
        if receipt?.state == .needsReview || receipt?.state == .sending {
            throw EssayReleaseError.invalid("Исход предыдущей отправки неизвестен. Сначала проверьте площадку, чтобы не создать дубликат.")
        }
    }
}
