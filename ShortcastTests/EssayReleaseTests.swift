import AppKit
import Foundation
import Testing
import os
@testable import Shortcast

private func releaseFixture() -> (LongformBuildResult, Transcript) {
    let concept = ThematicConcept(word: "СВОБОДА", tagline: "Ціна вибору", philosophicalPremise: "Вибір має наслідки", suggestedTitle: "Ціна свободи", source: .llm)
    var lines: [TranscriptSegment] = []
    let ranges = (0..<4).map { i -> TimeSegment in
        let start = Double(i * 60 + 10)
        lines += [TranscriptSegment(start: start, end: start + 8, text: "Це питання особистої свободи."),
                  TranscriptSegment(start: start + 9, end: start + 24, text: "За власний вибір доводиться відповідати.")]
        return TimeSegment(start: start, end: start + 25)
    }
    let arc = LongformNarrativeArc(id: "release", movieTitle: "Тестовий фільм", concept: concept,
        acts: [LongformAct(type: .hook, title: "Вибір", dramaticBeat: "Початок", segments: Array(ranges.prefix(2))),
               LongformAct(type: .catharsis, title: "Наслідки", dramaticBeat: "Відповідь", segments: Array(ranges.suffix(2)))], summary: "", mood: "dramatic")
    let result = LongformBuildResult(outputURL: URL(fileURLWithPath: "/private/tmp/essay.mp4"), arc: arc,
        metadata: LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: concept, arc: arc), duration: 110)
    return (result, Transcript(segments: lines, language: "uk"))
}

private func releaseReply(_ ids: [String], quote: String = "За власний вибір доводиться відповідати.") throws -> String {
    let rows = ids.enumerated().map { index, id in
        ["candidateID": id, "title": index == 0 ? "Ціна вибору" : "Відповідь за наслідки",
         "angle": "Свобода вимагає відповідальності", "hook": index == 0 ? "Хто обирає твоє життя?" : "Чим ти платиш за свободу?",
         "why": "Діалог має запитання і самостійну відповідь", "payoffQuote": quote, "question": "Яка ціна вибору для тебе?"]
    }
    return String(data: try JSONSerialization.data(withJSONObject: ["shorts": rows]), encoding: .utf8)!
}

private final class ReleaseBrowserStub: BrowserPublishingProtocol, Sendable {
    let jobs = OSAllocatedUnfairLock(initialState: [BrowserUploadJob]())
    let missingURL: Bool
    let auth: BrowserAuthStatus
    let failComments: Bool
    init(missingURL: Bool = false, youtube: Bool = true, tiktok: Bool = true, failComments: Bool = false) {
        self.missingURL = missingURL
        self.auth = .init(tiktok: tiktok, youtube: youtube)
        self.failComments = failComments
    }
    func checkAuthStatus() async throws -> BrowserAuthStatus { auth }
    func openLoginSession() async throws -> BrowserAuthStatus { try await checkAuthStatus() }
    func publish(job: BrowserUploadJob) -> AsyncThrowingStream<BrowserPublishEvent, Error> {
        let count = jobs.withLock { $0.append(job); return $0.count }
        return AsyncThrowingStream { stream in
            let platform = job.platforms[0]
            if job.action == "youtube-comment" && failComments {
                stream.yield(.failure(platform: "youtube", message: "Pin unavailable")); stream.finish(); return
            }
            let url = job.action == "youtube-comment" ? (job.targetVideoURL! + "&lc=Comment\(count)")
                : platform == "youtube" ? "https://www.youtube.com/watch?v=vid\(String(format: "%08d", count))" : "https://www.tiktok.com/@test/video/100\(count)"
            stream.yield(.success(platform: platform, message: "test", url: missingURL ? nil : url)); stream.finish()
        }
    }
}

