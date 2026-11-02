import AppKit
import SwiftUI
import WebKit

struct FilmPlanLibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var library = FilmLibrary.shared
    @State private var query = ""
    @State private var unfinishedOnly = true
    @State private var selected: PlannedFilm?
    @State private var cancellation: FilmLibrary.Download?
    let onChooseFile: (URL, VideoSourceMetadata?) -> Void
    private var visibleFilms: [PlannedFilm] {
        library.films.filter { (!unfinishedOnly || !library.completed.contains($0.id)) && (query.isEmpty || ($0.title + $0.topic + String($0.year)).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Фильмы из плана").font(.title2.bold())
                Spacer()
                Button("Импортировать план…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { do { try library.importPlan(url) } catch { library.error = error.localizedDescription } }
                }
                Button("Закрыть") { dismiss() }
            }
            HStack { TextField("Найти фильм, год или тему", text: $query); Toggle("Только невыполненные", isOn: $unfinishedOnly) }
            Text("\(library.films.count) фильмов · \(library.completed.count) эссе выполнено. Скачивание и выполнение эссе учитываются отдельно.").font(.caption).foregroundStyle(.secondary)
            if let error = library.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !library.downloads.isEmpty {
                ScrollView { VStack(spacing: 10) { ForEach(library.downloads) { task in downloadRow(task) } } }.frame(maxHeight: 210)
            }
            List(visibleFilms) { film in
                HStack(alignment: .top, spacing: 12) {
                    Button { library.toggleCompleted(film) } label: { Image(systemName: library.completed.contains(film.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless).help("Эссе выполнено")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(film.number). \(film.title) · \(film.year)").font(.headline)
                        Text(film.topic).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Выбрать раздачу", systemImage: "arrow.down.circle") { selected = film }.disabled(settings.workingDirectory == nil).accessibilityLabel("Выбрать раздачу: " + film.title)
                }.padding(.vertical, 8).accessibilityElement(children: .contain)
            }
            OperationLogPanel(isActive: library.downloads.contains { $0.state == "Загрузка" })
        }.padding(24).frame(width: 1040, height: 760)
        .sheet(item: $selected) { film in
            if let folder = settings.workingDirectory { FilmTorrentBrowser(film: film, workingDirectory: folder) }
        }
        .confirmationDialog("Убрать загрузку?", isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } })) {
            Button("Убрать задачу, оставить файлы") { removeTask(false) }
            Button("Убрать задачу и переместить файлы в Корзину", role: .destructive) { removeTask(true) }
        }

    }
    private func removeTask(_ files: Bool) {
        guard let task = cancellation else { return }
        do { try library.remove(task.id, deleteFiles: files) } catch { library.error = error.localizedDescription }
        cancellation = nil
    }
    private func downloadRow(_ task: FilmLibrary.Download) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(task.film.title + " · " + task.state).font(.headline)
                Text(task.progress).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button("В Finder") { NSWorkspace.shared.open(task.folder) }
            if task.state == "Загрузка" { Button("Пауза") { library.pause(task.id) } }
            else {
                if task.state == "Скачан" || task.state == "MP4 готов" { Button(task.state == "MP4 готов" ? "Открыть проект" : "Подготовить MP4") { dismiss(); onChooseFile(task.readyURL ?? task.sourceURL, VideoSourceMetadata(title: task.film.title)) } }
                else { Button("Продолжить") { do { try library.resume(task.id) } catch { library.error = error.localizedDescription } } }
                Button("Убрать") { cancellation = task }
            }
        }.padding(12).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor @Observable
