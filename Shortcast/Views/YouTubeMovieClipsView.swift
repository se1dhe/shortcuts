import SwiftUI

/// Trending Russian movie-cut YouTube Shorts grid.
/// Uses YouTube Data API v3 for reliable Shorts discovery.
struct YouTubeMovieClipsView: View {
    let onVideoReady: (URL, VideoSourceMetadata?) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(MovieShortsBrowserModel.self) private var browser
    @State private var searchQueries = ""
    @State private var selectedForPlayback: YouTubeSearchResult?
    @State private var showHistory = false

    // Grid state lives in the shared browser model so it survives navigation.
    private var results: [YouTubeSearchResult] { browser.results }
    private var isLoading: Bool { browser.isLoading }
    private var downloadingID: String? { browser.downloadingID }
    private var errorMessage: String? { browser.errorMessage }

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .textSelection(.enabled)
                Divider()
            }

            if settings.youtubeAPIKey.trimmed.isEmpty {
                missingKeyView
            } else {
                resultsGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            searchQueries = settings.movieShortsSearchQueries
            // Only load on first appearance — returning from a processed clip
            // keeps the already-loaded grid.
            if !browser.hasLoaded {
                await load()
            }
        }
        .onChange(of: settings.movieShortsSearchQueries) { _, newValue in
            if searchQueries != newValue {
                searchQueries = newValue
            }
        }
        .sheet(item: $selectedForPlayback) { result in
            YouTubePlayerView(result: result)
        }
        .sheet(isPresented: $showHistory) {
            ProcessedVideoHistoryView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                Image(systemName: "film")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Trending movie shorts")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    statChip(count: results.count, symbol: "rectangle.stack")
                }

                searchQueryEditor
            }

            Spacer()

            Button {
                showHistory = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.large)

            Button {
                Task { await load(forceRefresh: true) }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isLoading || settings.youtubeAPIKey.trimmed.isEmpty)
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func statChip(count: Int, symbol: String) -> some View {
        Label(String(format: String(localized: "%d shorts"), count), systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    private var searchQueryEditor: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 28)

            TextEditor(text: $searchQueries)
                .font(.caption)
                .scrollContentBackground(.hidden)
                .frame(minWidth: 360, maxWidth: 560, minHeight: 58, maxHeight: 58)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .onChange(of: searchQueries) { _, newValue in
                    settings.movieShortsSearchQueries = newValue
                }
                .help("One YouTube search query per line")
        }
    }

    // MARK: - Missing API key prompt

    private var missingKeyView: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "key.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            Text("YouTube Data API key required")
                .font(.title3.weight(.semibold))

            Text("A free API key lets the app search trending Russian movie Shorts directly via YouTube.\n\n1. Go to Google Cloud Console → APIs & Services → Credentials.\n2. Create an API key and enable the YouTube Data API v3.\n3. Paste the key in Settings below.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            SettingsLink {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Results grid

    private var resultsGrid: some View {
        ScrollView {
            if results.isEmpty && !isLoading {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(results) { result in
                        clipTile(result)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No movie shorts found. Try refreshing.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 300)
        .padding(.vertical, 40)
    }

    // MARK: - Tile

    private func clipTile(_ result: YouTubeSearchResult) -> some View {
        let isDownloading = downloadingID == result.id

        return VStack(alignment: .leading, spacing: 10) {
            phoneArea(result, isDownloading: isDownloading)
            footer(result)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
    }

    private func phoneArea(_ result: YouTubeSearchResult, isDownloading: Bool) -> some View {
        ZStack {
            MiniThumbnailPhone(videoID: result.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedForPlayback = result
                }

            overlays(result, isDownloading: isDownloading)
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(Rectangle())
    }

    private func overlays(_ result: YouTubeSearchResult, isDownloading: Bool) -> some View {
        VStack {
            HStack(alignment: .top) {
                Text(String(format: String(localized: "%ds"), Int(result.durationSeconds.rounded())))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    skip(result)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .help("Skip forever")
            }

            Spacer()

            HStack(spacing: 10) {
                actionButton("play.fill", "Play") {
                    selectedForPlayback = result
                }
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    actionButton("arrow.down.circle", "Download") {
                        Task { await process(result) }
                    }
                }
            }
            .padding(6)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .padding(10)
    }

    private func actionButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func footer(_ result: YouTubeSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(result.channel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    // MARK: - Load / Process

    private func load(forceRefresh: Bool = false) async {
        guard !isLoading, !settings.youtubeAPIKey.trimmed.isEmpty else { return }
        browser.isLoading = true
        browser.errorMessage = nil
        settings.movieShortsSearchQueries = searchQueries
        do {
            let found = try await YouTubeAPIService.searchShorts(
                apiKey: settings.youtubeAPIKey,
                queries: searchQueriesList,
                limit: 100,
                excludedIDs: settings.processedMovieClipIDs,
                forceRefresh: forceRefresh
            )
            browser.results = found
            browser.hasLoaded = true
        } catch {
            browser.errorMessage = error.localizedDescription
        }
        browser.isLoading = false
    }

    private var searchQueriesList: [String] {
        searchQueries
            .components(separatedBy: .newlines)
            .map(\.trimmed)
            .filter { !$0.isEmpty }
    }

    private func process(_ result: YouTubeSearchResult) async {
        let service = YouTubeImportService()
        await service.setCookiesPath(settings.youtubeCookiesPath)
        browser.downloadingID = result.id
        defer { browser.downloadingID = nil }

        do {
            // Download and metadata fetch are independent — run them together.
            async let downloadedURL = service.download(
                result,
                outputDirectory: settings.outputDirectory)
            async let fetchedMetadata = service.sourceMetadata(for: result)
            let url = try await downloadedURL
            let metadata = await fetchedMetadata

            var ids = settings.processedMovieClipIDs
            ids.insert(result.id)
            settings.processedMovieClipIDs = ids
            browser.remove(id: result.id)

            // Remember we came from recommendations so results can offer a
            // "Back to shorts" button.
            browser.cameFromRecommendations = true
            browser.selectedTab = .shorts

            onVideoReady(url, metadata)
        } catch {
            browser.errorMessage = error.localizedDescription
        }
    }

    private func skip(_ result: YouTubeSearchResult) {
        var ids = settings.processedMovieClipIDs
        ids.insert(result.id)
        settings.processedMovieClipIDs = ids

        withAnimation(.smooth(duration: 0.18)) {
            browser.remove(id: result.id)
        }
    }
}

// MARK: - Mini phone frame (identical to ShortClipTile.MiniPhone)

private struct MiniThumbnailPhone: View {
    let videoID: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let radius = w * 0.15
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.03)],
                        startPoint: .top, endPoint: .bottom))

                Color.black
                    .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                    .padding(3)

                ThumbnailImage(videoID: videoID)
                    .frame(width: max(w - 6, 0), height: max(h - 6, 0))
                    .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
            }
        }
    }
}

// MARK: - Max-quality thumbnail with fallback

private struct ThumbnailImage: View {
    let videoID: String
    @State private var url: URL

    init(videoID: String) {
        self.videoID = videoID
        _url = State(initialValue: URL(string: "https://img.youtube.com/vi/\(videoID)/maxresdefault.jpg")!)
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else if phase.error != nil {
                Color.clear.onAppear {
                    fallback()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
    }

    private func fallback() {
        let path = url.absoluteString
        if path.contains("maxresdefault") {
            url = URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")!
        } else if path.contains("hqdefault") {
            url = URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg")!
        }
    }
}
