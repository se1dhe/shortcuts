import AppKit
import Observation

@MainActor @Observable
final class ShortsLibrary {
    var cards: [DiscoveredShort] = []
    var selected = Set<String>()
    var busy = false
    var message = ""
    var storageAvailable = true
    var tikTokAuth: BrowserAuthStatus?
    var accountMessage = "Аккаунт ещё не проверен"
    var hasTargetTikTok: Bool {
        tikTokAuth?.tiktok == true && tikTokAuth?.tiktokHandle?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@")) == "telonyx_cinema"
    }
    let directory: URL
    private var searchPage = 0
    private let service = ShortsDiscoveryService()
    private var manifest: URL { directory.appendingPathComponent("library.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shortcast/YouTubeShorts")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                cards = try JSONDecoder().decode([DiscoveredShort].self, from: Data(contentsOf: manifest))
                for index in cards.indices where cards[index].status == .publishing {
                    cards[index].status = .needsReview
                    cards[index].issue = "Приложение закрылось во время публикации. Проверьте профиль TikTok."
                }
                try save()
            }
        } catch {
            storageAvailable = false
            message = "Не удалось открыть библиотеку. Исходный файл сохранён: \(error.localizedDescription)"
        }
    }

    func save() throws {
        guard storageAvailable else { throw ShortsError.message("Библиотека недоступна для записи.") }
        try JSONEncoder().encode(cards).write(to: manifest, options: .atomic)
    }

    @discardableResult
    func update(_ id: String, change: (inout DiscoveredShort) -> Void) -> Bool {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return false }
        let previous = cards[i]
        change(&cards[i])
        do { try save(); return true } catch { cards[i] = previous; message = error.localizedDescription; return false }
    }

    func dismiss(_ id: String) {
        guard !busy, cards.first(where: { $0.id == id })?.status == .discovered else { return }
        let previous = cards
        cards.removeAll { $0.id == id }
        do { try save(); selected.remove(id) }
        catch { cards = previous; message = error.localizedDescription }
    }

    func discover(film: String, category: String) async {
        guard !busy, storageAvailable else { return }
        busy = true; defer { busy = false }
        message = "Ищем короткие сцены и эдиты…"
        do {
            let films: [String]
            if film == "Все фильмы" {
                films = (0..<3).map { ShortsDiscoveryService.films[(searchPage * 3 + $0) % ShortsDiscoveryService.films.count] }
                searchPage += 1
            } else { films = [film] }
            let found = try await service.discover(films: films, category: category)
            let ids = Set(cards.map(\.id))
            let new = found.filter { !ids.contains($0.id) }
            cards += new
            try save()
            message = new.isEmpty ? "Новых шортсов нет. Попробуйте другой фильм или категорию." : "Найдено: \(new.count). Проверьте русский звук и фильм в предпросмотре."
        } catch { message = error.localizedDescription }
    }

    func process(_ id: String) async {
        guard !busy, storageAvailable, let card = cards.first(where: { $0.id == id }),
              card.reviewed, [.discovered, .ready].contains(card.status) else { return }
        busy = true; defer { busy = false }
        message = "Загружаем и обрабатываем: \(card.title)"
        do {
            let watermark = try ShortsWatermark.writeFrames(in: directory.appendingPathComponent("watermark-v2"))
            let output = try await service.render(card, directory: directory, watermark: watermark)
            let saved = update(id) {
                $0.outputPath = output.url.path; $0.status = .ready; $0.issue = nil; $0.watermarkVersion = ShortsWatermark.version
                if $0.duration == 0 { $0.duration = output.sourceDuration; $0.end = output.sourceDuration }
            }
            guard saved else { return }
            selected.remove(id)
            message = "Готово. Посмотрите результат и отметьте карточку для публикации."
        } catch {
            update(id) { $0.issue = error.localizedDescription }
            message = error.localizedDescription
        }
    }

    var selectedReady: [DiscoveredShort] { cards.filter { selected.contains($0.id) && $0.canPublish } }

    private func recordAuth(_ auth: BrowserAuthStatus) {
        tikTokAuth = auth
        if hasTargetTikTok { accountMessage = "Подключён @telonyx_cinema · можно публиковать" }
        else if let handle = auth.tiktokHandle { accountMessage = "Открыт @\(handle). Для публикации войдите в @telonyx_cinema." }
        else { accountMessage = "Войдите в @telonyx_cinema, затем закройте окно Chrome и проверьте аккаунт." }
    }

    func connectTikTok() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        message = "В отдельном окне Chrome войдите в @telonyx_cinema. Затем закройте это окно Chrome — вход сохранится, и приложение продолжит работу."
        do {
            recordAuth(try await BrowserAutomationService.shared.openLoginSession(tikTokOnly: true))
            message = accountMessage
        } catch { accountMessage = error.localizedDescription; message = accountMessage }
    }

    func refreshTikTok() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        accountMessage = "Проверяем сохранённый аккаунт TikTok…"
        do { recordAuth(try await BrowserAutomationService.shared.checkAuthStatus()) }
        catch { tikTokAuth = nil; accountMessage = error.localizedDescription }
    }

    func publishSelected() async {
        guard !busy, storageAvailable, !selectedReady.isEmpty else { return }
        let queue = selectedReady
        busy = true; defer { busy = false }
        do {
            recordAuth(try await BrowserAutomationService.shared.checkAuthStatus())
            guard hasTargetTikTok else {
                throw ShortsError.message("Войдите в TikTok @telonyx_cinema через кнопку «Войти». Открыт другой аккаунт или сессия не найдена.")
            }
            for (offset, card) in queue.enumerated() {
                guard let path = card.outputPath, FileManager.default.fileExists(atPath: path),
                      let index = cards.firstIndex(where: { $0.id == card.id }) else { continue }
                cards[index].status = .publishing
                // Persist before any external action: an interrupted upload must never be retried silently.
                try save()
                var job = BrowserUploadJob(videoURL: URL(fileURLWithPath: path), platforms: [.tiktok],
                    title: card.title, caption: card.caption, headless: false, isShort: true)
                job.expectedTikTokHandle = "telonyx_cinema"
                var receipt: String?
                do {
                    for try await event in BrowserAutomationService.shared.publish(job: job) {
                        switch event {
                        case .progress(_, let text), .captchaDetected(_, let text): message = "Ролик \(offset + 1) из \(queue.count): \(text)"
                        case .success(let platform, _, let url):
                            if platform == "tiktok", let url, DiscoveredShort.isTargetPublication(url) { receipt = url }
                        case .failure(_, let text): throw ShortsError.message(text)
                        case .finished: break
                        }
                    }
                    guard let receipt else { throw ShortsError.message("Нет подтверждённой ссылки. Проверьте профиль перед повторной отправкой.") }
                    cards[index].status = .published; cards[index].publishedURL = receipt; cards[index].issue = nil
                    try save()
                    selected.remove(card.id)
                } catch {
                    cards[index].status = .needsReview; cards[index].issue = error.localizedDescription
                    try save()
                    throw error
                }
            }
            message = "Публикация завершена: @telonyx_cinema"
        } catch { message = error.localizedDescription }
    }

}
