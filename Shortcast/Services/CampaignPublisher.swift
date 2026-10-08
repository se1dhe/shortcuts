import Foundation
import Observation

/// Orchestrates a full cross-platform campaign: the long-form essay to YouTube,
/// every approved short to TikTok/Instagram/YouTube Shorts (via Upload-Post),
/// and a final Telegram post that gathers the essay link plus all short links
/// over a cover image.
///
/// Everything observable lives here so `CampaignPublisherView` can render a live
/// checklist. Publishing reuses the existing per-clip and browser-automation
/// flows rather than duplicating them.
@MainActor
@Observable
final class CampaignPublisher {

    enum StepStatus: Sendable, Equatable {
        case pending, running, done, failed, skipped
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var status: StepStatus = .pending
        var detail: String?
    }

    // MARK: Context (immutable)

    let essay: LongformBuildResult?
    let movieTitle: String
    let movie: MovieIdentity?
    let clips: [ShortClip]

    // MARK: Observable state

    private(set) var steps: [Step] = []
    private(set) var result = CampaignResult()
    var telegramDraft: String = ""
    private(set) var isRunning = false
    var errorMessage: String?

    private let essayStepID = "essay"
    private let telegramStepID = "telegram"
    private let shortPlatforms: Set<SocialPlatform> = [.tiktok, .instagram, .youtube]

    init(essay: LongformBuildResult?, movieTitle: String, movie: MovieIdentity?, clips: [ShortClip]) {
        self.essay = essay
        self.movieTitle = movieTitle.isEmpty ? (movie?.title ?? "") : movieTitle
        self.movie = movie
        self.clips = clips
        rebuildSteps()
        self.telegramDraft = buildTelegramDraft()
    }

    /// Clips that will actually be pushed as part of the campaign.
    var publishableClips: [ShortClip] {
        clips.filter { $0.isApproved && $0.isReadyToPublish }
    }

    /// Editable essay link — auto-filled after a successful YouTube upload, but
    /// the user can paste one manually if browser automation didn't return it.
    var essayYouTubeURL: String {
        get { result.essayYouTubeURL ?? "" }
        set { result.essayYouTubeURL = newValue.trimmed.isEmpty ? nil : newValue.trimmed }
    }

    func rebuildSteps() {
        var newSteps: [Step] = []
        if essay != nil {
            newSteps.append(Step(id: essayStepID, title: "Эссе → YouTube"))
        }
        for (index, clip) in publishableClips.enumerated() {
            newSteps.append(Step(id: clip.id.uuidString, title: "Шорт \(index + 1): \(clip.displayTitle)"))
        }
        newSteps.append(Step(id: telegramStepID, title: "Telegram-пост"))
        steps = newSteps
    }

    // MARK: - Run

