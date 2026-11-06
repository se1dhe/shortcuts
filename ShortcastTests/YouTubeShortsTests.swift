import Foundation
import Testing
@testable import Shortcast

@Suite("YouTube Shorts library")
struct YouTubeShortsTests {
    @Test("Discovery excludes unrelated films, long videos, ordinary videos and unsafe IDs")
    func discovery() throws {
        func row(_ id: String = "abcdefghijk", title: String = "Драйв — сцена #shorts", duration: Double? = 24, url: String? = nil) throws -> String {
            var data: [String: Any] = ["id": id, "title": title, "url": url ?? "https://www.youtube.com/shorts/\(id)", "view_count": 500]
            if let duration { data["duration"] = duration }
            return String(data: try JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        }
        let rows = try [row(), row("lmnopqrstuv", title: "Драйв — эдит", duration: nil), row(title: "Джон Уик #shorts"),
            row(duration: 181), row("../../x"), row(title: "Драйв — сцена", url: "https://www.youtube.com/watch?v=abcdefghijk"),
            row(title: "Драйв обзор фильма #shorts")].joined(separator: "\n")
        let cards = try DiscoveredShort.parseSearch(rows, film: "Драйв")
        #expect(cards.count == 2)
        #expect(cards[1].duration == 0 && cards[1].end == 0)
    }

    @Test("Current YouTube Shorts shelves parse from a real captured response")
    func realShelf() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/youtube-shorts-shelf.html")
        let cards = try ShortsDiscoveryService.parseSearchPage(String(contentsOf: file, encoding: .utf8), film: "Бойцовский клуб")
        #expect(cards.count == 4)
        #expect(cards[0].id == "rJoigAoshmo")
        #expect(cards[0].views == 300_000)
        #expect(cards.allSatisfy { $0.duration == 0 && $0.status == .discovered })
        #expect(ShortsDiscoveryService.viewCount("1,2 млн просмотров") == 1_200_000)
        #expect(ShortsDiscoveryService.viewCount("12K views") == 12_000)
        #expect(throws: (any Error).self) { try ShortsDiscoveryService.parseSearchPage("<html>Consent</html>", film: "Драйв") }
    }

    @Test("JSON extraction respects braces and escaped quotes inside titles")
    func escapedJSON() throws {
        let html = #"<script>var ytInitialData = {"contents":{"text":"a } { \"quoted\" title"}};</script>"#
        #expect(try ShortsDiscoveryService.parseSearchPage(html, film: "Драйв").isEmpty)
    }

    @Test("Foreign-film queries do not admit Soviet titles with overlapping names")
    func sovietNames() throws {
        let row = #"{"id":"abcdefghijk","title":"Джентльмены удачи #shorts","url":"https://www.youtube.com/shorts/abcdefghijk"}"#
        #expect(try DiscoveredShort.parseSearch(row, film: "Джентльмены").isEmpty)
    }

    @Test("Only exact target account video links count as publication receipts")
    func receipts() {
        #expect(DiscoveredShort.isTargetPublication("https://www.tiktok.com/@telonyx_cinema/video/123456"))
        for url in ["https://www.tiktok.com/@other/video/123", "https://www.tiktok.com/@telonyx_cinema", "https://www.tiktok.com.evil.com/@telonyx_cinema/video/123", "https://www.tiktok.com/@telonyx_cinema/video/no", "http://www.tiktok.com/@telonyx_cinema/video/123"] {
            #expect(!DiscoveredShort.isTargetPublication(url))
        }
    }

    @Test("Downloaded media must be short vertical video with suitable audio")
    func sourceValidation() throws {
        func source(width: Int = 1080, height: Int = 1920, duration: String = "25", language: String = "rus", audio: Bool = true) throws -> Data {
            var streams: [[String: Any]] = [["codec_type": "video", "width": width, "height": height]]
            if audio { streams.append(["codec_type": "audio", "tags": ["language": language]]) }
            return try JSONSerialization.data(withJSONObject: ["streams": streams, "format": ["duration": duration]])
        }
        #expect(try ShortsDiscoveryService.validateSource(source(), end: 25) == 25)
        #expect(try ShortsDiscoveryService.validateSource(source(language: "und"), end: 0) == 25)
        #expect(try ShortsDiscoveryService.validateSource(source(language: "eng"), end: 0, audioLanguage: "ru") == 25)
        for data in try [source(width: 1920, height: 1080), source(duration: "181"), source(language: "eng"), source(audio: false), source(duration: "nan")] {
            #expect(throws: (any Error).self) { try ShortsDiscoveryService.validateSource(data, end: 0) }
        }
        #expect(throws: (any Error).self) { try ShortsDiscoveryService.validateSource(source(), end: 30) }
    }

