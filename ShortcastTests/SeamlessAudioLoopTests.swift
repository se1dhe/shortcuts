import AVFoundation
import Testing
import Foundation
import AVFoundation
import os
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

// MARK: - Fixtures

/// Отчёт измерительного прохода ffmpeg loudnorm (`print_format=json`) — ровно как его
/// печатает ffmpeg в stderr: числа строками, блок в самом конце лога.
private let stubLoudnormJSON = """
[Parsed_loudnorm@0x100] Output sample rate: 192000 Hz
{
	"input_i" : "-29.52",
	"input_tp" : "-11.61",
	"input_lra" : "6.20",
	"input_thresh" : "-39.85",
	"target_offset" : "0.03",
	"maximum_ratio" : "0.830"
}
"""

private let stubLoudnormSummary = """
[Parsed_loudnorm@0x100]
Output Integrated:    -14.02 LUFS
Output True Peak:       -1.50 dBTP
Output LRA:              6.20 LU
"""

/// Двойной исполнитель процесса: фиксирует аргументы и эмулирует коды выхода и отчёты.
/// Настоящий ffmpeg из этих тестов не запускается никогда (герметичность).
private final class StubFFmpegRunner: ProcessRunning, @unchecked Sendable {

    struct Call {
        let executableURL: URL
        let arguments: [String]

        /// Значение, переданное после `-af`.
        var audioFilter: String? {
            guard let index = arguments.firstIndex(of: "-af"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
    }

    private let lock = OSAllocatedUnfairLock<[Call]>(initialState: [])

    /// Что отдаёт измерительный проход (`-nostats`).
    var measurementReport: String = stubLoudnormJSON
    /// Что отдаёт нормализующий проход.
    var normalizationReport: String = stubLoudnormSummary
    /// Код выхода измерительного прохода (1 = ffmpeg упал).
    var measurementExitCode: Int32 = 0
    /// Код выхода нормализующего прохода (1 = ffmpeg упал).
    var normalizationExitCode: Int32 = 0
    /// Сколько нормализующих проходов подряд падают перед тем, как получиться.
    var failingNormalizingPasses: Int = 0
    /// Пишет ли «ffmpeg» временный файл результата.
    var writesOutputFile: Bool = true
    /// Размер этого файла (при `-c:v copy` он ≈ размеру рендера).
    var outputFileSize: Int = 8_192
    /// Сколько нормализующих проходов подряд пишут огрызок вместо результата.
    var undersizedNormalizingPasses: Int = 0

    var calls: [Call] { lock.withLock { $0 } }

    var capturedArguments: [[String]] { calls.map(\.arguments) }

    func run(executableURL: URL, arguments: [String], environment: [String: String]?) async throws -> ProcessResult {
        let isMeasurementPass = arguments.contains("-nostats")

        let shouldFail: Bool = lock.withLock { storage in
            storage.append(Call(executableURL: executableURL, arguments: arguments))
            if isMeasurementPass {
                return measurementExitCode != 0
            } else if failingNormalizingPasses > 0 {
                failingNormalizingPasses -= 1
                return true
            } else {
                return normalizationExitCode != 0
            }
        }

        if shouldFail {
            throw ProcessRunnerError.executionFailed(exitCode: isMeasurementPass ? measurementExitCode : normalizationExitCode,
                                                     errorOutput: "stub ffmpeg failure")
        }

        if isMeasurementPass {
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: measurementReport)
        }

        if writesOutputFile, let destination = arguments.last {
            let bytes = lock.withLock { _ -> Int in
                if !isMeasurementPass, undersizedNormalizingPasses > 0 {
                    undersizedNormalizingPasses -= 1
                    return 8
                }
                return outputFileSize
            }
            try? Data(count: bytes).write(to: URL(fileURLWithPath: destination))
        }
        return ProcessResult(exitCode: 0, standardOutput: "", standardError: normalizationReport)
    }
}

/// Создает «рендер» фиксированного размера в отдельном временном каталоге.
private func makeLoudnessRender(size: Int = 4_096) throws -> (directory: URL, videoURL: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShortcastLoudnessTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let videoURL = directory.appendingPathComponent("longform_суб'єктивність_262965.mp4")
    try Data(count: size).write(to: videoURL)
    return (directory, videoURL)
}

/// Собирает сервис на двойном исполнителе: без реального бинарника и без реального диска.
private func makeLoudnessService(
    runner: StubFFmpegRunner,
    ffmpegAvailable: Bool = true,
    freeSpace: Int64? = 50_000_000_000
) -> LongformLoudnessService {
    LongformLoudnessService(
        processRunner: runner,
        ffmpegResolver: { _ in (ffmpegAvailable ? URL(fileURLWithPath: "/nonexistent/stub/ffmpeg") : nil) as URL? },
        freeSpaceProvider: { _ in freeSpace }
    )
}

@Suite("LongformLoudness Normalization Tests")
struct LongformLoudnessNormalizationTests {

