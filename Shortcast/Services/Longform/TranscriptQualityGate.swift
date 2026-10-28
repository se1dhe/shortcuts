import Foundation

/// Отсеивает строки, которые Whisper large-v3 выдаёт на тишине, музыке и титрах:
/// подписи субтитровых команд, звуковые описания, бессмысленные повторы и текст
/// на чужом алфавите. Гейт применяется и к входу Director'а, и к добору сцен,
/// и к субтитрам — одна политика вместо трёх разных фильтров.
struct TranscriptQualityGate: Sendable, Equatable {

    enum Script: Sendable, Equatable {
        case cyrillic
        case latin
    }

    /// Алфавит, которого придерживается весь транскрипт. nil — букв нет вовсе
    /// или кириллица и латиница делят транскрипт поровну.
    let expectedScript: Script?

    init(expectedScript: Script?) {
        self.expectedScript = expectedScript
    }

    init(segments: [TranscriptSegment]) {
        self.init(expectedScript: Self.dominantScript(in: segments))
    }

    static func dominantScript(in segments: [TranscriptSegment]) -> Script? {
        var cyrillic = 0
        var latin = 0
        for segment in segments {
            for scalar in segment.text.unicodeScalars where CharacterSet.letters.contains(scalar) {
                if TextUtilities.isCyrillic(scalar) {
                    cyrillic += 1
                } else if isLatin(scalar) {
                    latin += 1
                }
            }
        }
        if cyrillic == latin { return nil }
        return cyrillic > latin ? .cyrillic : .latin
    }

    func isUsable(_ segment: TranscriptSegment) -> Bool {
        isUsable(text: segment.text)
    }

    func isUsable(text: String) -> Bool {
        guard !Self.isJunkLine(text) else { return false }
        return matchesExpectedScript(text)
    }

    func filtered(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { isUsable($0) }
    }

    // MARK: - Строки, не являющиеся репликой

    static func isJunkLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()

        if creditsMarkers.contains(where: { lower.contains($0) }) { return true }
        if lower == "you" { return true }
        if Self.letterCount(trimmed) < 2 { return true }
        if Self.isBracketedOnly(trimmed) { return true }
        if Self.isRepetitiveNonsense(trimmed) { return true }
        if Self.isShoutingDescriptor(trimmed) { return true }
        return false
    }

    /// Подписи субтитровых команд и водяные знаки рипов — как на латинице,
    /// так и на кириллице. Сравнение идёт по нижнему регистру.
    private static let creditsMarkers: [String] = [
        "sous-titre", "sous-titrage", "tekstet av", "undertexter av", "undertekster",
        "subtitles by", "subtitles:", "subtitled by", "translated by", "translation by",
        "synced by", "sync by", "timing by", "ripped by", "encoded by",
        "opensubtitles", "addic7ed", "subscene", "bf-watch",
        "субтитры создавал", "субтитры создала", "субтитры сделал", "субтитры сделала",
        "субтитры подготовил", "субтитры подготовила", "субтитры перевел", "субтитры перевёл",
        "перевод субтитр", "редактор субтитр", "корректор субтитр",
        "субтитри створив", "субтитри створила", "субтитри підготував", "субтитри підготувала",
        "переклад субтитр", "створив субтитри", "підготував субтитри",
        "©", "all rights reserved", "thanks for watching", "thank you for watching",
        "спасибо за просмотр", "дякуємо за перегляд", "продолжение следует", "далі буде",
    ]

    /// ANSI-описания звука и музыки: `*Screams*`, `[door slams]`, `(MUSIC)`.
    /// Диалог внутри скобок остаётся: `Так. (тихо)` — реплика.
    private static func isBracketedOnly(_ text: String) -> Bool {
        var stripped = ""
        var inStar = false
        var inSquare = false
        var inParen = false
        for character in text {
            switch character {
            case "*":
                inStar.toggle()
                continue
            case "[", "【":
                inSquare = true
                continue
            case "]", "】":
                inSquare = false
                continue
            case "(":
                inParen = true
                continue
            case ")":
                inParen = false
                continue
            default:
                break
            }
            if !inStar && !inSquare && !inParen {
                stripped.append(character)
            }
        }
        return letterCount(stripped) < 2
    }

    /// «Gagaga, gagaga, gagagagaga…» — каждый токен состоит из повторённого
    /// слога длиной 1–3 буквы не меньше трёх раз.
    private static func isRepetitiveNonsense(_ text: String) -> Bool {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 5 }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy(isRepetitiveToken)
    }

    private static func isRepetitiveToken(_ token: String) -> Bool {
        let characters = Array(token)
        for unitLength in 1...3 where characters.count % unitLength == 0 {
            let repeats = characters.count / unitLength
            guard repeats >= 3 else { continue }
            let unit = Array(characters[0..<unitLength])
            var matches = true
            for offset in stride(from: unitLength, to: characters.count, by: unitLength) {
                if Array(characters[offset..<(offset + unitLength)]) != unit {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    /// Короткая строка капсом без знака конца предложения — это подпись
    /// дорожки («GONG», «ТРЕВОЖНАЯ МУЗЫКА», «ДОБРА ПІЧА»), а не реплика.
    /// Крик с пунктуацией («ТІКАЙ!») остаётся.
    private static func isShoutingDescriptor(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 3, letters.allSatisfy({ $0.isUppercase }) else { return false }
        guard !text.contains(where: { ".!?…".contains($0) }) else { return false }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        return words.count <= 3
    }

    // MARK: - Алфавит

    private func matchesExpectedScript(_ text: String) -> Bool {
        guard let expectedScript else { return true }
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch expectedScript {
            case .cyrillic where TextUtilities.isCyrillic(scalar):
                return true
            case .latin where Self.isLatin(scalar):
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        (0x0041...0x005A).contains(scalar.value)
            || (0x0061...0x007A).contains(scalar.value)
            || (0x00C0...0x024F).contains(scalar.value)
            || (0x1E00...0x1EFF).contains(scalar.value)
    }

    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (CharacterSet.letters.contains(scalar) ? 1 : 0)
        }
    }
}
