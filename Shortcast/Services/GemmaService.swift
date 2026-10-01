import Foundation
import Gemma4Swift

/// Orchestrates one end-to-end generation: pull the audio out of the video,
/// build the prompt, run Gemma 4 on-device, and parse the result into the
/// three platform variants.
enum GemmaService {

    static func generate(
        job: VideoJob,
        engine: Gemma4Engine,
        languageOverride: String,
        styleExamples: String,
        videoTitle: String = "",
        videoDescription: String = "",
        onToken: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerationResult {

        let audioURL = try await MediaExtractor.extractAudio(from: job.url)
        defer {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        }

        let prompt = PromptBuilder.buildPrompt(
            languageOverride: languageOverride,
            styleExamples: styleExamples,
            videoTitle: videoTitle, videoDescription: videoDescription)

        let media = Gemma4Engine.MediaInput(videoURL: job.url, audioURL: audioURL)
        let raw = try await engine.describe(media: media, prompt: prompt, onToken: onToken)
        Self.log("raw output (\(raw.count) chars):\n\(raw)")
        return try JSONVariantParser.parse(raw)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/gemma] \(message)\n".utf8))
    }
}