    @Test("Interrupted publication survives reopening and cannot be queued again")
    @MainActor func interruptedPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ShortsLibrary(directory: directory)
        var card = DiscoveredShort(id: "abcdefghijk", title: "Драйв", channel: "Кино", duration: 20, views: 500, film: "Драйв", caption: "Кино", end: 20)
        card.status = .publishing
        library.cards = [card]
        try library.save()
        let restored = ShortsLibrary(directory: directory)
        #expect(restored.cards[0].status == .needsReview)
        #expect(!restored.cards[0].canPublish)
        #expect(restored.selectedReady.isEmpty)
        #expect(ShortsLibrary(directory: directory).cards[0].status == .needsReview)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_SHORTS_LIVE"] == "1"))
    @MainActor func liveDownloadAndWatermark() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcast-shorts-smoke-\(UUID().uuidString)")
        let library = ShortsLibrary(directory: directory)
        let discovered = try await ShortsDiscoveryService().discover(films: ["Бойцовский клуб"], category: "сильные диалоги")
        #expect(!discovered.isEmpty)
        print("Live Shorts discovered: \(discovered.count)")
        var card = DiscoveredShort(id: "rJoigAoshmo", title: "Суровая философия Тайлера | Бойцовский клуб", channel: "YouTube",
            duration: 32, views: 300_000, film: "Бойцовский клуб", caption: "Тест", end: 5)
        card.reviewed = true
        library.cards = [card]
        try library.save()
        await library.process(card.id)
        #expect(library.cards[0].canPublish, "\(library.message)")
        #expect(library.cards[0].outputPath != nil)
        print("Shorts smoke output: \(library.cards[0].outputPath ?? library.message)")
    }

    @Test("Typewriter frames use BLACKFORGE's font, then hold the complete mark")
    @MainActor func typewriterFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pattern = try ShortsWatermark.writeFrames(in: directory)
        #expect(pattern.lastPathComponent == "frame-%02d.png")
        let frames = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        #expect(frames.count == ShortsWatermark.frameCount)
        #expect(try Data(contentsOf: frames[0]) != Data(contentsOf: frames.last!))
        #expect(ShortsWatermark.filter.contains("eof_action=repeat"))
        #expect(ShortsWatermark.filter.contains("H-h-240"))
        #expect(ShortsWatermark.opacity == 0.5)
    }

    @Test("Older exports need the new watermark before automatic publication")
    @MainActor func legacyExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ShortsLibrary(directory: directory)
        let file = directory.appendingPathComponent("export.mp4")
        try Data([0]).write(to: file)
        var card = DiscoveredShort(id: "abcdefghijk", title: "Драйв", channel: "Кино", duration: 20, views: 500, film: "Драйв", caption: "Кино", end: 20)
        card.status = .ready; card.outputPath = file.path
        library.cards = [card]
        try library.save()
        let restored = ShortsLibrary(directory: directory)
        #expect(!restored.cards[0].canPublish)
        restored.update(card.id) { $0.watermarkVersion = ShortsWatermark.version }
        #expect(restored.cards[0].canPublish)
        #expect(ShortsLibrary(directory: directory).cards[0].canPublish)
    }

    private struct PublicationStub: BrowserPublishingProtocol {
        var auth = BrowserAuthStatus(tiktok: true, youtube: false, tiktokHandle: "telonyx_cinema")
        let events: [BrowserPublishEvent]
        func checkAuthStatus() async throws -> BrowserAuthStatus { auth }
        func openLoginSession() async throws -> BrowserAuthStatus { auth }
        func publish(job: BrowserUploadJob) -> AsyncThrowingStream<BrowserPublishEvent, Error> {
            #expect(job.expectedTikTokHandle == "telonyx_cinema")
            #expect(job.platforms == ["tiktok"])
            return AsyncThrowingStream { continuation in
                events.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    @Test("Publication keeps pre-upload failures retryable, ambiguous outcomes require review")
    @MainActor func publishingLifecycle() async throws {
        let receipt = "https://www.tiktok.com/@telonyx_cinema/video/123456789"
        let scenarios: [([BrowserPublishEvent], DiscoveredShort.Status, String)] = [
            ([.failure(platform: "tiktok", message: "Wrong account. File not uploaded", uploadStarted: false)], .ready, "telonyx_cinema"),
            ([.failure(platform: "tiktok", message: "Uploaded, outcome unknown", uploadStarted: true)], .needsReview, "telonyx_cinema"),
            ([.failure(platform: nil, message: "Unknown process error")], .needsReview, "telonyx_cinema"),
            ([.success(platform: "tiktok", message: "Done", url: receipt), .finished(allResults: ["tiktok": "success"])], .published, "telonyx_cinema"),
            ([.success(platform: "tiktok", message: "Done", url: "https://www.tiktok.com/@other/video/123"), .finished(allResults: ["tiktok": "success"])], .needsReview, "telonyx_cinema"),
            ([.finished(allResults: ["tiktok": "success"])], .needsReview, "telonyx_cinema"),
            ([.failure(platform: "tiktok", message: "Must never reach upload")], .ready, "other_owner")
        ]
        for (events, expected, handle) in scenarios {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = ShortsLibrary(directory: directory, browser: PublicationStub(auth: .init(tiktok: true, youtube: false, tiktokHandle: handle), events: events))
            let file = directory.appendingPathComponent("ready.mp4")
            try Data([0]).write(to: file)
            var card = DiscoveredShort(id: "abcdefghijk", title: "Драйв", channel: "Кино", duration: 20, views: 500, film: "Драйв", caption: "Кино", end: 20)
            card.status = .ready; card.outputPath = file.path; card.watermarkVersion = ShortsWatermark.version
            library.cards = [card]; library.selected = [card.id]
            try library.save()
            await library.publishSelected()
            #expect(library.cards[0].status == expected)
            #expect(ShortsLibrary(directory: directory).cards[0].status == expected)
            if expected == .published {
                #expect(library.cards[0].publishedURL == receipt)
                #expect(library.selectedReady.isEmpty)
                await library.publishSelected()
                #expect(library.cards[0].status == .published)
            }
        }
    }

    @Test("Unreadable manifest is retained and never overwritten")
    @MainActor func corruptLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("library.json"), data = Data("broken".utf8)
        try data.write(to: manifest)
        let library = ShortsLibrary(directory: directory)
        #expect(!library.storageAvailable)
        #expect(throws: (any Error).self) { try library.save() }
        #expect(try Data(contentsOf: manifest) == data)
    }
}
