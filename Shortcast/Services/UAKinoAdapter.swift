import Foundation

/// DOM contracts observed on UAKino's search and download pages, isolated from the UI and torrent engine.
enum UAKinoAdapter {
    struct SearchResult: Decodable, Sendable {
        let title: String
        let year: Int?
        let url: URL
    }
    static let torrentScript = #"JSON.stringify(Array.from(document.querySelectorAll('table.restable tbody tr')).map(row => { const cells = row.querySelectorAll('th,td'); const a = row.querySelector('a[href]'); return cells.length >= 5 && a ? {title:cells[0].innerText,size:cells[1].innerText,seeds:parseInt(cells[2].innerText),peers:parseInt(cells[3].innerText),url:a.href} : null; }).filter(Boolean))"#
    static let searchScript = #"JSON.stringify(Array.from(document.querySelectorAll('#dle-content .movie-item')).map(item => { const a=item.querySelector('a.movie-title'); const year=item.querySelector('a[href*="/find/year/"]'); return a ? {title:a.innerText.trim(),year:year ? parseInt(year.innerText) : null,url:a.href} : null; }).filter(Boolean))"#
    static let downloadLinkScript = #"Array.from(document.querySelectorAll('a[href]')).map(a=>a.href).find(href=>href.endsWith('/download.html')) || ''"#
    static let finalTorrentScript = #"Array.from(document.querySelectorAll('a[href]')).map(a=>a.href).find(href=>/\/torrent\/\d+\/.*\.torrent(?:\?|$)/.test(href)) || ''"#
    static func validFileURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "uakino.best" && url.path.range(of: #"^/torrent/\d+/.*\.torrent$"#, options: .regularExpression) != nil
    }
    static func parseTorrents(_ json: String) throws -> [FilmTorrent] {
        let rows = try JSONDecoder().decode([FilmTorrent].self, from: Data(json.utf8))
        return rows.filter { validTorrentURL($0.url) }
    }
    static func validTorrentURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "uakino.best" && url.path.range(of: #"^/download/\d+/torrent/?$"#, options: .regularExpression) != nil
    }
    static func match(_ results: [SearchResult], film: PlannedFilm) -> URL? {
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        func close(_ title: String) -> Bool {
            let a = Array(normalized(title)), b = Array(normalized(film.title))
            let tolerance = max(1, min(2, b.count / 10))
            guard abs(a.count - b.count) <= tolerance else { return false }
            var row = Array(0...b.count)
            for (i, character) in a.enumerated() {
                var next = [i + 1]
                for (j, other) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1))) }
                row = next
            }
            return (row.last ?? Int.max) <= tolerance
        }
        let matches = results.filter { $0.year == film.year && close($0.title) && $0.url.scheme == "https" && $0.url.host == "uakino.best" }
        return matches.count == 1 ? matches[0].url : nil
    }
    static func recommended(_ torrents: [FilmTorrent], availableBytes: Int64?) -> String? {
        let candidates = torrents.filter { torrent in
            guard let size = torrent.bytes, let seeds = torrent.seeds, seeds > 0,
                  torrent.title.lowercased().contains("ukr") else { return false }
            return availableBytes.map { size < $0 / 3 } ?? true
        }
        return candidates.sorted { a, b in
            let a1080 = a.title.lowercased().contains("1080p"), b1080 = b.title.lowercased().contains("1080p")
            if a1080 != b1080 { return a1080 }
            return (a.bytes ?? Int64.max) < (b.bytes ?? Int64.max)
        }.first?.id
    }
}
