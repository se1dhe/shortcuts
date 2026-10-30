import AVFoundation
import Foundation
import Testing
@testable import Shortcast

/// Explicit local QA. This suite NEVER calls browser or Telegram publishing.
@Suite("Live essay release", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_RELEASE"] == "1"))
@MainActor
struct LiveEssayReleaseTests {
    @Test func buildsTwoTrailersWithoutChangingTheEssay() async throws {
        let env = ProcessInfo.processInfo.environment
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club") && $0.longformResult != nil
        })
        let essay = try #require(project.longformResult), transcript = try #require(project.transcript)
        let path = try #require(env["SHORTCAST_RELEASE_SOURCE"])
        let archive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shortcast/Projects/\(project.id.uuidString).shortcastproj")
        let before = try Data(contentsOf: archive)
        let originalFile = try FileManager.default.attributesOfItem(atPath: essay.outputURL.path)
        let settings = AppSettings()
        let manager = ModelManager()
        let shorts: [EssayShort]
        if let saved = env["SHORTCAST_RELEASE_REUSE_PLAN"] {
            let previous = try JSONDecoder().decode(EssayRelease.self, from: Data(contentsOf: URL(fileURLWithPath: saved)))
            guard previous.essayKey == EssayRelease.key(for: essay.arc), previous.shorts.count == 2 else {
                throw EssayReleaseError.invalid("Saved model plan belongs to a different essay")
            }
            let rows = previous.shorts.map { ["candidateID": $0.candidateID ?? "", "title": $0.title, "angle": $0.angle,
                "hook": $0.hook, "why": $0.why, "payoffQuote": $0.payoffQuote, "question": $0.question] }
            let raw = String(data: try JSONSerialization.data(withJSONObject: ["shorts": rows]), encoding: .utf8)!
            var checked = try EssayShortDirector.parse(raw, catalogue: EssayShortDirector.catalogue(arc: essay.arc, transcript: transcript))
            for index in checked.indices { checked[index].selectionModelID = previous.shorts[index].selectionModelID }
            shorts = checked
            print("RELEASE_PROBE re-rendering verified saved model choices")
        } else {
            print("RELEASE_PROBE preparing director")
            try await manager.requireDirector(profile: settings.copywriterModel.directorProfile)
            let finder = manager.momentFinder
            let gateway = DirectorChatGateway(readiness: { await finder.isReady }, identifier: { await finder.profile.modelID },
                completion: { instructions, prompt, tokens in await finder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: tokens) })
            shorts = try await EssayShortDirector(model: gateway).plan(arc: essay.arc, transcript: transcript)
        }
        print("RELEASE_PROBE plans=\(shorts.map(\.title).joined(separator: " | "))")
        var release = project.essayRelease ?? EssayRelease(essayKey: EssayRelease.key(for: essay.arc))
        release.shorts = shorts
        let film = essay.outputURL.deletingLastPathComponent()
        let directory = try ExportLayout.shortsDirectory(in: film)
        for index in release.shorts.indices {
            print("RELEASE_PROBE rendering \(index + 1)/2")
            release.shorts[index] = try await EssayShortRenderer().render(release.shorts[index],
                sourceURL: URL(fileURLWithPath: path), result: essay, transcript: transcript,
                telegramURL: env["SHORTCAST_RELEASE_TELEGRAM_URL"]
                    ?? LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId), directory: directory,
                diagnosticsDirectory: env["SHORTCAST_RELEASE_CAMERA_DIAGNOSTICS"].map { URL(fileURLWithPath: $0) })
            let url = try #require(release.shorts[index].outputURL)
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            #expect(size == CGSize(width: 1080, height: 1920))
            #expect((38...58.04).contains(duration))
            #expect(abs(duration - release.shorts[index].duration) < 0.10)
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            let beginning = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let ending = try await generator.image(at: CMTime(seconds: duration - 1, preferredTimescale: 600)).image
            #expect(Self.meanLight(beginning, region: CGRect(x: 70, y: 30, width: 940, height: 280)) > 12)
            #expect(Self.meanLight(ending, region: CGRect(x: 70, y: 540, width: 940, height: 540)) > 12)
            // Inspect the first fade and both sides of every source cut. A
            // probe only at one second misses the green compositor padding.
            let matteProbe = AVAssetImageGenerator(asset: asset)
            matteProbe.appliesPreferredTrackTransform = true
            matteProbe.maximumSize = CGSize(width: 270, height: 480)
            matteProbe.requestedTimeToleranceBefore = .zero
            matteProbe.requestedTimeToleranceAfter = .zero
            var times = (0...12).map { Double($0) / 30 }
            var cursor = 0.0
            for segment in release.shorts[index].segments {
                cursor += segment.duration
                times += [-0.13, -0.10, -0.067, -0.033, 0, 0.033, 0.067, 0.10, 0.13].map { cursor + $0 }
            }
            for time in times where time >= 0 && time < duration {
                let frame = try await matteProbe.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                #expect(Self.meanLight(frame, region: CGRect(x: 2, y: 2, width: 8, height: 60), measuringTint: true) < 4,
                        "Top matte must stay black at \(time)s")
                #expect(Self.meanLight(frame, region: CGRect(x: 2, y: 418, width: 8, height: 60), measuringTint: true) < 4,
                        "Bottom matte must stay black at \(time)s")
            }
            print("RELEASE_PROBE video=\(url.path) duration=\(duration)")
        }
        let afterFile = try FileManager.default.attributesOfItem(atPath: essay.outputURL.path)
        #expect(originalFile[.size] as? Int == afterFile[.size] as? Int)
        #expect(originalFile[.modificationDate] as? Date == afterFile[.modificationDate] as? Date)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(release).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-essay-release-live.json"), options: .atomic)
        if env["SHORTCAST_ADOPT_RELEASE"] == "1" {
            guard try Data(contentsOf: archive) == before else { throw EssayReleaseError.invalid("Project changed during live QA") }
            let backup = "/private/tmp/shortcast-before-essay-release-\(UUID().uuidString).shortcastproj"
            try before.write(to: URL(fileURLWithPath: backup), options: .atomic)
            var updated = project; updated.essayRelease = release
            try await FilmProjectService.shared.saveProject(updated)
            print("RELEASE_PROBE backup=\(backup)")
        }
    }

    private static func meanLight(_ image: CGImage, region: CGRect, measuringTint: Bool = false) -> Double {
        guard let crop = image.cropping(to: region) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: 64 * 32 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let context = CGContext(data: buffer.baseAddress, width: 64, height: 32, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 32))
            }
        }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0.0) { total, index in
            let r = Double(bytes[index]), g = Double(bytes[index + 1]), b = Double(bytes[index + 2])
            return total + (measuringTint ? max(r, g, b) - min(r, g, b) : (r + g + b) / 3)
        } / Double(64 * 32)
    }
}
