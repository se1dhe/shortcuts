import Foundation

struct TMDBMovie: Sendable, Equatable, Identifiable {
    /// TMDB numeric id when known; 0 for model-inferred movies.
    var tmdbID: Int = 0
    var title: String
    var year: String
    var genres: [String]
    var overview: String
    var cast: [String]
    var director: String?
    
    // Ratings
    var imdbRating: Double?
    var rottenTomatoesScore: Int? // 0-100%

    // Artwork
    var posterPath: String?
    var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780\(posterPath)")
    }

    /// Stable identity for pickers. Falls back to title+year when there is no
    /// TMDB id (e.g. a movie the on-device model inferred).
    var id: String { tmdbID != 0 ? "tmdb-\(tmdbID)" : "\(title)|\(year)" }

    /// Compact label for the disambiguation dropdown, e.g. "Острые козырьки (2013)".
    var pickerLabel: String {
        year.isEmpty ? title : "\(title) (\(year))"
    }
}

enum TMDBError: LocalizedError {
    case noAPIKey
    case notFound(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "TMDB API key is not set."
        case .notFound(let q): "Movie not found: \(q)"
        case .network(let e): e.localizedDescription
        }
    }
}

struct TMDBService {
    let apiKey: String

    func searchMovie(by title: String, year: String? = nil) async throws -> TMDBMovie? {
        try await searchMovies(by: title, year: year).first
    }

    /// Returns up to `limit` fully-resolved candidates (title, year, genres,
    /// cast, director, synopsis), best match first. Lets the UI disambiguate
    /// between similar titles, e.g. "Острые козырьки" and its spin-offs.
    func searchMovies(by title: String, year: String? = nil, limit: Int = 6) async throws -> [TMDBMovie] {
        guard !apiKey.trimmed.isEmpty else { throw TMDBError.noAPIKey }
        var items = [
            URLQueryItem(name: "query", value: title.trimmed),
            URLQueryItem(name: "language", value: "ru-RU"),
            URLQueryItem(name: "page", value: "1"),
        ]
        if let year = year?.trimmed, !year.isEmpty {
            items.append(URLQueryItem(name: "year", value: year))
            items.append(URLQueryItem(name: "primary_release_year", value: year))
        }

        guard let request = buildRequest(path: "/search/movie", queryItems: items) else {
            throw TMDBError.noAPIKey
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        let ordered = orderedResults(results, requestedYear: year)
        // Resolve the genre id→name map once, reuse for every candidate.
        let genreMap = await resolveGenreMap()

        var movies: [TMDBMovie] = []
        for result in ordered.prefix(limit) {
            guard let movieId = result["id"] as? Int else { continue }
            let movieTitle = result["title"] as? String ?? title
            let releaseDate = result["release_date"] as? String ?? ""
            let movieYear = String(releaseDate.prefix(4))
            let genreIds = result["genre_ids"] as? [Int] ?? []
            let genres = genreIds.compactMap { genreMap[$0] }
            let overview = (result["overview"] as? String)?.trimmed ?? ""
            let cast = await resolveCast(movieId: movieId)
            let director = await resolveDirector(movieId: movieId)
            
            // TMDB vote_average is out of 10. We use it for IMDb and map it to 100 for RT.
            let voteAverage = result["vote_average"] as? Double
            let imdb = voteAverage
            let rt = voteAverage != nil ? Int(voteAverage! * 10) : nil
            
            let posterPath = result["poster_path"] as? String
            
            movies.append(TMDBMovie(
                tmdbID: movieId,
                title: movieTitle,
                year: movieYear,
                genres: genres,
                overview: overview,
                cast: cast,
                director: director,
                imdbRating: imdb,
                rottenTomatoesScore: rt,
                posterPath: posterPath))
        }
        return movies
    }

    /// Orders search results so a year match (when requested) comes first,
    /// otherwise keeps TMDB's own popularity ordering.
    private func orderedResults(_ results: [[String: Any]], requestedYear: String?) -> [[String: Any]] {
        guard let requestedYear = requestedYear?.trimmed, !requestedYear.isEmpty else {
            return results
        }
        let matches = results.filter { (($0["release_date"] as? String) ?? "").hasPrefix(requestedYear) }
        let rest = results.filter { !(($0["release_date"] as? String) ?? "").hasPrefix(requestedYear) }
        return matches + rest
    }

    private func resolveCast(movieId: Int) async -> [String] {
        guard let request = buildRequest(path: "/movie/\(movieId)/credits", queryItems: [URLQueryItem(name: "language", value: "ru-RU")]) else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let castArray = json["cast"] as? [[String: Any]] else {
            return []
        }
        return castArray.prefix(5).compactMap { $0["name"] as? String }
    }

    private func resolveDirector(movieId: Int) async -> String? {
        guard let request = buildRequest(path: "/movie/\(movieId)/credits", queryItems: [URLQueryItem(name: "language", value: "ru-RU")]) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crewArray = json["crew"] as? [[String: Any]] else {
            return nil
        }
        return crewArray.first { ($0["job"] as? String)?.lowercased() == "director" }?["name"] as? String
    }

    private func resolveGenreMap() async -> [Int: String] {
        guard let request = buildRequest(path: "/genre/movie/list", queryItems: [URLQueryItem(name: "language", value: "ru-RU")]) else { return [:] }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = json["genres"] as? [[String: Any]] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: all.compactMap {
            guard let id = $0["id"] as? Int, let name = $0["name"] as? String else { return nil }
            return (id, name)
        })
    }

    private func buildRequest(path: String, queryItems: [URLQueryItem] = []) -> URLRequest? {
        let cleanKey = apiKey.trimmed
        guard !cleanKey.isEmpty else { return nil }

        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")
        var items = queryItems

        let isBearer = cleanKey.starts(with: "eyJ")
        if !isBearer {
            items.append(URLQueryItem(name: "api_key", value: cleanKey))
        }
        components?.queryItems = items

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        if isBearer {
            request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
