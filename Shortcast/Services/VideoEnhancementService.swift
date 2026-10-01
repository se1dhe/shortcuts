import Foundation
import AVFoundation

/// Which pipeline runs before the final export / upload.
enum VideoEnhancementPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case crispHighFPS

    var id: String { rawValue }

    /// Maps any unknown / removed raw value (e.g. an old "cinematicHD"/"ultraHD4K") to
    /// `.off` so decoding legacy data never crashes.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VideoEnhancementPreset(rawValue: raw) ?? .off
    }

    var displayName: String {
        switch self {
        case .off:          String(localized: "Off")
        case .crispHighFPS: String(localized: "High detail + High FPS (RIFE 60 · sharpen, keeps aspect)")
        }
    }

    /// Presets that run frame interpolation (RIFE) for a higher output frame rate.
    var usesRIFE: Bool { self == .crispHighFPS }
}

/// Mutable options that drive the enhancement pipeline.
struct VideoEnhancementOptions: Sendable {
    let preset: VideoEnhancementPreset
    let rifeFrameRate: Int
    let realesrganScale: Int
    let sharpness: Double
    let contrast: Double
    let saturation: Double
    let bitrateMbps: Int
}

enum VideoEnhancementError: LocalizedError {
    case missingBinary(String)
    case processingFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingBinary(let name):
            return String(localized: "Missing required binary: \(name). Make sure it is installed and on your PATH.")
        case .processingFailed(let name, let detail):
            return String(localized: "\(name) failed: \(detail)")
        }
    }
}

/// Native macOS pipeline for the TikTok "4K cinematic" look.
/// Uses external CLI tools stored in `<workingDirectory>/bin`:
///   - ffmpeg   (sharpen / colour / scale / bitrate)
///   - rife-ncnn-vulkan   (frame interpolation, ultraHD4K only)
/// Missing tools are downloaded once on first use.
enum VideoEnhancementService {

    // MARK: - Availability

    static func canEnhance(options: VideoEnhancementOptions, workingDirectory: URL?) -> Bool {
        guard options.preset != .off else { return false }
        guard BinaryDownloadService.resolveBinary("ffmpeg", workingDirectory: workingDirectory) != nil else {
            Self.log("FFmpeg not found")
            return false
        }
        if options.preset.usesRIFE {
            guard BinaryDownloadService.resolveBinary("rife-ncnn-vulkan/rife-ncnn-vulkan", workingDirectory: workingDirectory) != nil else {
                Self.log("RIFE not found")
                return false
            }
        }
        return true
    }

    // MARK: - Main entry

    static func enhance(
        videoURL: URL,
        options: VideoEnhancementOptions,
        workingDirectory: URL?
    ) async throws -> URL {
        guard options.preset != .off else { return videoURL }
        Self.log("starting enhancement — preset=\(options.preset.rawValue), fps=\(options.rifeFrameRate)")

        let tmp = FileManager.default.temporaryDirectory
        let ffmpegBin = try await BinaryDownloadService.ensureAvailable(.ffmpeg, workingDirectory: workingDirectory)

        // ── RIFE path (Ultra HD 4K and High-detail-High-FPS): frames → RIFE → encode ──
        if options.preset.usesRIFE {
            let framesDir = tmp.appendingPathComponent("frames-\(UUID().uuidString)")
            try await extractFrames(from: videoURL, to: framesDir, binaryPath: ffmpegBin)

            var rifeInput = framesDir
            let rifeBin = try await BinaryDownloadService.ensureAvailable(.rife, workingDirectory: workingDirectory)
            let rifePasses = options.rifeFrameRate == 120 ? 2 : 1
            for pass in 0..<rifePasses {
                let rifeOutput = tmp.appendingPathComponent("rife-\(pass)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: rifeOutput, withIntermediateDirectories: true)
                try await runRIFE(input: rifeInput, output: rifeOutput, binaryPath: rifeBin)
                if pass > 0 { try? FileManager.default.removeItem(at: rifeInput) }
                rifeInput = rifeOutput
            }

            let encoded = tmp.appendingPathComponent("encoded-\(UUID().uuidString).mp4")
            defer {
                // Clean up all intermediate frame directories on exit
                for dir in [framesDir, rifeInput] {
                    if dir != encoded {
                        try? FileManager.default.removeItem(at: dir)
                    }
                }
            }
            try await encodeFrames(
                from: rifeInput,
                originalVideo: videoURL,
                to: encoded,
                fps: Double(options.rifeFrameRate),
                options: options,
                binaryPath: ffmpegBin)
            Self.log("enhancement complete → \(encoded.path)")
            return encoded
        }

        // Only .off (returned above) and .crispHighFPS (handled above) exist.
        return videoURL
    }

    // MARK: - Helpers

    private static func extractFrames(from videoURL: URL, to directory: URL, binaryPath: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = binaryPath
        task.arguments = [
            "-y", "-i", videoURL.path,
            "-an",
            "-q:v", "2",
            directory.appendingPathComponent("frame_%08d.jpg").path
        ]
        try await runAsync(task, name: "extract-frames")
    }

    private static func runRIFE(input: URL, output: URL, binaryPath: URL) async throws {
        let task = Process()
        task.executableURL = binaryPath
        task.currentDirectoryURL = binaryPath.deletingLastPathComponent()
        task.arguments = [
            "-i", input.path,
            "-o", output.path,
            "-f", "%08d.png",
            "-m", "rife-v4.6"
        ]
        try await runAsync(task, name: "RIFE")
    }

    private static func encodeFrames(
        from directory: URL,
        originalVideo: URL,
        to output: URL,
        fps: Double,
        options: VideoEnhancementOptions,
        binaryPath: URL
    ) async throws {
        let sh = options.sharpness
        let ct = options.contrast
        let sat = options.saturation

        // High detail, native resolution/aspect (no forced 4K rescale that would
        // stretch a 9:16 short). Sharpen + gentle contrast/saturation.
        let vf = [
            "eq=contrast=\(ct):saturation=\(sat)",
            "unsharp=5:5:\(sh)",
        ].joined(separator: ",")

        let task = Process()
        task.executableURL = binaryPath
        task.arguments = [
            "-y",
            "-framerate", String(fps),
            "-i", directory.appendingPathComponent("%08d.png").path,
            "-i", originalVideo.path,
            "-map", "0:v:0",
            "-map", "1:a:0?",
            "-vf", vf,
            "-c:v", "hevc_videotoolbox",
            "-b:v", "\(options.bitrateMbps)M",
            "-maxrate", "\(options.bitrateMbps + 10)M",
            "-bufsize", "\(options.bitrateMbps + 10)M",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-tag:v", "hvc1",
            output.path
        ]
        try await runAsync(task, name: "encode-frames")
    }

    private static func runAsync(_ task: Process, name: String) async throws {
        Self.log("\(name) starting…")
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = nil

        try task.run()

        return try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    Self.log("\(name) done")
                    continuation.resume()
                } else {
                    Self.log("\(name) FAILED — exit \(process.terminationStatus)")
                    if !output.isEmpty {
                        Self.log("\(name) output: \(output)")
                    }
                    continuation.resume(throwing: VideoEnhancementError.processingFailed(
                        name, "exit code \(process.terminationStatus) – \(output)"))
                }
            }
        }
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/enhance] \(message)\n".utf8))
    }
}
