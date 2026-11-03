import XCTest
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
@testable import Shortcast

final class AntiCopyrightServiceTests: XCTestCase {

    // MARK: - Config Tests

    func testEssayProcessingPreservesFrameForEveryPreset() {
        for preset in AntiCopyrightPreset.allCases {
            let original = preset.config
            let config = original.preservingFrame
            let builder = AntiCopyrightFFmpegBuilder(config: config)
            let filters = builder.buildVideoFilters(renderSize: CGSize(width: 1920, height: 1080))
            XCTAssertFalse(filters.contains { $0.contains("crop=") || $0.contains("scale=") || $0 == "hflip" })
            let geometry = AntiCopyrightGeometryTransformer(config: config)
            XCTAssertEqual(geometry.transform(renderSize: CGSize(width: 1920, height: 1080)), .identity)
            XCTAssertEqual(config.audioPitchShiftCents, original.audioPitchShiftCents)
            XCTAssertEqual(config.contrastDelta, original.contrastDelta)
        }
        // Applying the essay policy must not change the independent Shorts preset.
        XCTAssertGreaterThan(AntiCopyrightConfig.tikTokShield.driftIntensity, 0)
    }

    func testSourceFrameCadenceKeepsFilmAndBroadcastRates() {
        for fps: Int32 in [24, 25, 30, 50, 60] {
            let duration = CMTime(value: 1, timescale: fps)
            XCTAssertEqual(VideoFrameCadence.sourceFrameDuration(nominalFrameRate: Float(fps), minimumFrameDuration: duration), duration)
        }
        for fps: Int32 in [24_000, 30_000, 60_000] {
            XCTAssertEqual(VideoFrameCadence.sourceFrameDuration(nominalFrameRate: Float(fps) / 1001,
                minimumFrameDuration: .invalid), CMTime(value: 1001, timescale: fps))
        }
        for fps: Float in [0, .nan, .infinity] {
            XCTAssertEqual(VideoFrameCadence.sourceFrameDuration(nominalFrameRate: fps, minimumFrameDuration: .invalid),
                CMTime(value: 1, timescale: 30))
        }
    }

    func testOffConfigIsInactive() {
        let config = AntiCopyrightConfig.off
        XCTAssertFalse(config.isActive)
        XCTAssertFalse(config.hasVideoTransforms)
        XCTAssertFalse(config.hasAudioTransforms)
    }

    func testSubtleConfigIsActive() {
        let config = AntiCopyrightConfig.subtle
        XCTAssertTrue(config.isActive)
        XCTAssertTrue(config.hasVideoTransforms)
        XCTAssertTrue(config.hasAudioTransforms)
    }

    func testCinemaShieldConfigNoMirror() {
        let config = AntiCopyrightConfig.cinemaShield
        XCTAssertFalse(config.enableMirror, "CinemaShield should not mirror to preserve text/actors")
        XCTAssertTrue(config.isActive)
    }

    func testTikTokShieldConfigHasMirror() {
        let config = AntiCopyrightConfig.tikTokShield
        XCTAssertTrue(config.enableMirror)
        XCTAssertTrue(config.isActive)
    }

    func testConfigClamping() {
        var config = AntiCopyrightConfig()
        config.zoomScale = 2.0
        config.contrastDelta = 0.5
        config.filmGrainIntensity = 1.5
        config.audioPitchShiftCents = 300.0

        let clamped = config.clamped()

        XCTAssertEqual(clamped.zoomScale, 1.20, accuracy: 0.001)
        XCTAssertEqual(clamped.contrastDelta, 0.30, accuracy: 0.001)
        XCTAssertEqual(clamped.filmGrainIntensity, 1.0, accuracy: 0.001)
        XCTAssertEqual(clamped.audioPitchShiftCents, 200.0, accuracy: 0.001)
    }

    func testPitchScaleRatio() {
        let config = AntiCopyrightConfig(audioPitchShiftCents: 1200.0)
        let ratio = config.pitchScaleRatio
        XCTAssertEqual(ratio, 2.0, accuracy: 0.01, "1200 cents = 1 octave = 2x frequency")
    }

