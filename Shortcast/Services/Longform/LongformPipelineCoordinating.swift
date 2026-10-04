import Foundation

/// Результат успешной сборки длинного ролика
struct LongformBuildResult: Sendable {
    let outputURL: URL
    let arc: LongformNarrativeArc
    let metadata: LongformYouTubeMetadata
    let duration: Double
}

/// Протокол координатора сборки длинного видеоролика Shortcast Cinema
protocol LongformPipelineCoordinating: Sendable {
    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        backgroundMusicURL: URL?,
        musicVolume: Float,
        duckingEnabled: Bool,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult
}

extension LongformPipelineCoordinating {
    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        backgroundMusicURL: URL?,
        musicVolume: Float,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult {
        try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            backgroundMusicURL: backgroundMusicURL,
            musicVolume: musicVolume,
            duckingEnabled: true,
            progressHandler: progressHandler
        )
    }

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        backgroundMusicURL: URL?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult {
        try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            backgroundMusicURL: backgroundMusicURL,
            musicVolume: 0.28,
            duckingEnabled: true,
            progressHandler: progressHandler
        )
    }
}
