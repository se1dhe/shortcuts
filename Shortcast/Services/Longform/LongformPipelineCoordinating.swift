import Foundation

/// Результат успешной сборки длинного ролика
struct LongformBuildResult: Sendable {
    let outputURL: URL
    let arc: LongformNarrativeArc
    let metadata: LongformYouTubeMetadata
    let duration: Double
    let thumbnailURL: URL?

    init(
        outputURL: URL,
        arc: LongformNarrativeArc,
        metadata: LongformYouTubeMetadata,
        duration: Double,
        thumbnailURL: URL? = nil
    ) {
        self.outputURL = outputURL
        self.arc = arc
        self.metadata = metadata
        self.duration = duration
        self.thumbnailURL = thumbnailURL
    }
}

/// Настройки аудиомастеринга, звукорежиссуры и защиты от Content ID для кино-эссе Shortcast Cinema
struct LongformAudioSettings: Sendable, Equatable {
    var backgroundMusicURL: URL? = nil
    var musicVolume: Float = 0.18
    var duckingEnabled: Bool = true
    var dialogueFocusEnabled: Bool = true
    var originalMusicDucking: Float = 0.82
    var coldOpenEnabled: Bool = true
    var antiCopyrightEnabled: Bool = true
    var antiCopyrightPreset: AntiCopyrightPreset = .cinemaShield

    init(
        backgroundMusicURL: URL? = nil,
        musicVolume: Float = 0.18,
        duckingEnabled: Bool = true,
        dialogueFocusEnabled: Bool = true,
        originalMusicDucking: Float = 0.82,
        coldOpenEnabled: Bool = true,
        antiCopyrightEnabled: Bool = true,
        antiCopyrightPreset: AntiCopyrightPreset = .cinemaShield
    ) {
        self.backgroundMusicURL = backgroundMusicURL
        self.musicVolume = musicVolume
        self.duckingEnabled = duckingEnabled
        self.dialogueFocusEnabled = dialogueFocusEnabled
        self.originalMusicDucking = originalMusicDucking
        self.coldOpenEnabled = coldOpenEnabled
        self.antiCopyrightEnabled = antiCopyrightEnabled
        self.antiCopyrightPreset = antiCopyrightPreset
    }
}

/// Протокол координатора сборки длинного видеоролика Shortcast Cinema
protocol LongformPipelineCoordinating: Sendable {
    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        audioSettings: LongformAudioSettings,
        existingArc: LongformNarrativeArc?,
        workingDirectory: URL?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        audioSettings: LongformAudioSettings,
        workingDirectory: URL?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        backgroundMusicURL: URL?,
        musicVolume: Float,
        duckingEnabled: Bool,
        workingDirectory: URL?,
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
        duckingEnabled: Bool,
        workingDirectory: URL?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult {
        let settings = LongformAudioSettings(
            backgroundMusicURL: backgroundMusicURL,
            musicVolume: musicVolume,
            duckingEnabled: duckingEnabled
        )
        return try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            audioSettings: settings,
            workingDirectory: workingDirectory,
            progressHandler: progressHandler
        )
    }

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        audioSettings: LongformAudioSettings,
        workingDirectory: URL?,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult {
        try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            audioSettings: audioSettings,
            existingArc: nil,
            workingDirectory: workingDirectory,
            progressHandler: progressHandler
        )
    }

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        audioSettings: LongformAudioSettings,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult {
        try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            audioSettings: audioSettings,
            workingDirectory: nil,
            progressHandler: progressHandler
        )
    }

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
            workingDirectory: nil,
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
            workingDirectory: nil,
            progressHandler: progressHandler
        )
    }
}
