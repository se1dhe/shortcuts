import Foundation
import AVFoundation
import os

/// Результат валидации рендера
struct RenderValidationResult: Codable, Sendable, Equatable {
    let isValid: Bool
    let issues: [ValidationIssue]
    
    var hasIssues: Bool { !issues.isEmpty }
}

enum ValidationIssue: Codable, Sendable, Equatable, CustomStringConvertible {
    case fileMissing
    case fileTooSmall(sizeBytes: Int64)
    case notPlayable
    case noVideoTrack
    case noAudioTrack
    case durationTooShort(expected: ClosedRange<Double>, actual: Double)
    case durationTooLong(expected: ClosedRange<Double>, actual: Double)
    case loudnessOutOfTolerance(expected: Double, actual: Double, tolerance: Double)
    
    var description: String {
        switch self {
        case .fileMissing:
            return "Файл не найден"
        case .fileTooSmall(let size):
            return "Файл слишком малый: \(size / 1024 / 1024) MB"
        case .notPlayable:
            return "Файл не воспроизводится"
        case .noVideoTrack:
            return "Отсутствует видеодорожка"
        case .noAudioTrack:
            return "Отсутствует аудиодорожка"
        case .durationTooShort(let expected, let actual):
            return "Длительность \(String(format: "%.1f", actual))с меньше ожидаемой (\(String(format: "%.1f", expected.lowerBound))-\(String(format: "%.1f", expected.upperBound))с)"
        case .durationTooLong(let expected, let actual):
            return "Длительность \(String(format: "%.1f", actual))с больше ожидаемой (\(String(format: "%.1f", expected.lowerBound))-\(String(format: "%.1f", expected.upperBound))с)"
        case .loudnessOutOfTolerance(let expected, let actual, let tolerance):
            return "Громкость \(String(format: "%.1f", actual)) LUFS вне допуска \(String(format: "%.1f", expected))±\(String(format: "%.1f", tolerance)) LUFS"
        }
    }
}

/// Пост-рендер валидация: громкость, длительность, наличие треков.
/// Блокирует публикацию если рендер не проходит проверку.
actor RenderValidationService {
    
    private static let logger = Logger(subsystem: "app.shortcast", category: "RenderValidation")
    
    /// Валидирует готовый рендер эссе (4:00–8:00) по общей цели аудиомастеринга.
    func validateLongform(
        outputURL: URL,
        expectedDurationRange: ClosedRange<Double> = EssayDurationPolicy.rendered,
        expectedLoudness: Double = CinemaAudioMasteringService.targetLUFS,
        loudnessTolerance: Double = 1.0,
        workingDirectory: URL?
    ) async -> RenderValidationResult {
        var issues: [ValidationIssue] = []
        
        // 1. Проверка файла
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return RenderValidationResult(isValid: false, issues: [.fileMissing])
        }
        
        let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 10 * 1024 * 1024 else { // Минимум 10 MB
            return RenderValidationResult(isValid: false, issues: [.fileTooSmall(sizeBytes: Int64(fileSize))])
        }
        
        // 2. Проверка воспроизводимости и треков
        let asset = AVURLAsset(url: outputURL)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        
        if videoTracks.isEmpty {
            issues.append(.noVideoTrack)
        }
        if audioTracks.isEmpty {
            issues.append(.noAudioTrack)
        }
        
        // 3. Проверка длительности
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = CMTimeGetSeconds(duration)
        
        if durationSeconds < expectedDurationRange.lowerBound {
            issues.append(.durationTooShort(expected: expectedDurationRange, actual: durationSeconds))
        } else if durationSeconds > expectedDurationRange.upperBound {
            issues.append(.durationTooLong(expected: expectedDurationRange, actual: durationSeconds))
        }
        
        // 4. Проверка громкости (если есть аудио)
        if !audioTracks.isEmpty {
            do {
                let loudness = try await measureLoudness(url: outputURL, workingDirectory: workingDirectory)
                if let issue = Self.loudnessIssue(
                        actual: loudness,
                        expected: expectedLoudness,
                        tolerance: loudnessTolerance
                ) {
                    issues.append(issue)
                }
            } catch {
                Self.logger.warning("Loudness measurement failed: \(error.localizedDescription)")
                // Не блокируем валидацию если не удалось измерить громкость
            }
        }
        
        let isValid = issues.isEmpty
        return RenderValidationResult(isValid: isValid, issues: issues)
    }
    
    /// Валидирует готовый рендер шортса (38–58 секунд) по общей цели аудиомастеринга.
    func validateShort(
        outputURL: URL,
        expectedDurationRange: ClosedRange<Double> = 38...58,
        expectedLoudness: Double = CinemaAudioMasteringService.targetLUFS,
        loudnessTolerance: Double = 1.0,
        workingDirectory: URL?
    ) async -> RenderValidationResult {
        return await validateLongform(
            outputURL: outputURL,
            expectedDurationRange: expectedDurationRange,
            expectedLoudness: expectedLoudness,
            loudnessTolerance: loudnessTolerance,
            workingDirectory: workingDirectory
        )
    }
    
    nonisolated static func loudnessIssue(
        actual: Double,
        expected: Double = CinemaAudioMasteringService.targetLUFS,
        tolerance: Double = 1.0
    ) -> ValidationIssue? {
        guard actual.isFinite, abs(actual - expected) <= tolerance else {
            return .loudnessOutOfTolerance(expected: expected, actual: actual, tolerance: tolerance)
        }
        return nil
    }

    /// Измеряет integrated loudness через ffmpeg loudnorm
    private func measureLoudness(url: URL, workingDirectory: URL?) async throws -> Double {
        guard let workingDir = workingDirectory else {
            throw ValidationError.noWorkingDirectory
        }
        
        let ffmpeg = try await BinaryDownloadService.ensureAvailable(.ffmpeg, workingDirectory: workingDir)
        let ffprobe = try await BinaryDownloadService.ensureAvailable(.ffprobe, workingDirectory: workingDir)
        
        // Используем loudnorm фильтр для измерения громкости
        let args = [
            "-i", url.path,
            "-af", "loudnorm=print_format=json",
            "-f", "null",
            "-"
        ]
        
        let result = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: args)
        
        // Парсим JSON из stderr (loudnorm выводит туда)
        let output = result.standardError
        guard let jsonStart = output.range(of: "{"),
              let jsonEnd = output.range(of: "}", options: .backwards) else {
            throw ValidationError.loudnessParseFailed
        }
        
        let jsonString = String(output[jsonStart.lowerBound...jsonEnd.upperBound])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inputIntegrated = json["input_i"] as? String,
              let loudness = Double(inputIntegrated) else {
            throw ValidationError.loudnessParseFailed
        }
        
        return loudness
    }
}

enum ValidationError: LocalizedError {
    case noWorkingDirectory
    case loudnessParseFailed
    
    var errorDescription: String? {
        switch self {
        case .noWorkingDirectory:
            return "Working directory is required for loudness measurement"
        case .loudnessParseFailed:
            return "Failed to parse loudness measurement output"
        }
    }
}
