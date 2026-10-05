import Foundation
import AVFoundation

/// Протокол сервиса бесшовного мягкого зацикливания фонового саундтрека (SOLID: ISP & DIP).
public protocol SeamlessAudioLooping: Sendable {
    /// Создает зацикленную аудиодорожку с мягким акустическим кроссфейдом (equal-power) на стыках,
    /// делая повторы музыки незаметными и плавными на всей протяженности видео.
    func createSeamlessLoop(
        sourceURL: URL,
        targetDuration: Double,
        crossfadeDuration: Double
    ) async throws -> URL
}

/// Сервис бесшовного зацикливания музыки для кино-эссе Shortcast Cinema (SOLID: SRP).
/// Использует психоакустический quarter-sine crossfade (`acrossfade=c1=qsin:c2=qsin`),
/// сохраняющий постоянную мощность и избавляющий от щелчков, пауз и резких смен гармонии.
public final class SeamlessAudioLoopService: SeamlessAudioLooping, Sendable {

    public static let shared = SeamlessAudioLoopService()

    private let processRunner: any ProcessRunning

    public init(processRunner: any ProcessRunning = ProcessRunner.shared) {
        self.processRunner = processRunner
    }

    public func createSeamlessLoop(
        sourceURL: URL,
        targetDuration: Double,
        crossfadeDuration: Double = 4.0
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return sourceURL
        }

        let asset = AVURLAsset(url: sourceURL)
        let assetDuration: Double
        if let d = try? await asset.load(.duration) {
            assetDuration = d.seconds
        } else {
            assetDuration = 0.0
        }

        // Если исходный трек длиннее или равен требуемой длительности видео, зацикливание не требуется
        if assetDuration >= targetDuration || assetDuration <= 5.0 {
            return sourceURL
        }

        // Вычисляем эффективную длину одного цикла с учетом нахлеста кроссфейда
        let actualCrossfade = min(crossfadeDuration, assetDuration * 0.25)
        let effectiveStep = max(1.0, assetDuration - actualCrossfade)
        let remainingNeeded = max(0.0, targetDuration - assetDuration)
        let loopsCount = Int(ceil(remainingNeeded / effectiveStep)) + 1

        guard loopsCount > 1 else {
            return sourceURL
        }

        // Директория кэша сгенерированных бесшовных лупов
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeamlessAudioLoops", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let safeName = sourceURL.deletingPathExtension().lastPathComponent
        let targetSecInt = Int(ceil(targetDuration))
        let crossfadeInt = Int(actualCrossfade * 10)
        let outputFileName = "loop_\(safeName)_\(targetSecInt)s_xf\(crossfadeInt).m4a"
        let outputURL = cacheDir.appendingPathComponent(outputFileName)

        // Проверяем существующий готовый кэш
        if FileManager.default.fileExists(atPath: outputURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? UInt64, size > 1024 {
            return outputURL
        }

        // Ищем бинарник ffmpeg
        guard let ffmpegURL = resolveFFmpegBinary() else {
            // Если ffmpeg недоступен, возвращаем исходный URL (fallback)
            return sourceURL
        }

        // Формируем цепочку acrossfade
        var arguments: [String] = ["-y"]
        for _ in 0..<loopsCount {
            arguments.append(contentsOf: ["-i", sourceURL.path])
        }

        var filterParts: [String] = []
        if loopsCount == 2 {
            filterParts.append("[0:a][1:a]acrossfade=d=\(String(format: "%.2f", actualCrossfade)):c1=qsin:c2=qsin[out]")
        } else {
            filterParts.append("[0:a][1:a]acrossfade=d=\(String(format: "%.2f", actualCrossfade)):c1=qsin:c2=qsin[a1]")
            for i in 1..<(loopsCount - 1) {
                let currentIn = "a\(i)"
                let nextTrack = "\(i + 1):a"
                let nextOut = (i == loopsCount - 2) ? "out" : "a\(i + 1)"
                filterParts.append("[\(currentIn)][\(nextTrack)]acrossfade=d=\(String(format: "%.2f", actualCrossfade)):c1=qsin:c2=qsin[\(nextOut)]")
            }
        }

        let filterComplex = filterParts.joined(separator: ";")
        arguments.append(contentsOf: [
            "-filter_complex", filterComplex,
            "-map", "[out]",
            "-c:a", "aac",
            "-b:a", "192k",
            outputURL.path
        ])

        do {
            let result = try await processRunner.run(executableURL: ffmpegURL, arguments: arguments, environment: nil)
            if result.isSuccess && FileManager.default.fileExists(atPath: outputURL.path) {
                return outputURL
            }
        } catch {
            // При ошибке возвращаем исходный URL
            return sourceURL
        }

        return sourceURL
    }

    private func resolveFFmpegBinary() -> URL? {
        if let bin = BinaryDownloadService.resolveBinary("ffmpeg", workingDirectory: nil) {
            return bin
        }
        let commonPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
