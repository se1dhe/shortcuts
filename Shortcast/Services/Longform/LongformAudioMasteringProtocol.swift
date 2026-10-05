import AVFoundation

/// Протокол сведения непрерывного саундтрека и диалогов для длинного видео
protocol LongformAudioMasteringProtocol: Sendable {
    /// Формирует аудио-микс с динамическим сайдчейн-дакингом, подавлением оригинальной музыки фильма в паузах, кульминационным крещендо, микро-кроссфейдами на склейках и финальным затуханием в тишину (2.5с)
    func buildAudioMixParameters(
        composition: AVComposition,
        musicTrack: AVCompositionTrack,
        speechTrack: AVCompositionTrack,
        speechIntervals: [TimeSegment],
        sceneCutPoints: [Double],
        totalDuration: Double,
        baseMusicVolume: Float,
        duckingEnabled: Bool,
        dialogueFocusEnabled: Bool,
        originalMusicDucking: Float
    ) -> AVAudioMix
}

extension LongformAudioMasteringProtocol {
    func buildAudioMixParameters(
        composition: AVComposition,
        musicTrack: AVCompositionTrack,
        speechTrack: AVCompositionTrack,
        speechIntervals: [TimeSegment],
        sceneCutPoints: [Double] = [],
        totalDuration: Double,
        baseMusicVolume: Float = 0.28,
        duckingEnabled: Bool = true
    ) -> AVAudioMix {
        buildAudioMixParameters(
            composition: composition,
            musicTrack: musicTrack,
            speechTrack: speechTrack,
            speechIntervals: speechIntervals,
            sceneCutPoints: sceneCutPoints,
            totalDuration: totalDuration,
            baseMusicVolume: baseMusicVolume,
            duckingEnabled: duckingEnabled,
            dialogueFocusEnabled: true,
            originalMusicDucking: 0.82
        )
    }
}
