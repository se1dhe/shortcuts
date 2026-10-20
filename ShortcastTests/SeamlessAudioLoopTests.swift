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