    @Test("Pass 1 measures loudness with -vn, print_format=json and -f null -")
    func testMeasurementPassArguments() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        let measure = try #require(runner.calls.first)
        let measureArguments = measure.arguments
        #expect(measureArguments.contains("-hide_banner"))
        #expect(measureArguments.contains("-nostats"))
        #expect(measureArguments.contains("-vn"))
        #expect(measureArguments.firstIndex(of: "-i").map { measureArguments[$0 + 1] } == fixture.videoURL.path)
        #expect(measure.audioFilter?.contains("print_format=json") == true)
        #expect(measure.audioFilter?.contains("loudnorm") == true)
        #expect(Array(measureArguments.suffix(3)) == ["-f", "null", "-"])
        // Измерительный проход ничего не пишет и не трогает видеопоток.
        #expect(!measureArguments.contains("-y"))
        #expect(!measureArguments.contains("-c:v"))
        #expect(runner.capturedArguments.count == 2)
        #expect(returned == fixture.videoURL)
    }

    @Test("Pass 2 applies measured linear loudnorm and stream-copies the video")
    func testNormalizationPassArgumentsAndAtomicReplace() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        let encode = try #require(runner.calls.last)
        let encodeArguments = encode.arguments
        let filter = try #require(encode.audioFilter)

        // Видеопоток остается bit-exact, иначе возмущения защиты от Content ID не перекодируются.
        #expect(encodeArguments.firstIndex(of: "-c:v").map { encodeArguments[$0 + 1] } == "copy")
        #expect(encodeArguments.firstIndex(of: "-c:a").map { encodeArguments[$0 + 1] } == "aac")
        #expect(encodeArguments.firstIndex(of: "-b:a").map { encodeArguments[$0 + 1] } == "256k")
        #expect(encodeArguments.firstIndex(of: "-ar").map { encodeArguments[$0 + 1] } == "48000")
        #expect(encodeArguments.firstIndex(of: "-movflags").map { encodeArguments[$0 + 1] } == "+faststart")
        #expect(encodeArguments.contains("-y"))
        #expect(!encodeArguments.contains("-vn"))

        #expect(filter.contains("linear=true"))
        #expect(filter.contains("measured_I=-29.52"))
        #expect(filter.contains("measured_TP=-11.61"))
        #expect(filter.contains("measured_LRA=6.20"))
        #expect(filter.contains("measured_thresh=-39.85"))
        #expect(filter.contains("offset=0.03"))
        #expect(filter.contains("print_format=summary"))

        // Имя и расширение результата не меняются: их читают обложка и LongformResultsView.
        #expect(returned == fixture.videoURL)
        let written = try #require(encodeArguments.last)
        #expect(URL(fileURLWithPath: written).deletingLastPathComponent() == fixture.videoURL.deletingLastPathComponent())
        #expect(URL(fileURLWithPath: written).pathExtension == "mp4")
        #expect(URL(fileURLWithPath: written) != fixture.videoURL)

