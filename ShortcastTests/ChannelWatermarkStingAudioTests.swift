import AVFoundation
import Foundation
import Testing
@testable import Shortcast

/// Звук фирменного стинга: короткий whoosh + шиммер, который живёт внутри
/// анимации карточки и не клиппует поверх речи и музыки.
@Suite("Channel Watermark Sting Audio")
struct ChannelWatermarkStingAudioTests {

    @Test("стинг — 1,6 с, слышимый, без клиппинга и с затуханием в тишину")
    func stingIsAudibleWithoutClipping() {
        let samples = ChannelWatermarkStingAudio.samples()
        let length = Double(samples.count) / ChannelWatermarkStingAudio.sampleRate
        #expect(abs(length - ChannelWatermarkStingAudio.duration) < 0.01)

        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.05, "звук стинга слишком тихий")
        #expect(peak <= 0.34, "звук стинга клиппует")
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(abs(samples.last ?? 1) < 0.02, "стинг не затухает в тишину — будет щелчок")
    }

    @Test("стинг-файл пишется на диск и читается как аудио")
    func stingFileIsWrittenAndReadable() throws {
        let url = try #require(ChannelWatermarkStingAudio.makeFile())
        #expect(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
        let length = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(length - ChannelWatermarkStingAudio.duration) < 0.05)
    }
}
