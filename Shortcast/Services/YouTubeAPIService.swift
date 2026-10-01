import Foundation
import os

/// Uses the official YouTube Data API v3 to search for Shorts.
/// Unlike yt-dlp search, the API reliably returns true YouTube Shorts
/// when filtered with videoDuration=short + relevanceLanguage=ru.
enum YouTubeAPIService {

    enum SearchError: LocalizedError {
        case missingKey
        case network(Error)
        case invalidResponse
        case api(message: String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "YouTube API key is missing. Add it in Settings.")
            case .network(let error):
                return String(format: String(localized: "Network error: %@"), error.localizedDescription)
            case .invalidResponse:
                return String(localized: "Unexpected response from YouTube API.")
            case .api(let message):
                return String(format: String(localized: "YouTube API: %@"), message)
            }
        }
    }

    private static let cacheLock = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])

    private struct CacheEntry {
        let results: [YouTubeSearchResult]
        let timestamp: Date
    }

    static func searchShorts(
        apiKey: String,
        queries: [String] = MovieShortsSearchDefaults.queries,
        limit: Int = 10,
        excludedIDs: Set<String> = [],
        forceRefresh: Bool = false
    ) async throws -> [YouTubeSearchResult] {
        guard !apiKey.trimmed.isEmpty else {
            throw SearchError.missingKey
        }

        let queries = queries.isEmpty
            ? MovieShortsSearchDefaults.queries
            : queries

        let cacheKey = queries.joined(separator: "\n")
        if !forceRefresh,
           let cached = cacheLock.withLock({ dict in
               guard let entry = dict[cacheKey], Date().timeIntervalSince(entry.timestamp) < 600 else { return nil as [YouTubeSearchResult]? }
               return entry.results
           })
        {
            return cached
                .filter { !excludedIDs.contains($0.id) }
                .prefix(limit)
                .map { $0 }
        }

        var allResults: [YouTubeSearchResult] = []

        for query in queries.shuffled() {
            try Task.checkCancellation()
            let searchItems = try await performSearch(
                query: query,
                apiKey: apiKey,
                maxResults: 50)

            let videoIDs = searchItems.compactMap { $0.id?.videoId }

            guard !videoIDs.isEmpty else { continue }

            let durations = try await fetchDurations(
                videoIDs: videoIDs,
                apiKey: apiKey)

            for item in searchItems {
                guard let vid = item.id?.videoId,
                      let snippet = item.snippet else { continue }

                let duration = durations[vid] ?? 0
                guard duration > 0, duration <= 60 else { continue }

                let result = YouTubeSearchResult(
                    id: vid,
                    title: snippet.title ?? "",
                    description: snippet.description ?? "",
                    channel: snippet.channelTitle ?? "",
                    durationSeconds: duration,
                    uploadDate: snippet.publishedAt?.prefix(10).replacingOccurrences(of: "-", with: ""),
                    webpageURL: URL(string: "https://www.youtube.com/shorts/\(vid)")
                        ?? URL(string: "https://www.youtube.com/watch?v=\(vid)")!)

                // Keep only foreign films/series that carry a Russian dub — drop
                // Russian-origin productions and subtitle-only clips.
                guard MovieShortsRelevanceFilter.isRelevant(result) else { continue }

                allResults.append(result)
            }

            var seen = Set<String>()
            allResults = allResults.filter { seen.insert($0.id).inserted }
        }

        let finalResults = allResults

        cacheLock.withLock { dict in
            dict[cacheKey] = CacheEntry(results: finalResults, timestamp: Date())
        }

        return finalResults
            .filter { !excludedIDs.contains($0.id) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Network helpers

    private static func performSearch(
        query: String,
        apiKey: String,
        maxResults: Int
    ) async throws -> [YTSearchItem] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoDuration", value: "short"),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "relevanceLanguage", value: "ru"),
            URLQueryItem(name: "key", value: apiKey),
        ]

        guard let url = components.url else {
            throw SearchError.invalidResponse
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(YTSearchResponse.self, from: data)

        if let error = response.error {
            throw SearchError.api(message: error.message)
        }

        return response.items ?? []
    }

    private static func fetchDurations(
        videoIDs: [String],
        apiKey: String
    ) async throws -> [String: Double] {
        let ids = videoIDs.joined(separator: ",")
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "id", value: ids),
            URLQueryItem(name: "key", value: apiKey),
        ]

        guard let url = components.url else {
            throw SearchError.invalidResponse
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(YTVideosResponse.self, from: data)

        var map: [String: Double] = [:]
        for item in response.items ?? [] {
            if let duration = item.contentDetails?.duration {
                map[item.id] = parseISODuration(duration)
            }
        }
        return map
    }

    // MARK: - Duration parser

    private static func parseISODuration(_ value: String) -> Double {
        var seconds: Double = 0
        let scanner = Scanner(string: value)
        _ = scanner.scanString("PT")
        while !scanner.isAtEnd {
            if let number = scanner.scanDouble() {
                if scanner.scanString("H") != nil {
                    seconds += number * 3600
                } else if scanner.scanString("M") != nil {
                    seconds += number * 60
                } else if scanner.scanString("S") != nil {
                    seconds += number
                } else {
                    // consume unknown char
                    _ = scanner.scanCharacter()
                }
            } else {
                _ = scanner.scanCharacter()
            }
        }
        return seconds
    }
}

// MARK: - Codable models

private struct YTSearchResponse: Decodable {
    let items: [YTSearchItem]?
    let error: YTAPIError?
}

private struct YTSearchItem: Decodable {
    let id: YTSearchItemID?
    let snippet: YTSnippet?
}

private struct YTSearchItemID: Decodable {
    let videoId: String?
}

private struct YTSnippet: Decodable {
    let title: String?
    let description: String?
    let channelTitle: String?
    let publishedAt: String?
}

private struct YTVideosResponse: Decodable {
    let items: [YTVideoItem]?
    let error: YTAPIError?
}

private struct YTVideoItem: Decodable {
    let id: String
    let contentDetails: YTContentDetails?
}

private struct YTContentDetails: Decodable {
    let duration: String?
}

private struct YTAPIError: Decodable {
    let message: String
}
