import AVKit
import SwiftUI

/// A native video player sheet that streams a YouTube Short via yt-dlp.
struct YouTubePlayerView: View {
    let result: YouTubeSearchResult

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(result.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if let errorMessage {
                Spacer()
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Spacer()
            } else if let player {
                PlayerContainerView(player: player)
            } else {
                ProgressView("Loading video…")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 480)
        .task { await loadStream() }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private func loadStream() async {
        let service = YouTubeImportService()
        await service.setCookiesPath(settings.youtubeCookiesPath)
        do {
            let url = try await service.streamURL(for: result)
            player = AVPlayer(url: url)
            player?.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .default
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
