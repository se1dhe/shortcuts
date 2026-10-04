import AVFoundation
import Foundation

/// Local, explainable checks run immediately before a TikTok upload.
///
/// This is deliberately a risk assessment, not a Content ID or recommendation
/// prediction service: TikTok does not expose a public API that can establish
/// music ownership or guarantee distribution before a post is submitted.
enum TikTokPreflightService {

    enum Severity: Int, Sendable, Comparable {
        case info
        case warning
        case error

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Finding: Identifiable, Sendable, Equatable {
        let id: String
        let severity: Severity
        let title: String
        let detail: String
    }

    struct Report: Sendable, Equatable {
        let checkedAt: Date
        let findings: [Finding]

        var blocksUpload: Bool { findings.contains { $0.severity == .error } }
        var highestSeverity: Severity { findings.map(\.severity).max() ?? .info }
    }

    static func check(
        videoURL: URL,
        sourceMetadata: VideoSourceMetadata?,
        tiktokVariant: PostVariant?,
        promoEnabled: Bool,
        antiCopyrightEnabled: Bool = true,
        antiCopyrightConfig: AntiCopyrightConfig? = nil
    ) async -> Report {
        var findings: [Finding] = []
        let asset = AVURLAsset(url: videoURL)

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                findings.append(blockingError("video-track", "No video track", "TikTok upload is blocked because the prepared file has no video track."))
                return Report(checkedAt: .now, findings: findings)
            }

            let duration = try await asset.load(.duration).seconds
            if !duration.isFinite || duration <= 0 {
                findings.append(blockingError("duration", "Invalid duration", "TikTok upload is blocked because the prepared file has no usable duration."))
            } else if duration < 3 {
                findings.append(warning("very-short", "Very short clip", "Clips under three seconds are often hard to understand; verify that the hook and payoff are complete."))
            } else if duration > 180 {
                findings.append(warning("long-form", "Long-form duration", "Review retention and the first seconds carefully; this is longer than a typical short-form edit."))
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let size = naturalSize.applying(transform)
            let width = abs(size.width)
            let height = abs(size.height)
            if width == 0 || height == 0 {
                findings.append(blockingError("dimensions", "Invalid video dimensions", "TikTok upload is blocked because the prepared file has invalid dimensions."))
            } else {
                let ratio = width / height
                if abs(ratio - 9.0 / 16.0) > 0.04 {
                    findings.append(warning("aspect-ratio", "Not 9:16", "The prepared file is \(Int(width))×\(Int(height)). Vertical 9:16 usually gives the best full-screen presentation."))
                }
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                findings.append(warning("no-audio", "No audio track", "The file has no audio track. Add narration or an appropriately licensed sound if that is part of the creative intent."))
            } else {
                findings.append(warning("music-rights", "Audio rights are not verified", "An audio track is present, but this app cannot identify music or prove a license. Confirm that you own the audio, have a license, or will select a permitted TikTok sound."))
            }
        } catch {
            findings.append(blockingError("unreadable", "Could not inspect prepared video", "TikTok upload is blocked until the final file can be read: \(error.localizedDescription)"))
        }

        if sourceMetadata?.webpageURL != nil {
            findings.append(warning("external-source", "External source material", "This clip originated from a web source. Confirm rights to both video and audio; edits, subtitles, and attribution alone do not grant permission."))
        }

        let caption = [tiktokVariant?.hook, tiktokVariant?.summary, tiktokVariant?.hashtagLine]
            .compactMap { $0?.trimmed }
            .joined(separator: " ")
        let hashtags = tiktokVariant?.hashtags ?? []
        if hashtags.count > 10 {
            findings.append(warning("hashtags", "Many hashtags", "Use only relevant hashtags; \(hashtags.count) were added to this TikTok caption."))
        }
        if containsEngagementBait(caption) {
            findings.append(warning("engagement-bait", "Possible engagement bait", "The caption asks for engagement. Keep calls to action natural and avoid incentives or manipulative phrasing."))
        }
        if promoEnabled {
            findings.append(warning("regulated-promo", "Promotional overlay enabled", "This post contains a promo banner. Confirm TikTok disclosure requirements and any age, gambling, or regional restrictions before publishing."))
        }

        if antiCopyrightEnabled, let cfg = antiCopyrightConfig, cfg.isActive {
            var measures: [String] = []
            if cfg.enableMirror { measures.append("зеркалирование") }
            if abs(cfg.audioPitchShiftCents) > 0.0001 { measures.append(String(format: "питч-шифт (+%.0f cents)", cfg.audioPitchShiftCents)) }
            if cfg.filmGrainIntensity > 0.01 { measures.append("35мм зерно (pHash)") }
            if cfg.enableAudioWarmthEQ { measures.append("спектральный EQ") }
            if cfg.stripMetadata { measures.append("очистка метаданных") }
            let desc = measures.joined(separator: ", ")
            findings.append(Finding(id: "anticopyright-active", severity: .info, title: "TikTok Shield активен", detail: "Контрмеры против Content ID: \(desc). Риск блокировки минимизирован."))
        } else if sourceMetadata?.webpageURL != nil {
            findings.append(warning("anticopyright-missing", "Антикопирайт выключен", "Для внешних видео и фрагментов фильмов рекомендуется включить TikTok Shield во избежание списания просмотров или страйка."))
        }

        if findings.isEmpty {
            findings.append(Finding(id: "ready", severity: .info, title: "Basic preflight passed", detail: "No technical upload blockers were found. This is not a guarantee of moderation, copyright clearance, or recommendation reach."))
        }
        return Report(checkedAt: .now, findings: findings)
    }

    private static func containsEngagementBait(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let phrases = ["like for", "follow for", "comment for", "share for", "ставь лайк", "подпишись", "поставь лайк", "напиши в комментариях"]
        return phrases.contains { normalized.contains($0) }
    }

    private static func warning(_ id: String, _ title: String, _ detail: String) -> Finding {
        Finding(id: id, severity: .warning, title: title, detail: detail)
    }

    private static func blockingError(_ id: String, _ title: String, _ detail: String) -> Finding {
        Finding(id: id, severity: .error, title: title, detail: detail)
    }
}
