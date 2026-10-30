import Foundation

/// Результат успешной сборки длинного ролика
struct LongformBuildResult: Codable, Equatable, Sendable {
    let outputURL: URL
    let arc: LongformNarrativeArc
    let metadata: LongformYouTubeMetadata
    let duration: Double
    let thumbnailURL: URL?
    let validationResult: RenderValidationResult?
    let audioSettings: LongformAudioSettings?
    let thumbnailSubject: ThumbnailSubjectEvidence?
    let packagingWarning: String?

    init(
        outputURL: URL,
        arc: LongformNarrativeArc,
        metadata: LongformYouTubeMetadata,
        duration: Double,
        thumbnailURL: URL? = nil,
        validationResult: RenderValidationResult? = nil,
        audioSettings: LongformAudioSettings? = nil,
        thumbnailSubject: ThumbnailSubjectEvidence? = nil,
        packagingWarning: String? = nil
    ) {
        self.outputURL = outputURL
        self.arc = arc
        self.metadata = metadata
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.validationResult = validationResult
        self.audioSettings = audioSettings
        self.thumbnailSubject = thumbnailSubject
        self.packagingWarning = packagingWarning
    }
}

/// Настройки аудиомастеринга, звукорежиссуры и защиты от Content ID для кино-эссе Shortcast Cinema
struct LongformAudioSettings: Codable, Sendable, Equatable {
    var backgroundMusicURL: URL? = nil
    var musicVolume: Float = 0.18
    var duckingEnabled: Bool = true
    var dialogueFocusEnabled: Bool = true
    var originalMusicDucking: Float = 0.82
    var coldOpenEnabled: Bool = true
    var antiCopyrightEnabled: Bool = true
    var antiCopyrightPreset: AntiCopyrightPreset = .cinemaShield
    var loudnessNormalizationEnabled: Bool = true

    init(
        backgroundMusicURL: URL? = nil,
        musicVolume: Float = 0.18,
        duckingEnabled: Bool = true,
        dialogueFocusEnabled: Bool = true,
        originalMusicDucking: Float = 0.82,
        coldOpenEnabled: Bool = true,
        antiCopyrightEnabled: Bool = true,
        antiCopyrightPreset: AntiCopyrightPreset = .cinemaShield,
        loudnessNormalizationEnabled: Bool = true
    ) {
        self.backgroundMusicURL = backgroundMusicURL
        self.musicVolume = musicVolume
        self.duckingEnabled = duckingEnabled
        self.dialogueFocusEnabled = dialogueFocusEnabled
        self.originalMusicDucking = originalMusicDucking
        self.coldOpenEnabled = coldOpenEnabled
        self.antiCopyrightEnabled = antiCopyrightEnabled
        self.antiCopyrightPreset = antiCopyrightPreset
        self.loudnessNormalizationEnabled = loudnessNormalizationEnabled
    }
}

/// Протокол координатора сборки длинного видеоролика Shortcast Cinema
protocol LongformPipelineCoordinating: Sendable {
    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        selectedMoments: [SelectedMoment],
        essayPlan: EssayPlan?,
        audioSettings: LongformAudioSettings,
        existingArc: LongformNarrativeArc?,
        workingDirectory: URL?,
        channelLogoEnabled: Bool,
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
            selectedMoments: [],
            essayPlan: nil,
            audioSettings: settings,
            existingArc: nil,
            workingDirectory: workingDirectory,
            channelLogoEnabled: true,
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
        duckingEnabled: Bool,
        workingDirectory: URL?,
        channelLogoEnabled: Bool = true,
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
            selectedMoments: [],
            essayPlan: nil,
            audioSettings: settings,
            existingArc: nil,
            workingDirectory: workingDirectory,
            channelLogoEnabled: channelLogoEnabled,
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
            selectedMoments: [],
            essayPlan: nil,
            audioSettings: audioSettings,
            existingArc: nil,
            workingDirectory: workingDirectory,
            channelLogoEnabled: true,
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
        channelLogoEnabled: Bool,
        progressHandler: (@Sendable (Double, String) -> Void)?
    ) async throws -> LongformBuildResult {
        try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            selectedMoments: [],
            essayPlan: nil,
            audioSettings: audioSettings,
            existingArc: nil,
            workingDirectory: workingDirectory,
            channelLogoEnabled: channelLogoEnabled,
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
            selectedMoments: [],
            essayPlan: nil,
            audioSettings: audioSettings,
            existingArc: nil,
            workingDirectory: nil,
            channelLogoEnabled: true,
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
        let settings = LongformAudioSettings(
            backgroundMusicURL: backgroundMusicURL,
            musicVolume: 0.28,
            duckingEnabled: true
        )
        return try await buildLongformVideo(
            sourceURL: sourceURL,
            movieTitle: movieTitle,
            transcript: transcript,
            concept: concept,
            selectedMoments: [],
            essayPlan: nil,
            audioSettings: settings,
            existingArc: nil,
            workingDirectory: nil,
            channelLogoEnabled: true,
            progressHandler: progressHandler
        )
    }
}
