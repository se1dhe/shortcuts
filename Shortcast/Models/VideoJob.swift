import Foundation

struct VideoSourceMetadata: Sendable, Equatable {
    var title: String
    var description: String = ""
    var webpageURL: URL?
}

/// A short video the user dropped onto the window, plus the metadata Shortcast
/// needs to process and publish it.
struct VideoJob: Identifiable, Sendable, Equatable {
    let id = UUID()
    let url: URL
    let durationSeconds: Double
    let sourceMetadata: VideoSourceMetadata?
    let originalFileName: String?

    init(
        url: URL,
        durationSeconds: Double,
        sourceMetadata: VideoSourceMetadata? = nil,
        originalFileName: String? = nil
    ) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.sourceMetadata = sourceMetadata
        self.originalFileName = originalFileName
    }

    var fileName: String { url.lastPathComponent }

    /// Returns a human-friendly title candidate, prioritizing metadata and original file name over internal temp names.
    var effectiveTitle: String {
        if let metaTitle = sourceMetadata?.title,
           !metaTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return metaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let orig = originalFileName,
           !orig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return orig.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fileBase = (fileName as NSString).deletingPathExtension
        return fileBase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `m:ss`, e.g. `0:42`.
    var durationLabel: String {
        let total = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Shorts/Reels/TikTok run to ~60s. Longer videos still work, but the audio
    /// tower only hears the first 30s — surface that to the user.
    var exceedsRecommendedLength: Bool { durationSeconds > 60.5 }
}
