import AVKit
import SwiftUI

/// Preserve playback while upload progress and publication receipts update.
struct StudioVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) {
                player?.pause()
                let next = AVPlayer(url: url)
                player = next
                // The rendered files open with a brief dip from black. Preview
                // an actual frame rather than present an apparently empty file.
                await next.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
            }
            .onDisappear { player?.pause() }
    }
}
