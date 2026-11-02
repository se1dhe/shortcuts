import Foundation

struct PlannedFilm: Identifiable, Codable, Hashable, Sendable {
    let number: Int
    let title: String
    let year: Int
    let topic: String
    var id: String { "\(year)-" + title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "uk_UA")) }

    static func parse(_ markdown: String) -> [Self] {
        let pattern = #"(?m)^### Фільм (\d+): «([^»]+)»[^\n]*?\b((?:19|20)\d{2})\)[^\n]*\n- \*\*Тема есе:\*\* ([^\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let number = Int(ns.substring(with: m.range(at: 1))), let year = Int(ns.substring(with: m.range(at: 3))) else { return nil }
            return Self(number: number, title: ns.substring(with: m.range(at: 2)), year: year, topic: ns.substring(with: m.range(at: 4)))
        }
    }
}

struct FilmTorrent: Identifiable, Codable, Sendable, Hashable {
    var id: String { url.absoluteString }
    let title: String
    let size: String
    let seeds: Int?
    let peers: Int?
    let url: URL
    var bytes: Int64? {
        let parts = size.uppercased().replacingOccurrences(of: ",", with: ".").split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]), value.isFinite, value > 0,
              let power = ["KB": 1.0, "MB": 2, "GB": 3, "TB": 4][String(parts[1])] else { return nil }
        return Int64(min(Double(Int64.max), value * pow(1024, power)))
    }
}

/// Read only the torrent's file manifest; never trust a torrent path outside its library folder.
enum TorrentManifest {
    struct File: Identifiable, Sendable { let index: Int; let path: String; let bytes: Int64; var id: Int { index } }
    private indirect enum Value { case number(Int64), bytes(Data), list([Value]), dict([String: Value]) }
    private struct Reader {
        let bytes: [UInt8]; var position = 0
        mutating func value(_ depth: Int = 0) throws -> Value {
            guard depth < 32, position < bytes.count else { throw invalid }
            let token = bytes[position]; position += 1
            if token == 105 {
                let start = position
                while position < bytes.count, bytes[position] != 101 { position += 1 }
                guard position < bytes.count, let n = Int64(String(decoding: bytes[start..<position], as: UTF8.self)) else { throw invalid }
                position += 1; return .number(n)
            }
            if token == 108 || token == 100 {
                var list: [Value] = []; var dict: [String: Value] = [:]
                while position < bytes.count, bytes[position] != 101 {
                    let item = try value(depth + 1)
                    if token == 108 { list.append(item) }
                    else { guard case .bytes(let key) = item, let name = String(data: key, encoding: .utf8) else { throw invalid }; dict[name] = try value(depth + 1) }
                }
                guard position < bytes.count else { throw invalid }; position += 1
                return token == 108 ? .list(list) : .dict(dict)
            }
            guard (48...57).contains(token) else { throw invalid }
            let start = position - 1
            while position < bytes.count, bytes[position] != 58 { position += 1 }
            guard position < bytes.count, let count = Int(String(decoding: bytes[start..<position], as: UTF8.self)), count >= 0, count <= bytes.count - position - 1 else { throw invalid }
            position += 1; let data = Data(bytes[position..<(position + count)]); position += count
            return .bytes(data)
        }
    }
    static var invalid: NSError { NSError(domain: "TorrentManifest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Торрент повреждён или содержит недопустимый путь."]) }
    static func files(_ data: Data) throws -> [File] {
        guard data.count < 16_000_000 else { throw invalid }
        var reader = Reader(bytes: Array(data))
        guard case .dict(let root) = try reader.value(), case .dict(let info)? = root["info"],
              case .bytes(let nameData)? = info["name.utf-8"] ?? info["name"], let name = String(data: nameData, encoding: .utf8) else { throw invalid }
        func safe(_ component: String) -> Bool { !component.isEmpty && component != "." && component != ".." && !component.contains("/") && !component.contains("\\") && !component.contains("\0") }
        guard safe(name) else { throw invalid }
        if case .list(let entries)? = info["files"] {
            return try entries.enumerated().map { index, entry in
                guard case .dict(let file) = entry, case .number(let length)? = file["length"], length >= 0,
                      case .list(let parts)? = file["path.utf-8"] ?? file["path"] else { throw invalid }
                let names = try parts.map { part -> String in
                    guard case .bytes(let data) = part, let text = String(data: data, encoding: .utf8), safe(text) else { throw invalid }; return text
                }
                guard !names.isEmpty else { throw invalid }
                return File(index: index + 1, path: ([name] + names).joined(separator: "/"), bytes: length)
            }
        }
        guard case .number(let length)? = info["length"], length >= 0 else { throw invalid }
        return [File(index: 1, path: name, bytes: length)]
    }
}
