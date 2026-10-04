import Foundation
import AVFoundation
import Observation

/// Контроллер предпрослушивания аудиодорожек (SOLID: SRP, Observer pattern).
/// Управляет воспроизведением, регулировкой громкости в реальном времени и очисткой ресурсов.
@Observable
@MainActor
public final class AudioPreviewController {

    public private(set) var isPlaying: Bool = false
    public private(set) var currentlyPlayingURL: URL? = nil

    private var player: AVPlayer?
    private var finishObserver: NSObjectProtocol?

    public init() {}

    /// Запуск воспроизведения аудиофайла по URL с заданной громкостью
    public func play(url: URL, volume: Float) {
        stop()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = max(0.0, min(1.0, volume))
        self.player = newPlayer
        self.currentlyPlayingURL = url
        self.isPlaying = true

        finishObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }

        newPlayer.play()
    }

    /// Приостановка воспроизведения
    public func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Полная остановка и сброс плеера
    public func stop() {
        if let finishObserver {
            NotificationCenter.default.removeObserver(finishObserver)
            self.finishObserver = nil
        }
        player?.pause()
        player = nil
        currentlyPlayingURL = nil
        isPlaying = false
    }

    /// Переключение воспроизведения (Play / Pause / Switch track)
    public func toggle(url: URL?, volume: Float) {
        guard let url else {
            stop()
            return
        }

        if isPlaying {
            if currentlyPlayingURL == url {
                stop()
            } else {
                play(url: url, volume: volume)
            }
        } else {
            play(url: url, volume: volume)
        }
    }

    /// Обновление громкости текущего воспроизведения в реальном времени
    public func updateVolume(_ volume: Float) {
        player?.volume = max(0.0, min(1.0, volume))
    }
}
