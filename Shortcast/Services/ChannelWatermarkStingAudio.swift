import AVFoundation
import Foundation

/// Синтезированный звук появления вотермарк-карточки: мягкий восходящий whoosh
/// и короткий шиммер. Файл создаётся один раз и вставляется в композицию в те же
/// моменты, что и анимация, поэтому звук и кадр не могут разъехаться.
enum ChannelWatermarkStingAudio {
    static let sampleRate: Double = 48_000
    static let duration: Double = 1.6
    /// Пик ниже половины шкалы: стинг живёт поверх речи и музыки, его не нормализуют отдельно.
    static let peak: Float = 0.32

    nonisolated(unsafe) private static var cachedURL: URL?
    private static let lock = NSLock()

    /// Готовит `.caf` в кэше приложения. Один файл на все стинги одного эссе.
    static func makeFile() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedURL, FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Shortcast", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("channel-watermark-sting.caf")

        do {
            try write(samples(), to: url)
            cachedURL = url
            return url
        } catch {
            return nil
        }
    }

    /// Детерминированный сигнал: белый шум через поднимающийся фильтр (whoosh)
    /// плюс три затухающих партиала (шиммер) поверх низкого тела.
    static func samples() -> [Float] {
        let count = Int(sampleRate * duration)
        guard count > 0 else { return [] }

        var mix = [Float](repeating: 0, count: count)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        var lowPass: Float = 0

        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((seed >> 40) & 0xFF_FFFF) / Float(0x7F_FFFF) - 1
        }

        let partials: [(frequency: Float, amplitude: Float)] = [
            (1318.5, 0.16),
            (1975.5, 0.10),
            (2637.0, 0.06)
        ]

        for index in 0..<count {
            let time = Double(index) / sampleRate

            // Whoosh: фильтр открывается вверх, огибающая — половина синуса.
            let whooshTime = Float(min(time / 0.95, 1))
            let cutoff = Float(300 + 5200 * Double(whooshTime * whooshTime))
            let alpha = Float(1 - exp(-2 * Double.pi * Double(cutoff) / sampleRate))
            lowPass += alpha * (noise() - lowPass)
            let whoosh = lowPass * sin(.pi * whooshTime) * 0.55

            // Шиммер: колокольчики входят после 0,28 с и гаснут к концу.
            var shimmer: Float = 0
            if time > 0.28 {
                let bellTime = Float(time - 0.28)
                let envelope = exp(-3.4 * bellTime) * (1 - exp(-22 * bellTime))
                for partial in partials {
                    shimmer += sin(2 * .pi * partial.frequency * bellTime)
                        * partial.amplitude * envelope
                }
            }

            // Низкое тело — только в начале, чтобы whoosh не звучал как шорох бумаги.
            let body = time < 0.9
                ? sin(2 * .pi * 92 * Float(time)) * Float(exp(-4.0 * time)) * 0.12
                : 0

            mix[index] = whoosh + shimmer + body
        }

        let fadeIn = max(1, Int(0.012 * sampleRate))
        let fadeOut = max(1, Int(0.18 * sampleRate))
        for index in 0..<fadeIn {
            mix[index] *= Float(index) / Float(fadeIn)
        }
        for index in 0..<fadeOut {
            mix[count - 1 - index] *= Float(index) / Float(fadeOut)
        }

        let maxAbs = mix.reduce(Float(0)) { max($0, abs($1)) }
        if maxAbs > 0 {
            let gain = peak / maxAbs
            for index in 0..<count {
                mix[index] *= gain
            }
        }
        return mix
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              )
        else {
            throw NSError(
                domain: "ChannelWatermarkStingAudio",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать аудиоформат стинга."]
            )
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