        // Размер проверяем свежим stat'ом: URL.resourceValues отдаёт значения, закешированные
        // на том же объекте NSURL (первое чтение случилось до публикации), и после rename врёт.
        let publishedSize = (((try? FileManager.default.attributesOfItem(atPath: fixture.videoURL.path))?[.size]) as? NSNumber)?.int64Value ?? -1
        #expect(publishedSize == Int64(runner.outputFileSize))

        // Ни временного файла, ни служебной копии предыдущего рендера не остается.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(leftovers == [fixture.videoURL.lastPathComponent])
    }

    @Test("Отвергнутая первая попытка не отравляет проверку размера второй")
    func testRetryPublishesDespiteEarlierUndersizedOutput() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        runner.undersizedNormalizingPasses = 1

        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        // Огрызок от линейного прохода отвергнут, динамический принят и опубликован.
        #expect(runner.capturedArguments.count == 3)
        let lastFilter = try #require(runner.calls.last?.audioFilter)
        #expect(!lastFilter.contains("linear=true"))
        #expect(returned == fixture.videoURL)

        let publishedSize = (((try? FileManager.default.attributesOfItem(atPath: fixture.videoURL.path))?[.size]) as? NSNumber)?.int64Value ?? -1
        #expect(publishedSize == Int64(runner.outputFileSize))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(leftovers == [fixture.videoURL.lastPathComponent])
    }

    @Test("Loudness targets come from CinemaAudioMasteringService constants")
    func testTargetsReuseCinemaConstants() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        _ = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        let expectedPrefix = "loudnorm=I=\(String(format: "%.0f", CinemaAudioMasteringService.targetLUFS))"
            + ":TP=\(String(format: "%.1f", CinemaAudioMasteringService.targetTruePeak))"
            + ":LRA=\(String(format: "%.0f", CinemaAudioMasteringService.targetLRA))"
        #expect(expectedPrefix == "loudnorm=I=-16:TP=-2.0:LRA=7")
        #expect(runner.calls.count == 2)

        for call in runner.calls {
            guard let filter = call.audioFilter, filter.contains("loudnorm") else { continue }
            #expect(filter.contains(expectedPrefix))
        }
    }

    @Test("Unparseable measurement JSON falls back to a single dynamic pass")
    func testUnparseableMeasurementFallsBackToDynamicPass() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        runner.measurementReport = "size=    1204kB time=00:12:40.00 bitrate=N/A speed=N/A"

        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        let arguments = runner.capturedArguments
        #expect(arguments.count == 2)

        let dynamicFilter = try #require(runner.calls.last?.audioFilter)
        #expect(dynamicFilter.contains("loudnorm"))
        #expect(dynamicFilter.contains("print_format=summary"))
        #expect(!dynamicFilter.contains("linear=true"))
        #expect(!dynamicFilter.contains("measured_I"))
        #expect(!dynamicFilter.contains("measured_TP"))
        #expect(!dynamicFilter.contains("measured_LRA"))
        #expect(!dynamicFilter.contains("measured_thresh"))
        #expect(!dynamicFilter.contains("volume="))
        #expect(returned == fixture.videoURL)
    }

    @Test("Linear pass failure retries with the dynamic measured-free pass")
    func testLinearFailureRetriesWithoutMeasuredValues() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        runner.failingNormalizingPasses = 1

        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        let calls = runner.calls
        #expect(calls.count == 3)
        #expect(calls[1].audioFilter?.contains("linear=true") == true)
        #expect(calls[2].audioFilter?.contains("linear=true") == false)
        #expect(calls[2].audioFilter?.contains("measured_I") == false)
        #expect(returned == fixture.videoURL)
    }

    @Test("Excessive limiting skips the linear pass in favour of dynamic loudnorm")
    func testExcessiveLimitingGoesStraightToDynamicPass() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        // Буст +15 дБ при отрицательном true-peak запасе: линейный проход выдавил бы материал.
        runner.measurementReport = """
        {
            "input_i" : "-29.00",
            "input_tp" : "-1.00",
            "input_lra" : "6.20",
            "input_thresh" : "-39.35",
            "target_offset" : "0.02",
            "maximum_ratio" : "0.180"
        }
        """

        _ = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        let encode = try #require(runner.calls.last)
        #expect(encode.audioFilter?.contains("linear=true") == false)
        #expect(encode.audioFilter?.contains("measured_I") == false)
    }

    @Test("Runner exit code 1 keeps the pre-loudness file and never fails the build")
    func testFailingRunnerKeepsPreNormalizedRender() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        runner.measurementExitCode = 1
        runner.normalizationExitCode = 1

        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        #expect(returned == fixture.videoURL)
        #expect(FileManager.default.fileExists(atPath: fixture.videoURL.path))
        let size = try fixture.videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 4_096)
        #expect(runner.calls.last?.audioFilter?.contains("loudnorm") == true)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(leftovers == [fixture.videoURL.lastPathComponent])
    }

    @Test("Silent success with no output file keeps the pre-loudness render")
    func testMissingOutputFileKeepsPreNormalizedRender() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        runner.writesOutputFile = false

        let returned = try await makeLoudnessService(runner: runner)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        #expect(returned == fixture.videoURL)
        let size = try fixture.videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 4_096)
        #expect(runner.capturedArguments.count == 3)
    }

    @Test("Insufficient free space skips the loudness stage without invoking ffmpeg")
    func testInsufficientFreeSpaceSkipsStage() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        let returned = try await makeLoudnessService(runner: runner, freeSpace: 1_000)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        #expect(returned == fixture.videoURL)
        #expect(runner.capturedArguments.isEmpty)
        let size = try fixture.videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect(size == 4_096)
    }

    @Test("Missing ffmpeg skips the loudness stage without invoking the runner")
    func testMissingFFmpegSkipsStage() async throws {
        let fixture = try makeLoudnessRender()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let runner = StubFFmpegRunner()
        let returned = try await makeLoudnessService(runner: runner, ffmpegAvailable: false)
            .normalize(videoURL: fixture.videoURL, outputURL: fixture.videoURL, workingDirectory: nil)

        #expect(returned == fixture.videoURL)
        #expect(runner.capturedArguments.isEmpty)
    }

    @Test("Measurement parsing reads the trailing loudnorm JSON block")
    func testMeasurementParser() throws {
        let measurement = try #require(LongformLoudnessService.parseMeasurement(from: stubLoudnormJSON))
        #expect(measurement.inputIntegrated == -29.52)
        #expect(measurement.inputTruePeak == -11.61)
        #expect(measurement.inputLoudnessRange == 6.20)
        #expect(measurement.inputThreshold == -39.85)
        #expect(measurement.targetOffset == 0.03)
        #expect(measurement.maximumRatio == 0.83)
        // PLR 17.91 дБ — ровно то, почему статическое усиление здесь не самодостаточно.
        #expect(measurement.peakToLoudnessRatio > 17.5)
        #expect(LongformLoudnessService.parseSummaryIntegratedLoudness(from: stubLoudnormSummary) == -14.02)
    }

    @Test("Temporary loudness file is written next to the output on the same volume")
    func testTemporaryFilePlacement() {
        let output = URL(fileURLWithPath: "/tmp/shortcast-junk/Exports/longform_theme_123456.mp4")
        let temporary = LongformLoudnessService.makeTemporaryURL(for: output)
        #expect(temporary.deletingLastPathComponent() == output.deletingLastPathComponent())
        #expect(temporary.pathExtension == output.pathExtension)
        #expect(temporary.lastPathComponent.hasPrefix("loudnorm_longform_theme_"))
        #expect(temporary != output)
    }
}