    func testPitchScaleRatioSemitone() {
        let config = AntiCopyrightConfig(audioPitchShiftCents: 100.0)
        let ratio = config.pitchScaleRatio
        XCTAssertEqual(ratio, pow(2.0, 1.0 / 12.0), accuracy: 0.001, "100 cents = 1 semitone")
    }

    // MARK: - Geometry Transformer Tests

    func testMirrorTransform() {
        let config = AntiCopyrightConfig(enableMirror: true, zoomScale: 1.0)
        let transformer = AntiCopyrightGeometryTransformer(config: config)
        let renderSize = CGSize(width: 1920, height: 1080)
        let transform = transformer.transform(renderSize: renderSize)

        XCTAssertNotEqual(transform, .identity, "Mirror should produce non-identity transform")
    }

    func testNoMirrorTransform() {
        let config = AntiCopyrightConfig(enableMirror: false, zoomScale: 1.0)
        let transformer = AntiCopyrightGeometryTransformer(config: config)
        let renderSize = CGSize(width: 1920, height: 1080)
        let transform = transformer.transform(renderSize: renderSize)

        XCTAssertEqual(transform, .identity, "No mirror + no zoom should be identity")
    }

    func testZoomTransform() {
        let config = AntiCopyrightConfig(enableMirror: false, zoomScale: 1.05)
        let transformer = AntiCopyrightGeometryTransformer(config: config)
        let renderSize = CGSize(width: 1920, height: 1080)
        let transform = transformer.transform(renderSize: renderSize)

        XCTAssertNotEqual(transform, .identity, "Zoom should produce non-identity transform")
    }

    func testDriftEndpoints() {
        let config = AntiCopyrightConfig(zoomScale: 1.05, driftIntensity: 0.5)
        let transformer = AntiCopyrightGeometryTransformer(config: config)
        let renderSize = CGSize(width: 1920, height: 1080)
        let endpoints = transformer.driftEndpoints(renderSize: renderSize)

        XCTAssertLessThan(endpoints.start.x, 0, "Start drift should be negative")
        XCTAssertGreaterThan(endpoints.end.x, 0, "End drift should be positive")
    }

    func testNoDriftWhenDisabled() {
        let config = AntiCopyrightConfig(zoomScale: 1.05, driftIntensity: 0.0)
        let transformer = AntiCopyrightGeometryTransformer(config: config)
        let renderSize = CGSize(width: 1920, height: 1080)
        let endpoints = transformer.driftEndpoints(renderSize: renderSize)

        XCTAssertEqual(endpoints.start, .zero)
        XCTAssertEqual(endpoints.end, .zero)
    }

    // MARK: - Color Transformer Tests

    func testColorControlsFilterCreated() {
        let config = AntiCopyrightConfig(contrastDelta: 0.05, saturationDelta: 0.03)
        let transformer = AntiCopyrightColorTransformer(config: config)
        let filter = transformer.makeColorControlsFilter()

        XCTAssertNotNil(filter, "Filter should be created when deltas are non-zero")
    }

    func testNoColorFilterWhenZeroDeltas() {
        let config = AntiCopyrightConfig(contrastDelta: 0.0, saturationDelta: 0.0)
        let transformer = AntiCopyrightColorTransformer(config: config)
        let filter = transformer.makeColorControlsFilter()

        XCTAssertNil(filter, "No filter when deltas are zero")
    }

    // MARK: - Audio Mixer Tests

    func testScaledDuration() {
        let config = AntiCopyrightConfig(audioSpeedMultiplier: 1.02)
        let mixer = AntiCopyrightAudioMixer(config: config)
        let duration = CMTime(seconds: 100.0, preferredTimescale: 600)
        let scaled = mixer.calculateScaledDuration(for: duration)

        XCTAssertEqual(scaled.seconds, 100.0 / 1.02, accuracy: 0.01)
    }

    func testNoScalingWhenSpeedIsOne() {
        let config = AntiCopyrightConfig(audioSpeedMultiplier: 1.0)
        let mixer = AntiCopyrightAudioMixer(config: config)
        let duration = CMTime(seconds: 100.0, preferredTimescale: 600)
        let scaled = mixer.calculateScaledDuration(for: duration)

        XCTAssertEqual(scaled.seconds, 100.0, accuracy: 0.001)
    }

