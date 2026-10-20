import Foundation

/// Единственный источник путей финальных артефактов: `Exports/<Название Фильма>/`.
///
/// Промежуточные файлы (прокси, render-cache, temp-монтажи) сюда не переезжают намеренно:
/// `ProjectCleanupService` обходит рабочий каталог не-рекурсивно, и вложенность финалов
/// не должна менять цифру «Removable size» в настройках.
enum ExportLayout {
    static let rootDirName = "Exports"
    static let shortsDirName = "shorts"
    static let fallbackFilmName = "Фільм"

    enum Kind: String {
        case longformVideo = "longform"
        case rawRender = "raw"
        case cover = "thumbnail"
        case shortVideo = "short"
        case shortCover = "cover"
    }

    /// Имя папки фильма — читаемый оригинал названия, а не транслит и не нижний регистр:
    /// в Finder `Бегущий по лезвию 2049 (2017)` опознаётся сразу, кириллица и українські
    /// `і ї є` при этом не теряются.
    static func directoryName(for movieTitle: String) -> String {
        let trimmed = movieTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackFilmName }
        let invalid = CharacterSet(charactersIn: ":/\\?*<>\"|")
        let clean = trimmed.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallbackFilmName : clean
    }

    static func filmDirectory(workingDirectory: URL?, movieTitle: String) throws -> URL {
        let root = workingDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShortcastExports", isDirectory: true)
        let directory = root
            .appendingPathComponent(rootDirName, isDirectory: true)
            .appendingPathComponent(directoryName(for: movieTitle), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func shortsDirectory(in filmDirectory: URL) throws -> URL {
        let directory = filmDirectory.appendingPathComponent(shortsDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Имя артефакта: `kind_основа_uuid.ext`. Род — часть имени, а не каталога, чтобы
    /// видео и его обложка лежали рядом и `loudnorm`-временный файл оставался их соседом.
    static func artifact(in directory: URL, kind: Kind, base: String, ext: String,
                         unique: Bool = true) -> URL {
        let stem = [kind.rawValue, fileNameBase(from: base)]
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let suffix = unique ? "_\(UUID().uuidString.prefix(6))" : ""
        var candidate = directory.appendingPathComponent("\(stem)\(suffix).\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)\(suffix)-\(attempt).\(ext)")
            attempt += 1
            if attempt > 20 {
                break
            }
        }
        return candidate
    }

    static func fileNameBase(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let invalid = CharacterSet(charactersIn: ":/\\?*<>\"|.")
        let clean = trimmed.components(separatedBy: invalid).joined(separator: "-")
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return String(clean.prefix(60))
    }
}