@Suite("Render loudness validation")
struct RenderLoudnessValidationTests {
    @Test("Accepts the normalized output that was previously rejected")
    func acceptsActualRender() {
        #expect(RenderValidationService.loudnessIssue(actual: -16.1) == nil)
    }

    @Test("Keeps a one LUFS tolerance around the mastering target", arguments: [-1.0, 0.0, 1.0])
    func acceptsToleranceBoundary(offset: Double) {
        #expect(RenderValidationService.loudnessIssue(
            actual: CinemaAudioMasteringService.targetLUFS + offset
        ) == nil)
    }

    @Test("Rejects outputs beyond the tolerance", arguments: [-1.1, 1.1])
    func rejectsOutsideTolerance(offset: Double) {
        let target = CinemaAudioMasteringService.targetLUFS
        #expect(RenderValidationService.loudnessIssue(actual: target + offset)
            == .loudnessOutOfTolerance(expected: target, actual: target + offset, tolerance: 1.0))
    }

    @Test("Honors an explicit target and tolerance")
    func explicitTarget() {
        #expect(RenderValidationService.loudnessIssue(actual: -14.1, expected: -14, tolerance: 0.2) == nil)
        #expect(RenderValidationService.loudnessIssue(actual: -16.1, expected: -14, tolerance: 0.2)
            == .loudnessOutOfTolerance(expected: -14, actual: -16.1, tolerance: 0.2))
    }

    @Test("Rejects non-finite measurements", arguments: [Double.nan, .infinity, -.infinity])
    func rejectsNonFinite(actual: Double) {
        #expect(RenderValidationService.loudnessIssue(actual: actual) != nil)
    }
}