    // MARK: - FFmpeg Builder Tests

    func testFFmpegVideoFiltersWithMirror() {
        let config = AntiCopyrightConfig(enableMirror: true, zoomScale: 1.0)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildVideoFilters()

        XCTAssertTrue(filters.contains("hflip"), "Should contain hflip when mirror enabled")
    }

    func testFFmpegVideoFiltersWithoutMirror() {
        let config = AntiCopyrightConfig(enableMirror: false, zoomScale: 1.0)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildVideoFilters()

        XCTAssertFalse(filters.contains("hflip"), "Should not contain hflip when mirror disabled")
    }

    func testFFmpegVideoFiltersWithZoom() {
        let config = AntiCopyrightConfig(enableMirror: false, zoomScale: 1.05)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildVideoFilters()

        XCTAssertTrue(filters.contains { $0.contains("scale") || $0.contains("crop") },
                      "Should contain scale/crop when zoom enabled")
    }

    func testFFmpegVideoFiltersWithGrain() {
        let config = AntiCopyrightConfig(filmGrainIntensity: 0.3)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildVideoFilters()

        XCTAssertTrue(filters.contains { $0.contains("noise") },
                      "Should contain noise filter when grain enabled")
    }

    func testFFmpegVideoFiltersNoGrainWhenZero() {
        let config = AntiCopyrightConfig(filmGrainIntensity: 0.0)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildVideoFilters()

        XCTAssertFalse(filters.contains { $0.contains("noise") },
                       "Should not contain noise filter when grain is zero")
    }

    func testFFmpegVideoFiltersWithContrast() {
        let config = AntiCopyrightConfig(contrastDelta: 0.05)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildVideoFilters()

        XCTAssertTrue(filters.contains { $0.contains("eq=contrast") },
                      "Should contain eq filter when contrast delta is non-zero")
    }

    func testFFmpegAudioFiltersRubberband() {
        let config = AntiCopyrightConfig(audioSpeedMultiplier: 1.02, audioPitchShiftCents: 12.0)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildAudioFilters(method: .rubberband, sampleRate: 44100)

        XCTAssertTrue(filters.contains { $0.contains("rubberband") },
                      "Should contain rubberband filter")
    }

    func testFFmpegAudioFiltersAsetrate() {
        let config = AntiCopyrightConfig(audioPitchShiftCents: 12.0)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildAudioFilters(method: .asetrate, sampleRate: 44100)

        XCTAssertTrue(filters.contains { $0.contains("asetrate") },
                      "Should contain asetrate filter")
    }

    func testFFmpegAudioFiltersWithEQ() {
        let config = AntiCopyrightConfig(enableAudioWarmthEQ: true)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildAudioFilters(method: .rubberband, sampleRate: 44100)

        XCTAssertTrue(filters.contains { $0.contains("equalizer") },
                      "Should contain equalizer filter when EQ enabled")
    }

    func testFFmpegAudioFiltersNoEQWhenDisabled() {
        let config = AntiCopyrightConfig(audioSpeedMultiplier: 1.0, audioPitchShiftCents: 0.0, enableAudioWarmthEQ: false)
        let builder = AntiCopyrightFFmpegBuilder(config: config)
        let filters = builder.buildAudioFilters(method: .rubberband, sampleRate: 44100)

        XCTAssertTrue(filters.isEmpty, "Should have no filters when all audio transforms disabled")
    }

    func testFFmpegArgumentsIncludeVideoFilters() {
        let config = AntiCopyrightConfig(enableMirror: true)
        let service = AntiCopyrightService(config: config)
        let args = service.buildFFmpegArguments()

        XCTAssertTrue(args.contains("-vf"), "Should contain -vf flag")
        let vfIndex = args.firstIndex(of: "-vf")!
        let vfValue = args[vfIndex + 1]
        XCTAssertTrue(vfValue.contains("hflip"), "Video filter should contain hflip")
    }

