import Foundation

struct ProcessedVideoRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let youtubeURL: URL
    let videoID: String
    let title: String
    let dateProcessed: Date
    var hook: String
    var description: String
    var hashtags: String

    init(
        id: UUID = UUID(),
        youtubeURL: URL,
        videoID: String,
        title: String,
        dateProcessed: Date = Date(),
        hook: String = "",
        description: String = "",
        hashtags: String = ""
    ) {
        self.id = id
        self.youtubeURL = youtubeURL
        self.videoID = videoID
        self.title = title
        self.dateProcessed = dateProcessed
        self.hook = hook
        self.description = description
        self.hashtags = hashtags
    }
}
