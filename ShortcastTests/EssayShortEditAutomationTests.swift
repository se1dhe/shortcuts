import AVFoundation
import Foundation
import Testing
@testable import Shortcast

@Suite("Short edit and music automation")
struct EssayShortEditAutomationTests {
    @Test("Scene selection resolves an immutable line and refuses unknown references")
    func selectionReferences() throws {
        let window = EssayShortDirector.Window(id: "S9", segments: [.init(start: 20, end: 60)],
            text: "Віддай гроші, і я не чіпатиму дівчину.", sourceLines: ["Віддай гроші, і я не чіпатиму дівчину."])
        let draft = try EssayShortDirector.parseSelection(#"{"candidateID":"S9","payoffLine":1}"#, catalogue: [window])
        #expect(draft.payoffQuote == window.text)
        #expect(draft.segments == window.segments)
        #expect(draft.outputURL == nil)
        for raw in [#"{"candidateID":"S8","payoffLine":1}"#, #"{"candidateID":"S9","payoffLine":0}"#,
                    #"{"candidateID":"S9","payoffLine":-9223372036854775808}"#,
                    #"{"candidateID":"S9","payoffLine":2}"#, #"{"candidateID":"S9","payoffLine":null}"#] {
            #expect(throws: (any Error).self) { try EssayShortDirector.parseSelection(raw, catalogue: [window]) }
        }
    }

    @Test("Music analysis bins decoded audio by seconds instead of buffer count")
    func actualAudioClock() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48000 {
            let amplitude: Float = index < 24000 ? 0.1 : 0.7
            samples[index] = amplitude * Float(sin(Double(index) * 2 * .pi * 440 / 8000))
        }
        do { let output = try AVAudioFile(forWriting: file, settings: format.settings); try output.write(from: buffer) }
        let energy = try await AudioDropDetector.energyProfile(in: file)
        #expect(energy.count == 6)
        #expect(abs(energy[1] - 0.005) < 0.001)
        #expect(abs(energy[4] - 0.245) < 0.005)
        for count in 0...10 { #expect(AudioDropDetector.bestDrop(in: [Double](repeating: 0.01, count: count)).isFinite) }
    }

    @Test("Music entries exclude silence, fit the whole short and can start after zero")
    func musicEntries() {
        let energy = [Double](repeating: 0, count: 30) + [Double](repeating: 0.01, count: 25)
            + [Double](repeating: 0.15, count: 35)
        let entries = EssayShortEditService.offsets(energy: energy, duration: 40, payoff: 25, bpm: 120)
        #expect(!entries.isEmpty)
        #expect(entries[0].start > 0)
        #expect(abs(entries[0].peak - entries[0].start - 25) <= 2)
        #expect(entries.allSatisfy { $0.start >= 0 && $0.start + 40 <= Double(energy.count) })
        #expect(EssayShortEditService.offsets(energy: [], duration: 40, payoff: 20, bpm: nil).isEmpty)
        #expect(EssayShortEditService.offsets(energy: energy, duration: .nan, payoff: 20, bpm: nil).isEmpty)
    }

    @Test("Official catalogue nullable fields decode and unsafe filenames cannot be selected")
    func catalogueContract() throws {
        let data = Data(#"[{"title":"Example","filename":"Example.mp3","length":"00:03:00","genre":"22","isrc":"USUAN1200068","bpm":null,"instruments":null,"description":null,"feel":"Dark"}]"#.utf8)
        let tracks = try JSONDecoder().decode([EssayShortEditService.Track].self, from: data)
        #expect(EssayShortEditService.shortlist(tracks, mood: "Dark", duration: 40).count == 1)
        #expect(tracks[0].attribution.contains("CC BY 4.0"))
        #expect(tracks[0].source.host == "incompetech.com")
        let unsafe = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "Example.mp3", with: "../Example.mp3").utf8)
        #expect(EssayShortEditService.shortlist(try JSONDecoder().decode([EssayShortEditService.Track].self, from: unsafe), mood: "Dark", duration: 40).isEmpty)
        var short = EssayShort(id: "short1", angle: "Конфлікт", hook: "Питання", title: "Назва", why: "Репліка", payoffQuote: "Слова героя", question: "Що далі?", segments: [.init(start: 0, end: 40)])
        var settings = LongformAudioSettings()
        settings.musicUsageTerms = tracks[0].attribution; short.musicSettings = settings
        for platform in [SocialPlatform.youtube, .tiktok] {
            let post = short.post(platform: platform, movieTitle: "Драйв", release: EssayRelease(essayKey: "test"), telegramURL: nil)
            #expect(post.summary.contains("Kevin MacLeod"))
            #expect(post.summary.contains("creativecommons.org/licenses/by/4.0/"))
        }
    }
}