private final class RichPostProtocolStub: URLProtocol, @unchecked Sendable {
    static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        let snapshot = captured
        Self.requests.withLock { $0.append(snapshot) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"result":{"message_id":123}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Essay release", .serialized)
struct EssayReleaseTests {
    @Test("Publication footer uses the current Telegram channel without changing the approved essay")
    func currentPublicationDestination() {
        let (result, _) = releaseFixture()
        var metadata = result.metadata
        metadata.description += "\n\nTelegram: https://t.me/old_channel\n\n#Кіноесе"
        let revised = LongformMetadataGenerator.updatingTelegram(in: metadata, channelID: "@kadr_sens")
        #expect(revised.description.contains("Telegram: https://t.me/kadr_sens"))
        #expect(!revised.description.contains("https://t.me/old_channel"))
        #expect(revised.title == metadata.title && revised.tags == metadata.tags)
        #expect(LongformMetadataGenerator.updatingTelegram(in: revised, channelID: "@kadr_sens") == revised)
        #expect(metadata.description.contains("https://t.me/old_channel"))
    }

    @Test("Camera ignores face jitter, holds on detection loss and stays within the source")
    func steadyCamera() {
        let samples = (0...20).map { index in
            EssayCameraPath.Sample(time: Double(index) * 0.2, centre: index < 10 ? 0.5 + (index.isMultiple(of: 2) ? 0.004 : -0.004) : nil)
        }
        let path = EssayCameraPath.make(samples: samples, duration: 4.13, scaledWidth: 2400, viewportWidth: 1080)
        #expect(abs((path.last?.time ?? 0) - 4.13) < 0.00001)
        #expect(path.allSatisfy { abs($0.cropX - path[0].cropX) < 0.01 })
        let none = EssayCameraPath.make(samples: [], duration: 2, scaledWidth: 2400, viewportWidth: 1080)
        #expect(none.allSatisfy { $0.cropX == 660 })
    }

    @Test("Camera pans continuously with bounded speed and acceleration instead of jumping on face reacquisition")
    func smoothCamera() {
        let samples = [EssayCameraPath.Sample(time: 0, centre: 0.25), .init(time: 1, centre: nil),
                       .init(time: 2, centre: 0.75), .init(time: 4, centre: nil)]
        let path = EssayCameraPath.make(samples: samples, duration: 8, scaledWidth: 2400, viewportWidth: 1080)
        var velocities: [CGFloat] = []
        for (a, b) in zip(path, path.dropFirst()) {
            #expect((0...1320).contains(b.cropX))
            let velocity = (b.cropX - a.cropX) / CGFloat(b.time - a.time)
            #expect(abs(velocity) <= EssayCameraPath.maximumSpeed + 0.01)
            velocities.append(velocity)
        }
        for (a, b) in zip(velocities, velocities.dropFirst()) {
            #expect(abs(b - a) * 30 <= EssayCameraPath.maximumAcceleration + 0.01)
        }
        #expect(path.last!.cropX > path.first!.cropX + 700)
        // A separately cut source scene seeds its own crop immediately; the
        // previous scene's velocity and position are never carried into it.
        let next = EssayCameraPath.make(samples: [.init(time: 0, centre: 0.75)], duration: 1, scaledWidth: 2400, viewportWidth: 1080)
        #expect(next[0].cropX == 1260)
        #expect(next.allSatisfy { abs($0.cropX - 1260) < 0.01 })
    }

    @Test("A competing larger face does not steal focus from a continuously tracked face")
    func stickyFaceSelection() {
        let previous = CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.3)
        let subject = previous.offsetBy(dx: 0.01, dy: 0)
        let other = CGRect(x: 0.65, y: 0.2, width: 0.25, height: 0.4)
        #expect(EssayCameraPath.selectFace([other, subject], previous: previous) == subject)
        #expect(EssayCameraPath.selectFace([other, subject], previous: nil) == other)
    }

    @Test("Opaque short mattes cover unused pixels without covering the picture band")
    @MainActor func matteGeometry() throws {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: EssayShortRenderer.size)
        let video = CALayer(); video.frame = root.bounds; root.addSublayer(video)
        EssayShortRenderer.addMatte(to: root)
        let layers = try #require(root.sublayers)
        #expect(layers.count == 3 && layers[0] === video)
        #expect(root.isOpaque)
        let convertedBand = CGRect(x: 0, y: EssayShortRenderer.size.height - EssayShortRenderer.pictureBand.maxY,
            width: EssayShortRenderer.pictureBand.width, height: EssayShortRenderer.pictureBand.height)
        for matte in layers.dropFirst() {
            #expect(matte.isOpaque && matte.opacity == 1)
            #expect(matte.animationKeys() == nil)
            #expect(matte.frame.intersection(convertedBand).height <= 0)
            let color = try #require(matte.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) })
            #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0 && color.alphaComponent == 1)
        }
        #expect(layers.dropFirst().reduce(0) { $0 + $1.frame.height } + convertedBand.height == root.bounds.height)
    }