@Suite("LongformAudioMastering Loudness Hardening Tests")
struct LongformAudioMasteringHardeningTests {

    private func makeMix(originalMusicDucking: Float, totalDuration: Double) throws -> AVAudioMix {
        let composition = AVMutableComposition()
        let speechTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 1))
        let musicTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2))
        let service = LongformAudioMasteringService()
        return service.buildAudioMixParameters(
            composition: composition,
            musicTrack: musicTrack,
            speechTrack: speechTrack,
            speechIntervals: [
                TimeSegment(start: 1.0, end: 2.3),
                TimeSegment(start: 3.0, end: totalDuration - 0.1)
            ],
            totalDuration: totalDuration,
            baseMusicVolume: 0.18,
            duckingEnabled: true,
            dialogueFocusEnabled: true,
            originalMusicDucking: originalMusicDucking
        )
    }

    @Test("Ducked speech volume keeps a 5% floor at any UI ducking value")
    func testDuckedSpeechFloor() {
        // Прежний UI-default 1.00 полностью глушил речь в паузах.
        let maximumDucking = LongformAudioMasteringService.duckedSpeechVolume(originalMusicDucking: 1.0)
        #expect(maximumDucking == LongformAudioMasteringService.minimumDuckedSpeechVolume)
        #expect(maximumDucking == 0.05)

        let uiDefault = LongformAudioMasteringService.duckedSpeechVolume(originalMusicDucking: 0.82)
        #expect(abs(Double(uiDefault) - 0.18) < 0.0001)
        #expect(LongformAudioMasteringService.duckedSpeechVolume(originalMusicDucking: 0.0) == 1.0)
        #expect(LongformAudioMasteringService.duckedSpeechVolume(originalMusicDucking: -1.0) == 1.0)
    }

    @Test("Audio mix still has exactly two input parameters at maximum ducking")
    func testMixKeepsTwoInputParameters() throws {
        // Громкость всего микса делает пост-экспортный loudnorm, а не третий вход AVAudioMix.
        let mix = try makeMix(originalMusicDucking: 1.0, totalDuration: 40.0)
        #expect(mix.inputParameters.count == 2)
    }

    @Test("Volume ramp clamps a ramp that starts near the timeline end")
    func testVolumeRampClampedToTimeline() throws {
        // Рамп, который раньше уходил за конец таймлайна и обрывал экспорт.
        let clamped = try #require(LongformAudioMasteringService.volumeRampTimeRange(
            start: 29.5,
            duration: 100.0,
            lastRampEnd: 0.0,
            totalDuration: 30.0
        ))
        #expect(clamped.start.seconds == 29.5)
        #expect(clamped.duration.seconds == 0.5)
        #expect(clamped.end.seconds <= 30.0 + 0.0001)

        // Рамп, упирающийся в самый конец таймлайна, отбрасывается целиком.
        #expect(LongformAudioMasteringService.volumeRampTimeRange(
            start: 30.4,
            duration: 5.0,
            lastRampEnd: 0.0,
            totalDuration: 30.0
        ) == nil)

        // Пересечение с предыдущим рампом по-прежнему сдвигает старт.
        let shifted = try #require(LongformAudioMasteringService.volumeRampTimeRange(
            start: 5.0,
            duration: 0.2,
            lastRampEnd: 8.0,
            totalDuration: 30.0
        ))
        #expect(shifted.start.seconds > 8.0)
    }
}

