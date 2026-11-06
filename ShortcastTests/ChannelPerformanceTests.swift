import Foundation
import Testing
@testable import Shortcast

@Suite("Automatic channel feedback")
struct ChannelPerformanceTests {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)
    private func target(_ platform: String = "youtube") -> ChannelPerformance.Target {
        .init(projectID: UUID(), platform: platform, format: "short", videoID: platform == "youtube" ? "dVrzGnPNIzE" : "7703709443006991636",
            url: URL(string: platform == "youtube" ? "https://www.youtube.com/watch?v=dVrzGnPNIzE" : "https://www.tiktok.com/@kadr_sens/video/7703709443006991636")!,
            title: "Вибір героя", hook: "Орел чи решка?")
    }
    private func youtube(_ count: String = "1200", id: String = "dVrzGnPNIzE") -> String {
        "<script>var ytInitialPlayerResponse = {\"videoDetails\":{\"videoId\":\"\(id)\",\"viewCount\":\"\(count)\",\"title\":\"Орел { чи } решка?\"}};</script>"
    }

    @Test("Only an exact video's public counter is accepted; missing is not zero")
    func counters() throws {
        #expect(try ChannelPerformanceService.parse(youtube(), target: target(), now: now).views == 1200)
        #expect(try ChannelPerformanceService.parse(youtube("0"), target: target(), now: now).views == 0)
        for html in [youtube(id: "wrongVideo1"), youtube("1.2K"), youtube("-1"), "<html>Sign in</html>", "ytInitialPlayerResponse = {\"videoDetails\":{"] {
            #expect(throws: (any Error).self) { try ChannelPerformanceService.parse(html, target: target(), now: now) }
        }
        let html = #"<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":{"id":"7703709443006991636","createTime":"1793659640","stats":{"playCount":614}}}}}}</script>"#
        let sample = try ChannelPerformanceService.parse(html, target: target("tiktok"), now: now)
        #expect(sample.views == 614 && sample.publishedAt != nil)
        #expect(throws: (any Error).self) { try ChannelPerformanceService.parse(html.replacingOccurrences(of: "614", with: "null"), target: target("tiktok"), now: now) }
    }

    @Test("Refresh retains successful history on failure and does not poll within six hours")
    func refresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ChannelPerformanceService(cacheURL: directory.appendingPathComponent("observations.json"))
        let target = target(), html = youtube()
        let first = try await service.refresh(targets: [target], now: now, fetch: { _ in html })
        #expect(first[0].latest?.views == 1200)
        let cached = try await service.refresh(targets: [target], now: now.addingTimeInterval(10), fetch: { _ in Issue.record("Unexpected network request"); throw URLError(.notConnectedToInternet) })
        #expect(cached == first)
        let failed = try await service.refresh(targets: [target], now: now.addingTimeInterval(7 * 3600), fetch: { _ in throw URLError(.notConnectedToInternet) })
        #expect(failed[0].latest == first[0].latest && failed[0].issue != nil)
        #expect(try await service.cached() == failed)
    }

    @Test("A damaged cache is preserved instead of replaced with an empty history")
    func corruptCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("broken cache".utf8); try original.write(to: url)
        let service = ChannelPerformanceService(cacheURL: url)
        await #expect(throws: (any Error).self) { try await service.refresh(targets: [target()], fetch: { _ in youtube() }) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Feedback carries provenance and formats, omits stale counters and private metric guesses")
    func feedback() throws {
        var report = ChannelPerformance(target: target(), samples: [.init(date: now, views: 1200)])
        let text = try #require(ChannelPerformance.feedback([report], now: now))
        #expect(text.contains("youtube") && text.contains("1200") && text.contains("observedAt"))
        #expect(!text.contains("\"ctr\"") && !text.contains("\"retentionPercent\""))
        #expect(ChannelPerformance.feedback([report], now: now.addingTimeInterval(8 * 86400)) == nil)
        report.samples = []
        #expect(ChannelPerformance.feedback([report], now: now) == nil)
    }

    @Test("Only confirmed video deliveries become targets, never comments or interrupted uploads")
    func targets() {
        var project = FilmProject(sourceMovieURL: URL(fileURLWithPath: "/tmp/film.mp4"), movieFileName: "film.mp4", movieTitle: "Фільм")
        var release = EssayRelease(essayKey: "test")
        release.receipts = [
            "essay.youtube": .init(state: .published, url: "https://youtu.be/dVrzGnPNIzE", message: ""),
            "essay.youtube.comment": .init(state: .published, url: "https://youtu.be/dVrzGnPNIzE", message: ""),
            "short1.tiktok": .init(state: .published, url: "https://www.tiktok.com/@kadr_sens/video/7703709443006991636", message: ""),
            "short2.youtube": .init(state: .needsReview, url: "https://youtu.be/atlC-ti_ECs", message: "")]
        project.essayRelease = release
        #expect(Set(ChannelPerformance.targets(in: project).map(\.id)) == ["youtube:dVrzGnPNIzE", "tiktok:7703709443006991636"])
    }

    @Test("Live public counters can be collected without a publishing session")
    func liveCounters() async throws {
        guard ProcessInfo.processInfo.environment["SHORTCAST_LIVE_COUNTERS"] == "1" else { return }
        for platform in ["youtube", "tiktok"] {
            let target = target(platform)
            let html = try await ChannelPerformanceService.fetchPage(target.url)
            let sample = try ChannelPerformanceService.parse(html, target: target, now: Date())
            print("Public counter verified: \(platform) \(target.videoID), views=\(sample.views)")
            #expect(sample.views >= 0)
        }
    }
}
