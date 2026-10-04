import AVFoundation

/// Протокол сведения непрерывного саундтрека и диалогов для длинного видео
protocol LongformAudioMasteringProtocol: Sendable {
    /// Формирует аудио-микс с динамическим сайдчейн-дакингом, кульминационным крещендо и финальным затуханием в тишину (2.5с)
    func buildAudioMixParameters(
        composition: AVComposition,
        musicTrack: AVCompositionTrack,
        speechTrack: AVCompositionTrack,
        speechIntervals: [TimeSegment],
        totalDuration: Double,
        baseMusicVolume: Float,
        duckingEnabled: Bool
    ) -> AVAudioMix
}

extension LongformAudioMasteringProtocol {
    func buildAudioMixParameters(
        composition: AVComposition,
        musicTrack: AVCompositionTrack,
        speechTrack: AVCompositionTrack,
        speechIntervals: [TimeSegment],
        totalDuration: Double,
        baseMusicVolume: Float = 0.28,
        duckingEnabled: Bool = true
    ) -> AVAudioMix {
        buildAudioMixParameters(
            composition: composition,
            musicTrack: musicTrack,
            speechTrack: speechTrack,
            speechIntervals: speechIntervals,
            totalDuration: totalDuration,
            baseMusicVolume: baseMusicVolume,
            duckingEnabled: duckingEnabled
        )
    }
}
