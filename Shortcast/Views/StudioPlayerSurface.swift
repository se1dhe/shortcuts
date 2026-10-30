import AVFoundation
import AppKit
import SwiftUI

/// A minimal AVPlayerLayer host. Unlike SwiftUI VideoPlayer this avoids AVKit's
/// chapter/remote-command controller path, which is where the Oct 30 playback
/// crash entered AVPlayerController before AudioQueueStart trapped.
struct StudioPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView(frame: .zero)
        view.wantsLayer = true
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerLayerHostView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct FullscreenEssayPlayerView: View {
    let player: AVPlayer
    let duration: Double
    let onClose: () -> Void

    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            StudioPlayerSurface(player: player).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Label("Выйти из полного экрана", systemImage: "xmark")
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                Spacer()
                controls
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
            ) { time in
                let seconds = CMTimeGetSeconds(time)
                Task { @MainActor in
                    if seconds.isFinite { currentTime = max(0, min(seconds, duration)) }
                    isPlaying = player.timeControlStatus == .playing
                }
            }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            onClose()
        }
        .onExitCommand(perform: onClose)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.accent)

            Text(format(currentTime))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Slider(value: Binding(get: { currentTime }, set: { value in
                currentTime = value
                player.seek(to: CMTime(seconds: value, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
            }), in: 0...max(duration, 0.1))
                .tint(StudioTheme.accent)
            Text(format(duration))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