@Suite("Music bed automation")
struct MusicBedAutomationTests {
    @Test("Overlapping fades on a short clip do not silence the whole bed")
    func overlappingFades() throws {
        let settings = LongformAudioSettings(musicVolume: 0.1, duckingEnabled: false)
        let points = MusicBedMixing.automation(duration: 1, settings: settings, speech: [])
        #expect(points.first?.gain == 0 && points.last?.gain == 0)
        let middle = try #require(points.first { abs($0.time - 0.5) < 0.001 })
        #expect(abs(middle.gain - 0.05) < 0.0001)
    }

    @Test("Short breath pauses do not pump the background music")
    func breathPauses() {
        var settings = LongformAudioSettings(musicVolume: 0.1)
        settings.musicFadeInSeconds = 0
        settings.musicFadeOutSeconds = 0
        settings.musicDuckingDepth = 0.7
        let speech = [TimeSegment(start: 2, end: 3), .init(start: 3.5, end: 4), .init(start: 7, end: 8)]
        let merged = MusicBedMixing.speechForDucking(speech, duration: 10)
        #expect(merged == [.init(start: 2, end: 4), .init(start: 7, end: 8)])
        let points = MusicBedMixing.automation(duration: 10, settings: settings, speech: speech)
        #expect(!points.contains { $0.time > 2 && $0.time < 4 && $0.gain > 0.03001 })
        #expect(abs((points.first { $0.time == 4.3 }?.gain ?? -1) - 0.1) < 0.0001)
        #expect(MusicBedMixing.speechForDucking([.init(start: -1, end: 2), .init(start: 11, end: 12)], duration: 10) == [.init(start: 0, end: 2)])
    }