    /// Full campaign: essay → shorts (parallel) → refresh draft → Telegram post.
    func runCampaign(settings: AppSettings) async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        await publishEssay()
        await publishShorts(settings: settings)
        refreshTelegramDraft()
        await sendTelegramPost(settings: settings)
    }

    /// Sends only the Telegram post, using whatever links are already known.
    func publishTelegramOnly(settings: AppSettings) async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        refreshTelegramDraft()
        await sendTelegramPost(settings: settings)
    }

    // MARK: Essay

    private func publishEssay() async {
        guard let essay else { return }
        updateStep(essayStepID, .running, detail: "Загрузка на YouTube…")
        let job = BrowserUploadJob(
            videoURL: essay.outputURL,
            thumbnailURL: essay.thumbnailURL,
            platforms: [.youtube],
            title: essay.metadata.title,
            caption: essay.metadata.description,
            hashtags: essay.metadata.tags,
            isPublic: true,
            headless: true)
        do {
            var captured: String?
            var failed = false
            for try await event in BrowserAutomationService.shared.publish(job: job) {
                switch event {
                case .progress(_, let message):
                    updateStep(essayStepID, .running, detail: message)
                case .success(_, _, let url):
                    if let url, !url.trimmed.isEmpty { captured = url }
                case .failure(_, let message):
                    failed = true
                    updateStep(essayStepID, .failed, detail: message)
                case .captchaDetected(_, let message):
                    updateStep(essayStepID, .running, detail: "Нужна капча: \(message)")
                case .finished:
                    break
                }
            }
            if let captured {
                result.essayYouTubeURL = captured
                updateStep(essayStepID, .done, detail: captured)
            } else if !failed {
                updateStep(essayStepID, .done, detail: "Опубликовано (URL не возвращён — вставьте ссылку вручную)")
            }
        } catch {
            updateStep(essayStepID, .failed, detail: error.localizedDescription)
        }
    }

    // MARK: Shorts

    private func publishShorts(settings: AppSettings) async {
        let targets = publishableClips
        guard !targets.isEmpty else { return }
        for target in targets { updateStep(target.id.uuidString, .running, detail: "Публикация…") }

        let platforms = shortPlatforms
        let apiKey = settings.apiKey
        let profileName = settings.profileName
        await withTaskGroup(of: (UUID, ShortCampaignResult).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < targets.count else { return }
                let index = nextIndex
                nextIndex += 1
                let clip = targets[index]
                group.addTask {
                    await clip.publish(settings: settings, selectedPlatforms: platforms)
                    var urls: [SocialPlatform: String] = [:]
                    if let report = await clip.publishReport {
                        for (platform, outcome) in report.outcomes {
                            if case .success(let raw) = outcome, let raw, !raw.trimmed.isEmpty {
                                urls[platform] = raw
                            }
                        }
                        // Upload-Post often answers "submitted" and only exposes
                        // real URLs later — poll every 5s up to 2 minutes.
                        if let requestID = report.requestID, urls.count < platforms.count {
                            let client = UploadPostClient(apiKey: apiKey, profileName: profileName)
                            for _ in 0..<24 {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                if let polled = try? await client.pollStatus(reportID: requestID) {
                                    for (platform, url) in polled where urls[platform] == nil {
                                        urls[platform] = url
                                    }
                                }
                                if urls.count >= platforms.count { break }
                            }
                        }
                    }
                    let title = await clip.displayTitle
                    let failure = await clip.publishError
                    return (clip.id, ShortCampaignResult(id: clip.id.uuidString, title: title, urls: urls, error: failure))
                }
            }

            for _ in 0..<min(2, targets.count) { enqueueNext() }
            while let (id, shortResult) = await group.next() {
                self.result.shorts.append(shortResult)
                let status: StepStatus = shortResult.error == nil ? .done : .failed
                let detail = shortResult.error ?? shortResult.urls.values.first ?? "Отправлено"
                self.updateStep(id.uuidString, status, detail: detail)
                enqueueNext()
            }
        }
    }

    // MARK: Telegram

    func sendTelegramPost(settings: AppSettings) async {
        updateStep(telegramStepID, .running, detail: "Отправка…")
        let token = settings.telegramBotToken.trimmed
        let channel = settings.telegramChannelId.trimmed
        guard !token.isEmpty, !channel.isEmpty else {
            updateStep(telegramStepID, .failed, detail: "Токен бота или ID канала не заданы в Настройках.")
            return
        }
        let thumbnail = essay?.thumbnailURL ?? movie?.posterURL ?? movie?.backdropURL
        do {
            let messageID = try await TelegramPublishingService.shared.publishCampaign(
                text: telegramDraft,
                thumbnail: thumbnail,
                botToken: token,
                channelId: channel)
            let clean = channel.hasPrefix("@") ? String(channel.dropFirst()) : channel
            let postURL = "https://t.me/\(clean)/\(messageID)"
            result.telegramPostURL = postURL
            updateStep(telegramStepID, .done, detail: postURL)
        } catch {
            updateStep(telegramStepID, .failed, detail: error.localizedDescription)
        }
    }

    /// Rebuilds the editable Telegram post text from the links gathered so far.
    func refreshTelegramDraft() {
        telegramDraft = buildTelegramDraft()
    }

    func buildTelegramDraft() -> String {
        var lines: [String] = []
        let yearPart = (movie?.year.isEmpty == false) ? " (\(movie!.year))" : ""
        lines.append("🎬 «\(movieTitle)»\(yearPart)")

        var meta: [String] = []
        if let imdb = movie?.imdbRating, !imdb.isEmpty { meta.append("IMDb \(imdb)") }
        if let genres = movie?.genres, !genres.isEmpty { meta.append(genres.joined(separator: ", ")) }
        if !meta.isEmpty { lines.append("⭐ " + meta.joined(separator: " · ")) }
        lines.append("")

        if let essayURL = result.essayYouTubeURL, !essayURL.isEmpty {
            lines.append("📽️ Полное видео-эссе:")
            lines.append("→ \(essayURL)")
            lines.append("")
        }

        let links = result.collectedShortLinks
        if !links.isEmpty {
            lines.append("✂️ Лучшие моменты:")
            for link in links {
                lines.append("\(emoji(for: link.platform)) \(link.platform.rawValue.capitalized): \(link.url)")
            }
            lines.append("")
        }

        lines.append(hashtagLine())
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hashtagLine() -> String {
        var tags: [String] = []
        if let genres = movie?.genres {
            tags.append(contentsOf: genres.prefix(2).map { "#" + $0.replacingOccurrences(of: " ", with: "") })
        }
        tags.append("#Кино")
        tags.append("#Кинематограф")
        return Array(Set(tags)).joined(separator: " ")
    }

    private func emoji(for platform: SocialPlatform) -> String {
        switch platform {
        case .youtube: "▶️"
        case .tiktok: "📱"
        case .instagram: "📸"
        case .telegram: "✈️"
        }
    }

    /// Files the "Экспортировать все файлы" action reveals in Finder.
    func filesToExport() -> [URL] {
        var urls: [URL] = []
        if let essay {
            urls.append(essay.outputURL)
            if let thumbnail = essay.thumbnailURL { urls.append(thumbnail) }
        }
        for clip in publishableClips {
            if let url = clip.clipJob?.url { urls.append(url) }
        }
        return urls
    }

    private func updateStep(_ id: String, _ status: StepStatus, detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].status = status
        if let detail { steps[index].detail = detail }
    }
}