final class FilmTorrentBrowserModel: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    var torrents: [FilmTorrent] = []
    var error: String?
    var isLoading = false
    var isObtainingTorrent = false
    var downloadMessage = ""
    private var linkPolling: Task<Void, Never>?
    var files: [TorrentManifest.File] = []
    var downloadedTorrent: URL?
    var selectedFile = 0
    let web = WKWebView()
    private let folder: URL
    private var tableURL: URL?
    private var pendingTableSelection: FilmTorrent?
    private var expectedFilm: PlannedFilm?
    private var automaticNavigation = Set<String>()
    init(folder: URL) { self.folder = folder; super.init(); web.navigationDelegate = self }
    func search(_ film: PlannedFilm) {
        expectedFilm = film; automaticNavigation = []
        var components = URLComponents(string: "https://uakino.best/ua/")!
        components.queryItems = [.init(name: "do", value: "search"), .init(name: "subaction", value: "search"), .init(name: "story", value: film.title)]
        web.load(URLRequest(url: components.url!))
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true; error = nil; if !isObtainingTorrent { torrents = [] } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { isLoading = false; self.error = error.localizedDescription }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if isObtainingTorrent {
            if let pending = pendingTableSelection, webView.url == tableURL { pendingTableSelection = nil; clickSiteRelease(pending) }
            else { waitForFileLink() }
            return
        }
        let script = UAKinoAdapter.torrentScript
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error { self.error = error.localizedDescription; return }
            guard let json = value as? String, let data = json.data(using: .utf8) else { return }
            do { self.torrents = try UAKinoAdapter.parseTorrents(String(decoding: data, as: UTF8.self)); if self.torrents.isEmpty { self.findPlannedFilm() } else { self.tableURL = self.web.url } } catch { self.error = "Не удалось прочитать таблицу раздач: " + error.localizedDescription }
        }
    }
    private func findPlannedFilm() {
        guard let film = expectedFilm else { return }
        web.evaluateJavaScript(UAKinoAdapter.searchScript) { [weak self] value, _ in
            guard let self, let json = value as? String, let rows = try? JSONDecoder().decode([UAKinoAdapter.SearchResult].self, from: Data(json.utf8)) else { return }
            if let url = UAKinoAdapter.match(rows, film: film), self.automaticNavigation.insert(url.absoluteString).inserted {
                self.web.load(URLRequest(url: url)); return
            }
            self.web.evaluateJavaScript(UAKinoAdapter.downloadLinkScript) { [weak self] value, _ in
                guard let self, let link = value as? String, let url = URL(string: link), url.scheme == "https", url.host == "uakino.best",
                      self.automaticNavigation.insert(url.absoluteString).inserted else { return }
                self.web.load(URLRequest(url: url))
            }
        }
    }
    func download(_ torrent: FilmTorrent) {
        guard !isObtainingTorrent, UAKinoAdapter.validTorrentURL(torrent.url) else { return }
        error = nil; files = []; downloadedTorrent = nil
        isObtainingTorrent = true; downloadMessage = "Сайт готовит ссылку на торрент…"
        OperationJournal.shared.append("Получаю торрент: " + torrent.title)
        if let tableURL, web.url != tableURL {
            pendingTableSelection = torrent; web.load(URLRequest(url: tableURL)); return
        }
        clickSiteRelease(torrent)
    }
    private func clickSiteRelease(_ torrent: FilmTorrent) {
        // Use the site's own click handler: it submits the selected release and
        // starts its normal countdown. A plain GET returns the home page.
        let encoded = String(data: try! JSONEncoder().encode(torrent.url.absoluteString), encoding: .utf8)!
        let script = "(() => { const link = Array.from(document.querySelectorAll('a[href]')).find(a => a.href === " + encoded + "); if (!link) return false; link.click(); return true; })()"
        web.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error { self.isObtainingTorrent = false; self.error = error.localizedDescription }
            else if value as? Bool != true { self.isObtainingTorrent = false; self.error = "Страница раздач изменилась. Откройте её заново." }
        }
    }
    private func waitForFileLink() {
        linkPolling?.cancel()
        linkPolling = Task { @MainActor [weak self] in
            for second in 0..<60 {
                guard !Task.isCancelled, let self, self.isObtainingTorrent else { return }
                if let value = try? await self.web.evaluateJavaScript(UAKinoAdapter.finalTorrentScript),
                   let link = value as? String, let url = URL(string: link), UAKinoAdapter.validFileURL(url) {
                    var request = URLRequest(url: url)
                    request.setValue(self.web.url?.absoluteString, forHTTPHeaderField: "Referer")
                    self.downloadMessage = "Получаю файл торрента…"
                    self.web.startDownload(using: request) { [weak self] download in download.delegate = self }
                    return
                }
                self.downloadMessage = "Ожидаю ссылку сайта · \(second + 1) с"
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self else { return }
            self.isObtainingTorrent = false; self.error = "Сайт не выдал торрент за минуту. Откройте страницу сайта и повторите выбор раздачи."
            OperationJournal.shared.append(self.error ?? "", level: .warning)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) { decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false, scheme == "https", url.host == "challenges.cloudflare.com" { decisionHandler(.allow); return }
        if scheme == "https", url.host == "uakino.best" {
            decisionHandler(UAKinoAdapter.validFileURL(url) ? .download : .allow)
        } else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(UUID().uuidString + ".torrent")
            downloadedTorrent = url; completionHandler(url)
        } catch { self.error = error.localizedDescription; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        isObtainingTorrent = false; linkPolling?.cancel()
        guard let url = downloadedTorrent else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.first == 100 else { throw EssayReleaseError.invalid("Сайт вернул веб-страницу вместо торрента. Повторите штатный выбор раздачи после проверки сайта.") }
            files = try TorrentManifest.files(data).filter { ["mp4", "mkv", "avi", "mov", "webm", "m4v"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
            guard let largest = files.max(by: { $0.bytes < $1.bytes }) else { throw TorrentManifest.invalid }
            selectedFile = largest.index
            OperationJournal.shared.append("Торрент получен: видеофайлов \(files.count)")
        } catch { self.error = error.localizedDescription }
    }
    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) { isObtainingTorrent = false; linkPolling?.cancel(); self.error = error.localizedDescription }
}

struct FilmTorrentBrowser: View {
    let film: PlannedFilm
    let workingDirectory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var showWebsite = false
    @State private var model: FilmTorrentBrowserModel
    init(film: PlannedFilm, workingDirectory: URL) {
        self.film = film; self.workingDirectory = workingDirectory
        _model = State(initialValue: FilmTorrentBrowserModel(folder: workingDirectory.appendingPathComponent("films/.incoming")))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("\(film.title) · \(film.year)").font(.title2); Spacer(); Button("Закрыть") { dismiss() } }
            Text("Проверьте название и год, откройте фильм, затем «Скачати торенти». Выберите раздачу по размеру и качеству.").font(.callout).foregroundStyle(.secondary)
            if model.isLoading { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if model.isObtainingTorrent { ProgressView(model.downloadMessage).controlSize(.small) }
            if !model.torrents.isEmpty {
                Toggle("Показать страницу сайта", isOn: $showWebsite).font(.caption)
            }
            FilmWebsite(web: model.web)
                .frame(height: model.torrents.isEmpty || showWebsite ? 380 : 1)
                .opacity(model.torrents.isEmpty || showWebsite ? 1 : 0)
                .accessibilityHidden(!model.torrents.isEmpty && !showWebsite)
            if !model.torrents.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.torrents) { torrent in
                        HStack {
                            VStack(alignment: .leading) { Text(torrent.title).font(.callout); if UAKinoAdapter.recommended(model.torrents, availableBytes: try? workingDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) == torrent.id { Text("Рекомендуется: украинская дорожка, доступная раздача, размер с учётом места").font(.caption2).foregroundStyle(StudioTheme.accent) }; Text("\(torrent.size) · сиды: \(torrent.seeds.map(String.init) ?? "—") · пиры: \(torrent.peers.map(String.init) ?? "—")").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("Выбрать") { model.download(torrent) }.disabled(model.isObtainingTorrent)
                        }
                    }
                } }.frame(maxHeight: .infinity)
            }
            if !model.files.isEmpty {
                Picker("Видеофайл", selection: $model.selectedFile) { ForEach(model.files) { file in Text(file.path + " · " + ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).tag(file.index) } }
                Button("Скачать в films и подготовить MP4") {
                    guard let torrent = model.downloadedTorrent, let file = model.files.first(where: { $0.index == model.selectedFile }) else { return }
                    do { try FilmLibrary.shared.enqueue(film: film, torrent: torrent, file: file, workingDirectory: workingDirectory); dismiss() } catch { model.error = error.localizedDescription }
                }.buttonStyle(StudioPrimaryButtonStyle())
            }
            OperationLogPanel(isActive: model.isLoading || model.isObtainingTorrent)
        }.padding(20).frame(width: 1060, height: 800).onAppear { model.search(film) }
    }
}
private struct FilmWebsite: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PlannedFilmsStartPanel: View {
    @State private var library = FilmLibrary.shared
    @State private var query = ""
    let onChoose: (PlannedFilm?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Фильмы из плана эссе", systemImage: "list.bullet.rectangle").font(.headline)
                    Text("\(library.films.count) фильмов · выполнено \(library.completed.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Найти фильм", text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Все загрузки", systemImage: "arrow.down.circle") { onChoose(nil) }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(library.films.filter { query.isEmpty || ($0.title + $0.topic).localizedCaseInsensitiveContains(query) }) { film in
                        HStack {
                            Image(systemName: library.completed.contains(film.id) ? "checkmark.circle.fill" : "film")
                                .foregroundStyle(library.completed.contains(film.id) ? Color.green : StudioTheme.accent)
                            Text("\(film.number). \(film.title) · \(film.year)").font(.callout.weight(.medium))
                            Spacer()
                            if library.completed.contains(film.id) { Text("Эссе выполнено").font(.caption).foregroundStyle(.secondary) }
                            Button("Скачать") { onChoose(film) }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
            }.frame(height: 180)
        }.studioPanel(padding: 18)
    }
}