    @Test("Act profile follows edited output timing and preserves legacy manual envelopes")
    func storyProfile() throws {
        let concept = ThematicConcept(word: "ВИБІР", tagline: "Ціна", philosophicalPremise: "Ціна вибору", suggestedTitle: "Ціна", source: .llm)
        let arc = LongformNarrativeArc(movieTitle: "Фільм", concept: concept, acts: [
            LongformAct(type: .hook, title: "Початок", dramaticBeat: "", segments: [.init(start: 500, end: 510)]),
            LongformAct(type: .downfall, title: "Випробування", dramaticBeat: "", segments: [.init(start: 700, end: 720)]),
            LongformAct(type: .catharsis, title: "Розв'язка", dramaticBeat: "", segments: [.init(start: 900, end: 915)])
        ], summary: "")
        let timeline = LongformTimeline(arc: arc, coldOpenEnabled: false)
        let points = MusicBedMixing.storyEnvelope(for: arc, coldOpenEnabled: false)
        let downfall = try #require(timeline.start(ofAct: 1))
        let catharsis = try #require(timeline.start(ofAct: 2))
        #expect(MusicBedMixing.envelopeGain(at: downfall + 2, points: points) == 0.45)
        #expect(MusicBedMixing.envelopeGain(at: catharsis + 2, points: points) == 1)
        #expect(points.allSatisfy { $0.time >= 0 && $0.time <= timeline.duration && (0...1).contains($0.gain) })
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time })
        let normalized = MusicBedMixing.normalizedEnvelope([.init(time: 3, gain: 0.2), .init(time: 0, gain: 1), .init(time: 3, gain: 0.8)], duration: 10)
        #expect(normalized.map(\.time) == [0, 3])
        #expect(normalized.last?.gain == 0.8)

        var linked = LongformAudioSettings(backgroundMusicURL: URL(fileURLWithPath: "/tmp/music.mp3"), musicVolume: 0.027)
        linked.musicEnvelope = points
        linked.musicSource = "Источник записи"
        linked.musicUsageTerms = "Условия"
        linked.musicOffsetSeconds = 12
        // Old archives omit this key, and their exact hand-edited points survive.
        let legacy = try JSONDecoder().decode(LongformAudioSettings.self, from: JSONEncoder().encode(linked))
        #expect(legacy.musicEnvelopeFollowsActs == nil)
        var changedArc = arc
        changedArc.acts[0].segments[0].end += 6
        #expect(MusicBedMixing.resolvedSettings(legacy, for: changedArc, coldOpenEnabled: false) == legacy)

        linked.musicEnvelopeFollowsActs = true
        let saved = try JSONDecoder().decode(LongformAudioSettings.self, from: JSONEncoder().encode(linked))
        let resolved = MusicBedMixing.resolvedSettings(saved, for: changedArc, coldOpenEnabled: false)
        let changedTimeline = LongformTimeline(arc: changedArc, coldOpenEnabled: false)
        let shiftedDownfall = try #require(changedTimeline.start(ofAct: 1))
        #expect(abs(shiftedDownfall - downfall - 6) < 0.0001)
        #expect(MusicBedMixing.envelopeGain(at: shiftedDownfall + 2, points: resolved.musicEnvelope ?? []) == 0.45)
        #expect(resolved.backgroundMusicURL == linked.backgroundMusicURL)
        #expect(resolved.musicVolume == linked.musicVolume && resolved.musicOffsetSeconds == 12)
        #expect(resolved.musicSource == linked.musicSource && resolved.musicUsageTerms == linked.musicUsageTerms)
        #expect(resolved.musicEnvelope?.map(\.id) == points.map(\.id))
        #expect(MusicBedMixing.resolvedSettings(resolved, for: changedArc, coldOpenEnabled: false) == resolved)
        var custom = resolved
        custom.musicEnvelopeFollowsActs = false
        #expect(MusicBedMixing.resolvedSettings(custom, for: arc, coldOpenEnabled: false) == custom)
    }

    @Test("Fades reach silence and speech ducks only the music")
    func envelope() {
        var settings = LongformAudioSettings(musicVolume: 0.1)
        settings.musicFadeInSeconds = 1
        settings.musicFadeOutSeconds = 2
        settings.musicDuckingDepth = 0.7
        let points = MusicBedMixing.automation(duration: 10, settings: settings, speech: [.init(start: 2, end: 4)])
        #expect(points.first?.gain == 0)
        #expect(points.last?.gain == 0)
        #expect(abs((points.first { $0.time == 2 }?.gain ?? -1) - 0.03) < 0.0001)
        #expect(abs((points.first { $0.time == 1 }?.gain ?? -1) - 0.1) < 0.0001)
        #expect(points.allSatisfy { $0.gain >= 0 && $0.gain <= 0.1 })
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time })
        settings.duckingEnabled = false
        let plain = MusicBedMixing.automation(duration: 10, settings: settings, speech: [.init(start: 2, end: 4)])
        #expect(plain.count == 4)
        #expect(plain.first?.gain == 0 && plain.last?.gain == 0)
    }

    @Test("Old audio settings decode and new music automation survives saving")
    func persistence() throws {
        var settings = LongformAudioSettings(musicVolume: 0.025)
        let legacy = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(LongformAudioSettings.self, from: legacy) == settings)
        settings.musicOffsetSeconds = 17.5
        settings.musicFadeInSeconds = 0.7
        settings.musicFadeOutSeconds = 3
        settings.musicDuckingDepth = 0.8
        settings.musicLoopEnabled = false
        #expect(try JSONDecoder().decode(LongformAudioSettings.self, from: JSONEncoder().encode(settings)) == settings)
        var short = EssayShort(id: "music-test", angle: "Тема", hook: "Хук", title: "Назва", why: "Діалог",
            payoffQuote: "Цитата", question: "Питання", segments: [.init(start: 0, end: 20)])
        short.musicSettings = settings
        #expect(try JSONDecoder().decode(EssayShort.self, from: JSONEncoder().encode(short)).musicSettings == settings)
        short.musicSettings = nil
        #expect(try JSONDecoder().decode(EssayShort.self, from: JSONEncoder().encode(short)).musicSettings == nil)
    }
}


