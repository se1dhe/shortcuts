import AVFoundation
import Foundation
import Gemma4Swift
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import Tokenizers
import HuggingFace

/// Обновляет публикационный пакет, не экспортируя видео и не меняя его монтаж.
struct LongformPackagingService: Sendable {
    let thumbnailGenerator: any LongformThumbnailGeneratingProtocol

    @MainActor
    static func makeThumbnailGenerator(modelManager: ModelManager, movie: MovieIdentity?) -> LongformThumbnailGenerator {
        let cast = Array((movie?.characters ?? []).filter { !$0.trimmed.isEmpty }.prefix(2))
        let session = CoverVisionSession(model: ModelManager.model)
        let gateway = ThumbnailVisionGateway(modelID: ModelManager.model.rawValue) { [modelManager, session] image, prompt in
            await modelManager.freeDirectorIfMemoryTight()
            return try await session.complete(image: image, prompt: prompt)
        }
        return LongformThumbnailGenerator(verifier: ThumbnailSubjectVerifier(model: gateway, leadingCast: cast))
    }

    static func updatingText(_ result: LongformBuildResult) -> LongformBuildResult {
        let timeline = LongformTimeline(arc: result.arc, coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true)
        let metadata = LongformMetadataGenerator.generate(movieTitle: result.arc.movieTitle,
            concept: result.arc.concept, arc: result.arc, timeline: timeline)
        return LongformBuildResult(outputURL: result.outputURL, arc: result.arc, metadata: metadata,
            duration: result.duration, thumbnailURL: result.thumbnailURL, validationResult: result.validationResult,
            audioSettings: result.audioSettings, thumbnailSubject: result.thumbnailSubject, packagingWarning: result.packagingWarning)
    }

    func refresh(_ result: LongformBuildResult, sourceURL: URL) async throws -> LongformBuildResult {
        let text = Self.updatingText(result)
        let output = ExportLayout.artifact(in: result.outputURL.deletingLastPathComponent(), kind: .cover,
            base: result.arc.concept.word, ext: "jpg")
        var thumbnail: ReviewedThumbnail?
        var warning: String?
        do {
            var coverConcept = result.arc.concept
            if let title = result.arc.publicationTitle, !title.trimmed.isEmpty { coverConcept.suggestedTitle = title }
            thumbnail = try await thumbnailGenerator.generateReviewedThumbnail(sourceAsset: AVURLAsset(url: sourceURL),
                segments: result.arc.segments, concept: coverConcept, movieTitle: result.arc.movieTitle, outputURL: output)
        } catch is CancellationError { throw CancellationError() }
        catch { warning = error.localizedDescription }
        try Task.checkCancellation()
        return LongformBuildResult(outputURL: result.outputURL, arc: result.arc, metadata: text.metadata,
            duration: result.duration, thumbnailURL: thumbnail?.url, validationResult: result.validationResult,
            audioSettings: result.audioSettings, thumbnailSubject: thumbnail?.subject, packagingWarning: warning)
    }

    func regenerateCover(
        _ result: LongformBuildResult,
        sourceURL: URL,
        avoidingTimes: [Double]
    ) async throws -> LongformBuildResult {
        let output = ExportLayout.artifact(in: result.outputURL.deletingLastPathComponent(), kind: .cover,
            base: result.arc.concept.word, ext: "jpg")
        var coverConcept = result.arc.concept
        if let title = result.arc.publicationTitle, !title.trimmed.isEmpty {
            coverConcept.suggestedTitle = title
        }
        let thumbnail = try await thumbnailGenerator.generateAlternativeReviewedThumbnail(
            sourceAsset: AVURLAsset(url: sourceURL), segments: result.arc.segments,
            concept: coverConcept, movieTitle: result.arc.movieTitle, outputURL: output,
            avoidingTimes: avoidingTimes)
        try Task.checkCancellation()
        return LongformBuildResult(outputURL: result.outputURL, arc: result.arc, metadata: result.metadata,
            duration: result.duration, thumbnailURL: thumbnail.url, validationResult: result.validationResult,
            audioSettings: result.audioSettings, thumbnailSubject: thumbnail.subject, packagingWarning: nil)
    }
}

/// Использует штатный VLM loader MLX: он поддерживает shared-KV и quantized
/// per-layer projections E4B, которых нет в старом фасаде Gemma4Engine.
private actor CoverVisionSession {
    private let model: Gemma4Pipeline.Model
    private var container: ModelContainer?
    init(model: Gemma4Pipeline.Model) { self.model = model }
    func complete(image: URL, prompt: String) async throws -> String {
        if container == nil {
            guard let path = Gemma4ModelCache.localPath(for: model) else {
                throw ThumbnailSelectionError.visionUnavailable
            }
            container = try await CoverVisionCompatibility.factory().loadContainer(from: path, using: #huggingFaceTokenizerLoader())
            DirectorRunLog.write("cover vision loaded: " + model.rawValue)
        }
        guard let container else { throw ThumbnailSelectionError.visionUnavailable }
        var parameters = GenerateParameters(maxTokens: 384, temperature: 0.1)
        parameters.maxKVSize = 4096
        let session = ChatSession(container, generateParameters: parameters,
            processing: .init(resize: CGSize(width: 896, height: 896)), additionalContext: ["enable_thinking": false])
        var reply = ""
        for try await chunk in session.streamResponse(to: prompt, images: [.url(image)]) {
            try Task.checkCancellation()
            reply += chunk
        }
        return reply
    }
}
