import SwiftUI

struct YouTubeSearchView: View {
    let onVideoReady: (URL, VideoSourceMetadata?) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var query = "Lineage 2 Scryde"
    @State private var directURL = ""
    @State private var results: [YouTubeSearchResult] = []
    @State private var selectedResult: YouTubeSearchResult?
    @State private var isSearching = false
    @State private var isDownloading = false
    @State private var isDirectDownloading = false
    @State private var downloadStatus: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?

    private let service = YouTubeImportService()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 7) {
                Text("Find a YouTube video")
                    .font(.title2.weight(.semibold))

                Text("Search fresh videos by topic, download one, then edit it with the normal shorts flow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Showing videos from \(settings.youtubeMinDurationMinutes) to \(settings.youtubeMaxDurationMinutes) minutes, newest first.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            searchBar
            directURLBar

            if let downloadStatus {
                Label(downloadStatus, systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
                    .textSelection(.enabled)
            }

            resultsList
        }
        .frame(maxWidth: 760)
    }

    private var searchBar: some View {
        let minBinding = Binding(
            get: { settings.youtubeMinDurationMinutes },
            set: { settings.youtubeMinDurationMinutes = $0 }
        )
        let maxBinding = Binding(
            get: { settings.youtubeMaxDurationMinutes },
            set: { settings.youtubeMaxDurationMinutes = $0 }
        )

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search query", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }

                Button {
                    search()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(isSearching || isDownloading || query.trimmed.isEmpty)
            }
            .controlSize(.large)

            HStack(spacing: 12) {
                Text("Min:")
                    .foregroundStyle(.secondary)
                Stepper("\(settings.youtubeMinDurationMinutes) min", value: minBinding, in: 5...max(settings.youtubeMaxDurationMinutes - 1, 5), step: 5)

                Text("Max:")
                    .foregroundStyle(.secondary)
                Stepper("\(settings.youtubeMaxDurationMinutes) min", value: maxBinding, in: min(settings.youtubeMinDurationMinutes + 1, 300)...300, step: 5)
            }
            .font(.caption)
        }
    }

    private var resultsList: some View {
        VStack(spacing: 10) {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching YouTube…")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 150)
            } else if results.isEmpty {
                VStack(spacing: 8) {
                    Text("Try Lineage 2 Scryde, Lineage 2 Lu4 or Lineage 2 Force-play.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 330)
            }
        }
    }

    private func resultRow(_ result: YouTubeSearchResult) -> some View {
        let isSelected = selectedResult == result

        return Button {
            selectedResult = result
            download(result)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(result.metadata)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if isDownloading && isSelected {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDownloading || isDirectDownloading)
    }

    private var directURLBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 2)

            Text("Or paste a direct video link")
                .font(.callout.weight(.semibold))

            HStack(spacing: 10) {
                TextField("https://youtube.com/watch?v=… or https://youtube.com/shorts/…",
                          text: $directURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { downloadDirectURL() }

                Button {
                    downloadDirectURL()
                } label: {
                    if isDirectDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Download link", systemImage: "link.badge.plus")
                    }
                }
                .disabled(isSearching || isDownloading || isDirectDownloading || directURL.trimmed.isEmpty)

                if isDirectDownloading {
                    Button("Cancel", role: .destructive) {
                        cancelDownload()
                    }
                }
            }
            .controlSize(.large)

            Text("Works with Shorts and full videos. Short videos open as one editable short; longer videos go through moment finding.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func search() {
        guard !query.trimmed.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        selectedResult = nil

        let searchQuery = query
        searchTask = Task {
            do {
                let foundResults = try await service.search(query: searchQuery, minDurationMinutes: settings.youtubeMinDurationMinutes, maxDurationMinutes: settings.youtubeMaxDurationMinutes)
                guard !Task.isCancelled else { return }
                results = foundResults
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            isSearching = false
        }
    }

    private func download(_ result: YouTubeSearchResult) {
        isDownloading = true
        errorMessage = nil
        downloadStatus = "Downloading video…"

        downloadTask = Task {
            do {
                await service.setCookiesPath(settings.youtubeCookiesPath)
                async let metadata = service.sourceMetadata(for: result)
                async let downloadedURL = service.download(result, outputDirectory: settings.outputDirectory) { progress in
                    await MainActor.run { downloadStatus = progress.label }
                }
                let url = try await downloadedURL
                downloadStatus = "Opening editor…"
                let sourceMetadata = await metadata
                onVideoReady(url, sourceMetadata)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
            downloadStatus = nil
            downloadTask = nil
        }
    }

    private func downloadDirectURL() {
        guard !directURL.trimmed.isEmpty else { return }
        isDirectDownloading = true
        errorMessage = nil
        downloadStatus = "Reading link and downloading video…"
        selectedResult = nil

        let urlString = directURL
        downloadTask = Task {
            do {
                await service.setCookiesPath(settings.youtubeCookiesPath)
                // Use a single yt-dlp call that both downloads the video and
                // writes metadata to .info.json — avoids a race condition where
                // a parallel --dump-single-json process could fail or timeout
                // while the download is in progress, leaving title/description empty.
                let (url, metadata) = try await service.downloadDirectURLWithMetadata(
                    urlString,
                    outputDirectory: settings.outputDirectory
                ) { progress in
                    await MainActor.run { downloadStatus = progress.label }
                }
                downloadStatus = "Opening editor…"
                onVideoReady(url, metadata)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDirectDownloading = false
            downloadStatus = nil
            downloadTask = nil
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        Task { await service.cancelDownload() }
        downloadStatus = "Cancelling download…"
    }
}
