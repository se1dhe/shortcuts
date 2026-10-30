import Foundation
import Observation
import SwiftUI

/// Preferences used by the film → essay → shorts pipeline.
@MainActor
@Observable
final class AppSettings {
    enum CopywriterModel: String, CaseIterable, Identifiable, Sendable {
        case qwen35_9b = "qwen"
        case gemma12B = "gemma12b"
        var id: String { rawValue }
        var displayName: String { self == .gemma12B ? "Gemma 4 12B" : "Qwen 3.5 9B" }
        var directorProfile: ChatModelProfile { self == .gemma12B ? .gemma12B : .qwen35_9b }
    }
    var tmdbAPIKey: String { didSet { defaults.set(tmdbAPIKey, forKey: Keys.tmdbApiKey) } }
    var telegramBotToken: String { didSet { defaults.set(telegramBotToken, forKey: Keys.telegramBotToken) } }
    var telegramChannelId: String { didSet { defaults.set(telegramChannelId, forKey: Keys.telegramChannelId) } }
    var languageOverride: String { didSet { defaults.set(languageOverride, forKey: Keys.language) } }
    var copywriterModel: CopywriterModel { didSet { defaults.set(copywriterModel.rawValue, forKey: Keys.copywriter) } }
    var channelLogoWatermarkEnabled: Bool { didSet { defaults.set(channelLogoWatermarkEnabled, forKey: Keys.channelLogoWatermark) } }

    /// User-selected output folder for downloads and exports. Uses a security-scoped
    /// bookmark so the app keeps access across launches. nil → use temp directory.
    var outputDirectory: URL? {
        get {
            guard let data = defaults.data(forKey: Keys.outputDirectoryBookmark) else { return nil }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            else { return nil }
            if isStale, let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(newData, forKey: Keys.outputDirectoryBookmark)
            }
            return url
        }
        set {
            if let url = newValue {
                let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(data, forKey: Keys.outputDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.outputDirectoryBookmark)
            }
        }
    }

    /// Human-readable path of the output directory (or "Temporary folder").
    var outputDirectoryLabel: String {
        outputDirectory?.path(percentEncoded: false) ?? String(localized: "Temporary folder (system)")
    }

    /// App's working directory — where input files are copied before processing
    /// so every consumer (AVAsset, Gemma4VideoProcessor) has unrestricted access.
    /// Falls back to the system temp directory when nil.
    var workingDirectory: URL? {
        get {
            guard let data = defaults.data(forKey: Keys.workingDirectoryBookmark) else { return nil }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            else { return nil }
            if isStale, let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(newData, forKey: Keys.workingDirectoryBookmark)
            }
            return url
        }
        set {
            if let url = newValue {
                let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(data, forKey: Keys.workingDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.workingDirectoryBookmark)
            }
        }
    }

    /// Human-readable path of the working directory (or "System temporary folder").
    var workingDirectoryLabel: String {
        workingDirectory?.path(percentEncoded: false) ?? String(localized: "System temporary folder")
    }

    /// Whether the working directory has been chosen and its bookmark is still
    /// valid (not stale). Used by the first-launch flow.
    var hasWorkingDirectory: Bool {
        workingDirectory != nil
    }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tmdbAPIKey = defaults.string(forKey: Keys.tmdbApiKey) ?? ""
        self.telegramBotToken = defaults.string(forKey: Keys.telegramBotToken) ?? ""
        self.telegramChannelId = defaults.string(forKey: Keys.telegramChannelId) ?? "@telonyx_club"
        self.languageOverride = defaults.string(forKey: Keys.language) ?? "uk"
        self.copywriterModel = defaults.string(forKey: Keys.copywriter).flatMap(CopywriterModel.init) ?? .gemma12B
        self.channelLogoWatermarkEnabled = defaults.object(forKey: Keys.channelLogoWatermark) as? Bool ?? true

    }
    private enum Keys {
        static let tmdbApiKey = "shortcast.tmdbApiKey"
        static let telegramBotToken = "shortcast.telegramBotToken"
        static let telegramChannelId = "shortcast.telegramChannelId"
        static let language = "shortcast.languageOverride"
        static let copywriter = "shortcast.copywriterModel"
        static let channelLogoWatermark = "shortcast.channelLogoWatermarkEnabled"
        static let outputDirectoryBookmark = "shortcast.outputDirectoryBookmark"
        static let workingDirectoryBookmark = "shortcast.workingDirectoryBookmark"
    }
}
