import Foundation

/// Represents a pending user decision when a video container has multiple audio tracks.
/// Adheres to Single Responsibility Principle (SRP).
struct PendingAudioSelection: Identifiable, Sendable {
    let id = UUID()
    let videoURL: URL
    let sourceMetadata: VideoSourceMetadata?
    let tracks: [AudioTrackInfo]
    var selectedTrackId: Int
}