    func testFFmpegArgumentsIncludeAudioFilters() {
        let config = AntiCopyrightConfig(audioPitchShiftCents: 12.0)
        let service = AntiCopyrightService(config: config)
        let args = service.buildFFmpegArguments()

        XCTAssertTrue(args.contains("-af"), "Should contain -af flag")
    }

    func testFFmpegArgumentsNoFlagsWhenOff() {
        let config = AntiCopyrightConfig.off
        let service = AntiCopyrightService(config: config)
        let args = service.buildFFmpegArguments()

        XCTAssertFalse(args.contains("-vf"), "Should not contain -vf when off")
        XCTAssertFalse(args.contains("-af"), "Should not contain -af when off")
    }

    // MARK: - Service Integration Tests

    func testServiceInitialization() {
        let config = AntiCopyrightConfig.moderate
        let service = AntiCopyrightService(config: config)

        XCTAssertEqual(service.config, config.clamped())
    }

    func testServiceStandardInstances() {
        XCTAssertNotNil(AntiCopyrightService.subtle)
        XCTAssertNotNil(AntiCopyrightService.cinemaShield)
        XCTAssertNotNil(AntiCopyrightService.tikTokShield)
        XCTAssertNotNil(AntiCopyrightService.moderate)
        XCTAssertNotNil(AntiCopyrightService.aggressive)
        XCTAssertNotNil(AntiCopyrightService.off)
    }

    func testServiceCalculateTransform() {
        let config = AntiCopyrightConfig(enableMirror: true, zoomScale: 1.05)
        let service = AntiCopyrightService(config: config)
        let renderSize = CGSize(width: 1920, height: 1080)
        let transform = service.calculateTransform(renderSize: renderSize)

        XCTAssertNotEqual(transform, .identity)
    }

    func testServiceScaledDuration() {
        let config = AntiCopyrightConfig(audioSpeedMultiplier: 1.02)
        let service = AntiCopyrightService(config: config)
        let duration = CMTime(seconds: 100.0, preferredTimescale: 600)
        let scaled = service.calculateScaledDuration(for: duration)

        XCTAssertEqual(scaled.seconds, 100.0 / 1.02, accuracy: 0.01)
    }

    // MARK: - Preset Tests

    func testPresetDisplayName() {
        XCTAssertEqual(AntiCopyrightPreset.off.displayName, "Отключено")
        XCTAssertEqual(AntiCopyrightPreset.subtle.displayName, "Мягкая (Subtle)")
        XCTAssertEqual(AntiCopyrightPreset.cinemaShield.displayName, "Кинематографическая обработка")
    }

    func testPresetConfig() {
        XCTAssertEqual(AntiCopyrightPreset.off.config, .off)
        XCTAssertEqual(AntiCopyrightPreset.subtle.config, .subtle)
        XCTAssertEqual(AntiCopyrightPreset.cinemaShield.config, .cinemaShield)
    }

    func testAllPresetsCaseIterable() {
        XCTAssertEqual(AntiCopyrightPreset.allCases.count, 7)
    }
}

@MainActor
final class ShieldExportRegressionTests: XCTestCase {
    func testInPlaceProcessingPreservesTimelineAndAudio() async throws {
        guard ProcessInfo.processInfo.environment["SHORTCAST_RENDER_SMOKE"] == "1" else { throw XCTSkip("Opt-in media export") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("input.mp4")
        _ = try await ProcessRunner.shared.run(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: [
            "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "2", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", file.path])
        let service = AntiCopyrightService(config: .moderate,
            pictureRegion: CGRect(x: 0, y: 90, width: 640, height: 180), activeDuration: 1.5, preserveTimeline: true)
        _ = try await service.process(videoURL: file, outputURL: file, workingDirectory: dir)
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)
        XCTAssertEqual(service.config.audioSpeedMultiplier, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".shield-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testFailedProcessingDoesNotDeleteDestination() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("input.mp4")
        let previous = Data("existing export must survive".utf8)
        try previous.write(to: file)
        do {
            _ = try await AntiCopyrightService.cinemaShield.process(videoURL: file, outputURL: file, workingDirectory: dir)
            XCTFail("Invalid input must fail")
        } catch { XCTAssertEqual(try Data(contentsOf: file), previous) }
    }
}