    @Test("Release preparation and publishing keep the results and their progress sheet mounted")
    @MainActor func releaseProgressKeepsPresenter() {
        let workspace = WorkspaceModel()
        workspace.longformResult = releaseFixture().0
        workspace.cancelLongformSelection()
        #expect(workspace.phase == .longformResults)
        workspace.isWorkingOnEssayRelease = true
        #expect(workspace.isBusy)
        #expect(!workspace.showsPipelineProgress)
        workspace.isWorkingOnEssayRelease = false
        #expect(!workspace.isBusy)
    }

    @Test("Reopening a prepared release preserves its pair without loading a model or publishing")
    @MainActor func preparedHandoff() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in shorts.indices {
            let file = directory.appendingPathComponent("short\(i).mp4")
            try Data([1]).write(to: file)
            shorts[i].outputURL = file
        }
        let release = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts)
        let workspace = WorkspaceModel(filmProjectService: FilmProjectService(storageDirectory: directory))
        var project = FilmProject(sourceMovieURL: URL(fileURLWithPath: "/missing-source.mp4"), movieFileName: "movie", movieTitle: result.arc.movieTitle)
        project.essayRelease = release
        workspace.currentProject = project
        workspace.longformResult = result
        // There is intentionally no source job or loaded Director. Reopening
        // must only read the saved exports, never enter the generator.
        try await workspace.prepareEssayRelease(modelManager: ModelManager(), settings: AppSettings()) { _ in }
        #expect(workspace.currentEssayRelease == release)
        #expect(workspace.currentEssayRelease?.hasReadyShorts == true)
        #expect(!workspace.isWorkingOnEssayRelease)
        try FileManager.default.removeItem(at: shorts[0].outputURL!)
        #expect(workspace.currentEssayRelease?.hasReadyShorts == false)
        var editedArc = result.arc
        editedArc.captionEdits = [LongformCaptionEdit(start: 10, end: 18, original: "Помилка", replacement: "Виправлення")]
        workspace.longformResult = LongformBuildResult(outputURL: result.outputURL, arc: editedArc,
            metadata: result.metadata, duration: result.duration)
        #expect(workspace.currentEssayRelease == nil)
    }

    @Test("Candidates contain only approved scenes, complete lines and 38–58 second stories")
    func catalogue() {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        #expect(windows.count >= 2)
        for window in windows {
            #expect((38...58.04).contains(window.duration + 3))
            #expect(window.segments.allSatisfy { segment in result.arc.segments.contains { $0.start <= segment.start && $0.end >= segment.end } })
            #expect(window.segments.allSatisfy { range in transcript.segments.contains { $0.start == range.start } })
        }
    }

    @Test("Two complementary plans are accepted; duplicated windows and invented quotes are refused")
    func evidence() throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        let first = try #require(windows.first), last = try #require(windows.last)
        #expect(try EssayShortDirector.parse(releaseReply([first.id, last.id]), catalogue: windows).count == 2)
        #expect(try EssayShortDirector.parse(releaseReply([first.id, first.id]), catalogue: windows, expectedCount: 1).count == 1)
        #expect(throws: EssayReleaseError.self) { try EssayShortDirector.parse(releaseReply([first.id, first.id]), catalogue: windows) }
        #expect(throws: EssayReleaseError.self) { try EssayShortDirector.parse(releaseReply([first.id, last.id], quote: "Цього ніколи не було у фільмі."), catalogue: windows) }
    }

    @Test("YouTube targets are canonical exact video links; channel and spoofed URLs are refused")
    func videoLinks() {
        #expect(EssayRelease.youtubeURL("https://youtu.be/abcdefghijk?t=10") == "https://www.youtube.com/watch?v=abcdefghijk")
        #expect(EssayRelease.youtubeURL("https://youtube.com/@channel") == nil)
        #expect(EssayRelease.youtubeURL("https://youtube.com.evil.test/watch?v=abcdefghijk") == nil)
        #expect(EssayRelease.youtubeURL("https://youtube.com/watch?v=bad") == nil)
        #expect(EssayRelease.publicationURL("https://www.tiktok.com/@test", platform: "tiktok") == nil)
        #expect(EssayRelease.publicationURL("https://www.tiktok.com/@test/video/1234", platform: "tiktok") != nil)
        #expect(EssayRelease.youtubeCommentURL("https://youtube.com/watch?v=abcdefghijk&lc=UgxCommentId") != nil)
        #expect(EssayRelease.youtubeCommentURL("https://youtube.com/watch?v=abcdefghijk") == nil)
        #expect(EssayRelease.youtubeCommentURL("https://youtube.com.evil.test/watch?v=abcdefghijk&lc=UgxCommentId") == nil)
    }

    @Test("Second model pass cannot see windows overlapping the first selected story")
    func sequentialSelection() async throws {
        let (result, transcript) = releaseFixture()
        let prompts = OSAllocatedUnfairLock(initialState: [String]())
        let gateway = DirectorChatGateway(readiness: { true }, identifier: { "fixture-model" }, completion: { _, prompt, _ in
            let number = prompts.withLock { $0.append(prompt); return $0.count }
            guard let line = prompt.components(separatedBy: "\n").first(where: { $0.hasPrefix("S") }),
                  let id = line.split(separator: " ").first else { return nil }
            let raw = try? releaseReply([String(id)])
            return number == 1 ? raw : raw?.replacingOccurrences(of: "Хто обирає твоє життя?", with: "Чим ти платиш за свободу?")
        })
        let selected = try await EssayShortDirector(model: gateway).plan(arc: result.arc, transcript: transcript)
        #expect(selected.count == 2)
        #expect(selected.allSatisfy { $0.selectionModelID == "fixture-model" })
        let requests = prompts.withLock { $0 }
        #expect(requests.count == 2)
        #expect(!requests[1].contains("\(selected[0].candidateID!) ["))
    }

    @Test("Interrupted publishing remains uncertain after a project round trip")
    func recovery() throws {
        var project = FilmProject(sourceMovieURL: URL(fileURLWithPath: "/tmp/movie.mp4"), movieFileName: "movie.mp4", movieTitle: "Фільм")
        var release = EssayRelease(essayKey: "test")
        release.receipts["short1.youtube"] = .init(state: .sending, message: "sending")
        project.essayRelease = release
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder.decode(FilmProject.self, from: encoder.encode(project))
        #expect(restored.essayRelease?.receipts["short1.youtube"]?.state == .needsReview)
    }

    @Test("RichMessage is sent with escaped content, a real button and an explicit media attachment")
    @MainActor func richPayload() async throws {
        RichPostProtocolStub.requests.withLock { $0 = [] }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RichPostProtocolStub.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let cover = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1, 2, 3]).write(to: cover); defer { try? FileManager.default.removeItem(at: cover) }
        let post = EssayRichPost(title: "Кадр & <Сенс>", body: "Теза", quote: "Цитата", question: "Питання?",
            hashtags: "#Кіноесе", youtubeURL: "https://www.youtube.com/watch?v=abcdefghijk", coverURL: cover)
        let id = try await TelegramPublishingService(session: session).publishRichPost(post, botToken: "test-token", channelId: "-100123")
        #expect(id == 123)
        let request = try #require(RichPostProtocolStub.requests.withLock { $0.first })
        #expect(request.url?.lastPathComponent == "sendRichMessage")
        let body = (String(data: try #require(request.httpBody), encoding: .utf8) ?? "").replacingOccurrences(of: "\\/", with: "/")
        #expect(body.contains("rich_message") && body.contains("attach://cover"))
        #expect(body.contains("tg://photo?id=cover"))
        #expect(body.contains("&amp;") && body.contains("&lt;Сенс&gt;"))
        #expect(body.contains("-100123"))
    }

    @Test("Publishing resumes without re-uploading confirmed targets")
    @MainActor func resume() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for i in shorts.indices { shorts[i].outputURL = file }
        var release = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts,
            essayYouTubeURL: "https://www.youtube.com/watch?v=abcdefghijk")
        release.receipts["telegram.announcement"] = .init(state: .published, message: "already posted")
        let browser = ReleaseBrowserStub()
        let publisher = EssayReleasePublisher(browser: browser)
        var checkpoint = release
        let updated = try await publisher.publish(release, result: result, botToken: "unused", channelId: "@test_channel",
            progress: { _ in }, checkpoint: { checkpoint = $0 })
        #expect(browser.jobs.withLock { $0.count } == 7)
        #expect(browser.jobs.withLock { $0.filter { $0.action == nil }.allSatisfy { $0.isShort == true } })
        #expect(checkpoint == updated)
        _ = try await publisher.publish(updated, result: result, botToken: "unused", channelId: "@test_channel", progress: { _ in }, checkpoint: { _ in })
        #expect(browser.jobs.withLock { $0.count } == 7)
    }

    @Test("Unknown upload outcomes stop the pipeline and cannot be retried blindly")
    @MainActor func uncertainUpload() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for i in shorts.indices { shorts[i].outputURL = file }
        var state = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts)
        let browser = ReleaseBrowserStub(missingURL: true)
        await #expect(throws: EssayReleaseError.self) {
            _ = try await EssayReleasePublisher(browser: browser).publish(state, result: result, botToken: "unused", channelId: "@test_channel",
                progress: { _ in }, checkpoint: { state = $0 })
        }
        #expect(state.receipts["essay.youtube"]?.state == .needsReview)
        #expect(browser.jobs.withLock { $0.count } == 1)
        #expect(throws: EssayReleaseError.self) { try EssayReleasePublisher.requireRetryAllowed(state.receipts["essay.youtube"]) }
    }

    @Test("TikTok can be deferred without login, then resumed without duplicating YouTube or Telegram")
    @MainActor func deferredTikTok() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for index in shorts.indices { shorts[index].outputURL = file }
        var state = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts)
        state.includeTikTok = false
        #expect(try JSONDecoder().decode(EssayRelease.self, from: JSONEncoder().encode(state)).wantsTikTok == false)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RichPostProtocolStub.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let telegram = TelegramPublishingService(session: session)
        RichPostProtocolStub.requests.withLock { $0 = [] }
        let youtubeOnly = ReleaseBrowserStub(tiktok: false)
        state = try await EssayReleasePublisher(browser: youtubeOnly, telegram: telegram)
            .publish(state, result: result, botToken: "test-only", channelId: "@test_channel", progress: { _ in }, checkpoint: { _ in })
        #expect(youtubeOnly.jobs.withLock { $0.count == 6 && $0.allSatisfy { $0.platforms == ["youtube"] } })
        #expect(state.receipts["telegram.announcement"]?.state == .published)
        #expect(state.receipts["short1.tiktok"] == nil && state.receipts["short2.tiktok"] == nil)
        #expect(RichPostProtocolStub.requests.withLock { $0.count } == 1)

        state.includeTikTok = true
        // The already completed YouTube destinations must not require a new
        // YouTube login when the deferred TikTok uploads are finally enabled.
        let tiktokOnly = ReleaseBrowserStub(youtube: false)
        state = try await EssayReleasePublisher(browser: tiktokOnly, telegram: telegram)
            .publish(state, result: result, botToken: "test-only", channelId: "@test_channel", progress: { _ in }, checkpoint: { _ in })
        #expect(tiktokOnly.jobs.withLock { $0.count == 2 && $0.allSatisfy { $0.platforms == ["tiktok"] } })
        #expect(RichPostProtocolStub.requests.withLock { $0.count } == 1)
        #expect(state.receipts["short1.tiktok"]?.state == .published && state.receipts["short2.tiktok"]?.state == .published)
    }

    @Test("Enabled TikTok without a login stops before any publication")
    @MainActor func missingTikTokLogin() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for index in shorts.indices { shorts[index].outputURL = file }
        let state = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts)
        let browser = ReleaseBrowserStub(tiktok: false)
        var checkpoints = 0
        await #expect(throws: EssayReleaseError.self) {
            _ = try await EssayReleasePublisher(browser: browser).publish(state, result: result, botToken: "unused", channelId: "@test_channel",
                progress: { _ in }, checkpoint: { _ in checkpoints += 1 })
        }
        #expect(browser.jobs.withLock { $0.isEmpty })
        #expect(checkpoints == 0)
    }

    @Test("Telegram destination is prepared after the essay and before the shorts bring viewers")
    @MainActor func publicationOrder() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for i in shorts.indices { shorts[i].outputURL = file }
        let release = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RichPostProtocolStub.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var completed: [String] = []
        RichPostProtocolStub.requests.withLock { $0 = [] }
        let browser = ReleaseBrowserStub()
        let final = try await EssayReleasePublisher(browser: browser, telegram: TelegramPublishingService(session: session))
            .publish(release, result: result, botToken: "test-only", channelId: "@test_channel", progress: { _ in }, checkpoint: { state in
                for key in state.receipts.keys.sorted() where state.receipts[key]?.state == .published && !completed.contains(key) {
                    completed.append(key)
                }
            })
        #expect(completed == ["essay.youtube", "telegram.announcement", "short1.youtube", "short1.tiktok", "short2.youtube", "short2.tiktok", "essay.youtube.comment", "short1.youtube.comment", "short2.youtube.comment"])
        let jobs = browser.jobs.withLock { $0 }
        #expect(jobs.count == 8)
        #expect(jobs[0].videoPath == result.outputURL.path)
        #expect(jobs[0].title == result.metadata.title)
        #expect(jobs[0].caption == LongformMetadataGenerator.updatingTelegram(in: result.metadata, channelID: "@test_channel").description)
        let essayURL = try #require(final.essayYouTubeURL)
        for job in jobs.dropFirst().filter({ $0.action == nil }) {
            #expect(job.title.contains(result.arc.movieTitle))
            #expect(job.caption.contains(essayURL))
            #expect(job.caption.contains("https://t.me/test_channel"))
            #expect(!job.hashtags.isEmpty)
            #expect(job.isShort == true && job.isPublic)
        }
        let request = try #require(RichPostProtocolStub.requests.withLock { $0.first })
        let payload = (String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "").replacingOccurrences(of: "\\/", with: "/")
        #expect(payload.contains(essayURL))
    }

    @Test("Pin failures leave all videos and Telegram delivered, and every comment is attempted")
    @MainActor func pinFailureDoesNotBlockDelivery() async throws {
        let (result, transcript) = releaseFixture()
        let windows = EssayShortDirector.catalogue(arc: result.arc, transcript: transcript)
        var shorts = try EssayShortDirector.parse(releaseReply([windows.first!.id, windows.last!.id]), catalogue: windows)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        for i in shorts.indices { shorts[i].outputURL = file }
        var state = EssayRelease(essayKey: EssayRelease.key(for: result.arc), shorts: shorts, essayYouTubeURL: "https://www.youtube.com/watch?v=abcdefghijk")
        state.includeTikTok = false
        state.receipts["telegram.announcement"] = .init(state: .published, message: "already posted")
        let browser = ReleaseBrowserStub(failComments: true)
        await #expect(throws: EssayReleaseError.self) {
            _ = try await EssayReleasePublisher(browser: browser).publish(state, result: result, botToken: "unused", channelId: "@test_channel", progress: { _ in }, checkpoint: { state = $0 })
        }
        #expect(state.receipts["short1.youtube"]?.state == .published && state.receipts["short2.youtube"]?.state == .published)
        for key in ["essay.youtube.comment", "short1.youtube.comment", "short2.youtube.comment"] {
            #expect(state.receipts[key]?.state == .needsReview)
        }
        #expect(browser.jobs.withLock { $0.filter { $0.action == "youtube-comment" }.count } == 3)
        let before = browser.jobs.withLock { $0.filter { $0.action == nil }.count }
        let recovered = ReleaseBrowserStub()
        state = try await EssayReleasePublisher(browser: recovered).publish(state, result: result, botToken: "unused", channelId: "@test_channel", progress: { _ in }, checkpoint: { _ in })
        #expect(recovered.jobs.withLock { $0.count == 3 && $0.allSatisfy { $0.action == "youtube-comment" } })
        #expect(before == 2 && state.receipts["essay.youtube.comment"]?.state == .published)
    }
}
