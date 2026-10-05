import Testing
import Foundation
import AVFoundation
@testable import Shortcast

@Suite("SeamlessAudioLoop Service Tests")
struct SeamlessAudioLoopTests {

    @Test("SeamlessAudioLoopService returns original URL if target duration is shorter than track")
    func testLoopNotNeededWhenShorter() async throws {
        let musicURL = URL(fileURLWithPath: "Shortcast/Resources/Music/Prrodan_Foggy_Night.m4a")
        guard FileManager.default.fileExists(atPath: musicURL.path) else { return }

        let looper = SeamlessAudioLoopService.shared
        let resultURL = try await looper.createSeamlessLoop(sourceURL: musicURL, targetDuration: 60.0, crossfadeDuration: 4.0)

        #expect(resultURL == musicURL)
    }

    @Test("SeamlessAudioLoopService creates crossfaded loop for target duration exceeding track")
    func testLoopCreatedWhenLonger() async throws {
        let musicURL = URL(fileURLWithPath: "Shortcast/Resources/Music/Prrodan_Foggy_Night.m4a")
        guard FileManager.default.fileExists(atPath: musicURL.path) else { return }

        let looper = SeamlessAudioLoopService.shared
        // Foggy Night is ~220s. Target duration 260s requires 2 loops with crossfade.
        let resultURL = try await looper.createSeamlessLoop(sourceURL: musicURL, targetDuration: 260.0, crossfadeDuration: 4.0)

        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        let asset = AVURLAsset(url: resultURL)
        let dur = try await asset.load(.duration)
        #expect(dur.seconds >= 260.0)
    }
}
