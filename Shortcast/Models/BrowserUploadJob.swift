import Foundation

/// Specific tailored viral content for a single social platform.
struct PlatformUploadContent: Sendable, Codable, Equatable {
    var title: String?
    var caption: String
    var hashtags: [String]
    var thumbnailPath: String?

    init(
        title: String? = nil,
        caption: String,
        hashtags: [String] = [],
        thumbnailPath: String? = nil
    ) {
        self.title = title
        self.caption = caption
        self.hashtags = hashtags
        self.thumbnailPath = thumbnailPath
    }
}

/// Defines a browser automation upload task across platforms.
struct BrowserUploadJob: Sendable, Codable, Equatable {
    var videoPath: String
    var thumbnailPath: String?
    var platforms: [String]
    var platformContent: [String: PlatformUploadContent]?
    var title: String
    var caption: String
    var hashtags: [String]
    var isPublic: Bool
    var headless: Bool
    var isShort: Bool? = nil
    var action: String? = nil
    var targetVideoURL: String? = nil
    var pinnedComment: String? = nil

    init(
        videoURL: URL,
        thumbnailURL: URL? = nil,
        platforms: Set<SocialPlatform>,
        platformContent: [String: PlatformUploadContent]? = nil,
        title: String,
        caption: String,
        hashtags: [String] = [],
        isPublic: Bool = true,
        headless: Bool = true,
        isShort: Bool = false,
        action: String? = nil,
        targetVideoURL: String? = nil,
        pinnedComment: String? = nil
    ) {
        self.videoPath = videoURL.path
        self.thumbnailPath = thumbnailURL?.path
        self.platforms = platforms.map(\.rawValue)
        self.platformContent = platformContent
        self.title = title
        self.caption = caption
        self.hashtags = hashtags
        self.isPublic = isPublic
        self.headless = headless
        self.isShort = isShort
        self.action = action
        self.targetVideoURL = targetVideoURL
        self.pinnedComment = pinnedComment
    }
}

/// Status of account sessions in the local Chrome profile.
struct BrowserAuthStatus: Sendable, Codable, Equatable {
    var tiktok: Bool
    var youtube: Bool

    init(tiktok: Bool = false, youtube: Bool = false) {
        self.tiktok = tiktok
        self.youtube = youtube
    }

    var hasAnyConnected: Bool {
        tiktok || youtube
    }
}

/// Live streaming events emitted during a browser publishing run.
enum BrowserPublishEvent: Sendable {
    case progress(platform: String?, message: String)
    case captchaDetected(platform: String, message: String)
    case success(platform: String, message: String, url: String?)
    case failure(platform: String?, message: String)
    case finished(allResults: [String: String])
}