extension MusicBedAutomationTests {
    @Test("Music with an offset, fades and ducking exports a real audio mix")
    @MainActor func exportMusicMix() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<96_000 {
            let value = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.2
            channels[0][i] = value; channels[1][i] = value
        }
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        let asset = AVURLAsset(url: source)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let speech = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try speech.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: sourceTrack, at: .zero)
        var settings = LongformAudioSettings(backgroundMusicURL: source, musicVolume: 0.1)
        settings.musicOffsetSeconds = 0.25
        settings.musicFadeInSeconds = 0.1
        settings.musicFadeOutSeconds = 0.2
        settings.musicDuckingDepth = 0.8
        settings.musicLoopEnabled = false
        let music = try #require(try await MusicBedMixing.add(to: composition, settings: settings, duration: 1,
            speech: [.init(start: 0.3, end: 0.6)]))
        #expect(composition.tracks(withMediaType: .audio).count == 2)
        let original = AVMutableAudioMixInputParameters(track: speech)
        original.setVolume(1, at: .zero)
        let mix = AVMutableAudioMix(); mix.inputParameters = [original, music]
        let output = folder.appendingPathComponent("mixed.m4a")
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.audioMix = mix
        try await exporter.export(to: output, as: .m4a)
        let rendered = AVURLAsset(url: output)
        #expect(abs(try await rendered.load(.duration).seconds - 1) < 0.1)
        #expect(try await rendered.loadTracks(withMediaType: .audio).count == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int ?? 0) > 1000)
    }
}

@MainActor
@Suite("Music folder library")
struct MusicFolderLibraryTests {
    @Test("Folder changes appear automatically and deleted tracks become unavailable")
    func followsFolderContents() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("First.mp3")
        let added = nested.appendingPathComponent("Added.WAV")
        try Data().write(to: first)
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let library = MusicFolderLibrary(directory: root)
        #expect(library.tracks.map { $0.url.lastPathComponent } == ["First.mp3"])
        let monitor = Task { await library.monitor() }
        defer { monitor.cancel() }
        try Data().write(to: added)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(Set(library.tracks.map { $0.url.lastPathComponent }) == Set(["First.mp3", "Added.WAV"]))
        try FileManager.default.removeItem(at: first)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(library.tracks.map { $0.url.lastPathComponent } == ["Added.WAV"])
        try FileManager.default.removeItem(at: root)
        library.refresh()
        #expect(library.tracks.isEmpty)
        #expect(library.error != nil)
    }
}
