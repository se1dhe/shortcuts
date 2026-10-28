import Foundation

/// Утилиты для работы с внешними бинарными файлами (ffmpeg, ffprobe).
/// Общие методы для поиска и валидации бинарников.
enum BinaryUtilities {
    
    /// Ищет ffmpeg в стандартных местах или в working directory.
    /// - Parameter workingDirectory: Директория где может находиться ffmpeg
    /// - Returns: URL к бинарнику ffmpeg или nil если не найден
    static func resolveFFmpegBinary(workingDirectory: URL?) -> URL? {
        // 1. Проверяем working directory
        if let workDir = workingDirectory {
            let ffmpegInWorkDir = workDir.appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: ffmpegInWorkDir.path) {
                return ffmpegInWorkDir
            }
        }
        
        // 2. Проверяем стандартные пути macOS
        let standardPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        
        for path in standardPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        // 3. Пробуем найти через which
        if let whichResult = try? Process.run(URL(fileURLWithPath: "/usr/bin/which"), arguments: ["ffmpeg"]),
           whichResult.terminationStatus == 0 {
            // which нашёл ffmpeg, но нам нужен путь
            // Упрощённо: возвращаем nil, пусть вызывающий код использует BinaryDownloadService
        }
        
        return nil
    }
    
    /// Ищет ffprobe в стандартных местах или в working directory.
    /// - Parameter workingDirectory: Директория где может находиться ffprobe
    /// - Returns: URL к бинарнику ffprobe или nil если не найден
    static func resolveFFprobeBinary(workingDirectory: URL?) -> URL? {
        // 1. Проверяем working directory
        if let workDir = workingDirectory {
            let ffprobeInWorkDir = workDir.appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: ffprobeInWorkDir.path) {
                return ffprobeInWorkDir
            }
        }
        
        // 2. Проверяем стандартные пути macOS
        let standardPaths = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        
        for path in standardPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
}
