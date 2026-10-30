import Foundation

/// Материал для режиссёра: реальные непересекающиеся фрагменты диалогов.
/// Модель выбирает ID и смысловую роль, а не сочиняет таймкоды/цитаты.
struct EssaySceneCatalogue: Sendable {
    struct Scene: Sendable {
        let id: String
        let start: Double
        let end: Double
        let text: String
        let quote: String
    }

    let scenes: [Scene]

    init(transcript: Transcript) {
        let segments = TranscriptQualityGate(segments: transcript.segments)
            .filtered(transcript.segments)
            .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var result: [Scene] = []
        var run: [TranscriptSegment] = []

        func flush() {
            defer { run.removeAll() }
            guard let first = run.first, let last = run.last,
                  EssayDurationPolicy.sceneLength.contains(last.end - first.start) else { return }
            let text = run.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let quote = text.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
            guard quote.count >= 12 else { return }
            result.append(Scene(
                id: String(format: "S%04d", result.count + 1),
                start: first.start, end: last.end, text: text, quote: quote))
        }

        for segment in segments {
            if let first = run.first, let last = run.last,
               segment.start - last.end > 4 || segment.end - first.start > 40 {
                flush()
            }
            // Один слишком длинный ASR-сегмент не превращается в «цельную
            // сцену» искусственным кропом посередине неизвестной реплики.
            guard segment.end - segment.start <= 40 else { continue }
            if let previous = run.last, segment.start < previous.end { continue }
            run.append(segment)
            let duration = segment.end - (run.first?.start ?? segment.start)
            if duration >= 28, endsThought(segment.text) { flush() }
        }
        flush()
        scenes = result
    }

    private init(scenes: [Scene]) { self.scenes = scenes }

    var digest: String {
        scenes.map {
            "[\($0.id) \(String(format: "%.1f", $0.start))–\(String(format: "%.1f", $0.end))] \($0.text)"
        }.joined(separator: "\n")
    }

    /// Модель вправе выбирать только из действительно переданных ей строк.
    func presented(in digest: String) -> EssaySceneCatalogue {
        EssaySceneCatalogue(scenes: scenes.filter { digest.contains("[\($0.id) ") })
    }

    /// После прореживания номера снова плотные: модель видит только реально
    /// переданные сцены, а локальный ID по-прежнему однозначно задаёт исходник.
    func denselyNumbered() -> EssaySceneCatalogue {
        EssaySceneCatalogue(scenes: scenes.enumerated().map { index, scene in
            Scene(id: String(format: "S%04d", index + 1), start: scene.start, end: scene.end,
                  text: scene.text, quote: scene.quote)
        })
    }

    struct SelectionError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    func moments(from rows: Any?) -> [SelectedMoment]? {
        try? decodeMoments(from: rows)
    }

    /// Вариации имён полей нормализуются, содержимое сцен не восстанавливается
    /// догадками. Любой неизвестный ID или повтор — отдельная диагностируемая ошибка.
    func decodeMoments(from rows: Any?) throws -> [SelectedMoment] {
        guard let rows = rows as? [Any], !rows.isEmpty else {
            throw SelectionError(detail: "В ответе нет списка выбранных сцен (selection).")
        }
        var selected: [SelectedMoment] = []
        var seen = Set<String>()
        for (index, raw) in rows.enumerated() {
            let row: [Any]
            if let tuple = raw as? [Any], tuple.count == 5 {
                row = tuple
            } else if let object = raw as? [String: Any] {
                var fields: [String: Any] = [:]
                for (key, value) in object {
                    let canonical: String
                    switch key.lowercased() {
                    case "id", "sceneid": canonical = "id"
                    case "role", "actrole": canonical = "role"
                    case "weight", "dramaticweight": canonical = "weight"
                    case "featured": canonical = "featured"
                    case "explanation", "supports", "reason": canonical = "explanation"
                    default: continue
                    }
                    guard fields[canonical] == nil else {
                        throw SelectionError(detail: "Сцена \(index + 1): неоднозначные поля \(canonical).")
                    }
                    fields[canonical] = value
                }
                let names = ["id", "role", "weight", "featured", "explanation"]
                for name in names where fields[name] == nil {
                    throw SelectionError(detail: "Сцена \(index + 1): отсутствует поле \(name).")
                }
                row = names.compactMap { fields[$0] }
            } else {
                throw SelectionError(detail: "Сцена \(index + 1): неполная запись выбора.")
            }
            guard let rawID = row[0] as? String, let id = canonicalID(rawID) else {
                throw SelectionError(detail: "Сцена \(index + 1): недопустимый ID, нужен номер из каталога.")
            }
            guard let scene = scenes.first(where: { $0.id == id }) else {
                throw SelectionError(detail: "Сцена \(id) отсутствует в переданном каталоге.")
            }
            guard seen.insert(id).inserted else {
                throw SelectionError(detail: "Сцена \(id) выбрана повторно. Каждой роли нужен отдельный фрагмент.")
            }
            guard let roleKey = row[1] as? String, let role = LongformActType(promptKey: roleKey),
                  LongformActType.canonicalAnalyticOrder.contains(role),
                  let weight = row[2] as? Double, weight.isFinite, (0...1).contains(weight),
                  let featured = row[3] as? Bool,
                  let supports = row[4] as? String, !supports.trimmed.isEmpty else {
                throw SelectionError(detail: "Сцена \(id): неверная роль, вес или отсутствует обоснование.")
            }
            selected.append(SelectedMoment(
                startTime: scene.start, endTime: scene.end, reason: supports,
                dramaticWeight: weight, actRole: role, supports: supports,
                featured: featured, evidenceQuote: scene.quote))
        }
        return selected
    }

    private func canonicalID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.first == "S", !value.dropFirst().isEmpty,
              value.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(value.dropFirst()), number > 0 else { return nil }
        // S004 и S0004 — один номер, никакого поиска «похожей» сцены.
        let digits = String(number)
        return "S" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

private func endsThought(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"»”’"))
    return trimmed.last.map { ".!?…".contains($0) } ?? false
}
