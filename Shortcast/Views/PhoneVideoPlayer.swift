import AVKit
import SwiftUI

/// A silent, looping video view with no playback controls — used as the
/// background of the phone-style post previews.
struct PhoneVideoPlayer: NSViewRepresentable {

    let url: URL
    /// How the video fills its frame. Defaults to `.resizeAspect` so that
    /// square (1:1) and non-9:16 shorts are shown in full without cropping.
    /// Callers can override to `.resizeAspectFill` when a crop-fill is desired.
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// Optional trim window (seconds) — the loop plays only [trimStart, trimEnd]
    /// so the preview matches what the manual trim will export. `trimEnd <= 0`
    /// means "until the end".
    var trimStart: Double = 0
    var trimEnd: Double = 0

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = gravity

        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        context.coordinator.player = queue
        context.coordinator.rebuildLooper(url: url, trimStart: trimStart, trimEnd: trimEnd)
        view.player = queue
        queue.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Rebuild the loop if the trim window changed.
        context.coordinator.rebuildLooperIfNeeded(url: url, trimStart: trimStart, trimEnd: trimEnd)
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        coordinator.player?.removeAllItems()
        coordinator.player?.replaceCurrentItem(with: nil)
        coordinator.player = nil
        nsView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        private var currentTrim: (Double, Double)?

        func rebuildLooperIfNeeded(url: URL, trimStart: Double, trimEnd: Double) {
            if let current = currentTrim, current == (trimStart, trimEnd) { return }
            rebuildLooper(url: url, trimStart: trimStart, trimEnd: trimEnd)
        }

        func rebuildLooper(url: URL, trimStart: Double, trimEnd: Double) {
            guard let player else { return }
            looper?.disableLooping()
            let item = AVPlayerItem(url: url)
            // Only loop a sub-range when both a start and a real end are set.
            if trimEnd > trimStart + 0.1 {
                let start = CMTime(seconds: max(0, trimStart), preferredTimescale: 600)
                let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
                looper = AVPlayerLooper(
                    player: player, templateItem: item,
                    timeRange: CMTimeRange(start: start, end: end))
            } else {
                looper = AVPlayerLooper(player: player, templateItem: item)
            }
            currentTrim = (trimStart, trimEnd)
            player.play()
        }
    }
}
