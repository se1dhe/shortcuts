import Foundation
import Observation

/// Holds the "Movie Shorts" / "Search" browser state so it survives navigation
/// away to processing and back. Without this, the grid re-mounted empty and
/// reloaded every time the user returned from a processed clip.
@MainActor
@Observable
final class MovieShortsBrowserModel {

    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case search
        case shorts
        var id: String { rawValue }
    }

    /// Which sub-tab is showing. Persisted so returning from a processed
    /// recommendation lands back on the Movie Shorts list.
    var selectedTab: Tab = .search

    /// The recommended movie-shorts grid, kept across mounts.
    var results: [YouTubeSearchResult] = []
    var isLoading = false
    var downloadingID: String?
    var errorMessage: String?

    /// True once the first load finished, so re-mounting doesn't reload.
    var hasLoaded = false

    /// Set when the currently-processing clip came from the recommendations
    /// grid — drives the "Back to shorts" button in the results screens.
    var cameFromRecommendations = false

    /// Remove a result from the grid (skipped or processed) with no reload.
    func remove(id: String) {
        results.removeAll { $0.id == id }
    }
}
