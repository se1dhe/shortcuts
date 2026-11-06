import Foundation

/// Материал для режиссёра: реальные непересекающиеся фрагменты диалогов.
/// Модель выбирает ID и смысловую роль, а не сочиняет таймкоды/цитаты.
struct EssaySceneCatalogue: Sendable {
    /// Keep a little of the natural breath around dialogue. The model still
    /// chooses the utterance block; these handles only extend into transcript
    /// gaps and never cut or overlap neighboring speech.
    static let maximumDialogueHandle: Double = 1.25

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
            // A flush must not hide an ASR overlap with the preceding scene.
            if let previous = result.last, segment.start < previous.end { continue }
            if let previous = run.last, segment.start < previous.end { continue }
            run.append(segment)
            let duration = segment.end - (run.first?.start ?? segment.start)
            if duration >= 28, endsThought(segment.text) { flush() }
        }
        flush()

        // Catalogue timestamps used to equal the first/last ASR speech samples,
        // so every selected edit began and ended mid-conversation. Extend each
        // handle only through silence visible between adjacent transcript lines.
        // Respect the scene cap after padding; balance the available handles if
        // both ends would otherwise push a 40-second scene over the limit.
        scenes = result.enumerated().map { index, scene in
            let previousSpeechEnd = segments.last(where: { $0.end <= scene.start })?.end ?? 0
            let safeEnd = SentenceBoundaryDetector.safeTailEnd(after: scene.end,
                desiredEnd: scene.end + Self.maximumDialogueHandle,
                speech: transcript.segments.map { TimeSegment(start: $0.start, end: $0.end) })
            let availableBefore = max(0, scene.start - previousSpeechEnd)
            let availableAfter = transcript.segments.contains(where: { $0.start >= scene.end }) ? max(0, safeEnd - scene.end) : 0
            // Adjacent scenes share the same silence. Give each at most half
            // of that gap so independently padded IDs remain non-overlapping.
            let sharedBefore = index > 0 ? max(0, (scene.start - result[index - 1].end) / 2) : availableBefore
            let sharedAfter = index + 1 < result.count ? max(0, (result[index + 1].start - scene.end) / 2) : availableAfter
            var before = min(Self.maximumDialogueHandle, availableBefore, sharedBefore)
            var after = min(Self.maximumDialogueHandle, availableAfter, sharedAfter)
            let excess = max(0, scene.end - scene.start + before + after - 40)
            if excess > 0 {
                // Either handle can be shorter than half the excess. Remove
                // whatever remains from the other handle, never from dialogue.
                let removeAfter = min(after, excess / 2)
                let removeBefore = min(before, excess - removeAfter)
                before -= removeBefore
                after -= min(after, excess - removeBefore)
            }
            // Reuse the same midpoint expression on both sides to avoid
            // sub-frame overlaps from floating-point rounding.
            let startBoundary = index > 0
                ? result[index - 1].end + (scene.start - result[index - 1].end) / 2 : 0
            let endBoundary = index + 1 < result.count
                ? scene.end + (result[index + 1].start - scene.end) / 2 : scene.end + after
            let start = max(scene.start - before, startBoundary)
            var end = min(scene.end + after, endBoundary, start + EssayDurationPolicy.sceneLength.upperBound)
            // Adding/subtracting timestamps can differ by an ulp. Keep the
            // catalogue inside the same strict bound used by the evidence gate.
            if end - start > EssayDurationPolicy.sceneLength.upperBound { end = end.nextDown }
            return Scene(id: scene.id, start: start, end: end, text: scene.text, quote: scene.quote)
        }
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

    struct Repair: Sendable {
        let original: String
        let indices: [Int]
        let problems: [String]
        let roles: [Int: String]
        let available: EssaySceneCatalogue

        var prompt: String {
            let slots = indices.map { index in
                "index=\(index + 1), role=\(roles[index] ?? "збережи роль оригіналу")"
            }.joined(separator: "\n")
            return "ВИПРАВ ЛИШЕ ЦІ РЯДКИ selection (index від 1):\n\(slots)\nПОМИЛКИ:\n"
                + problems.joined(separator: "\n") + "\nОРИГІНАЛЬНИЙ ПЛАН (решту не змінюй):\n"
                + original + "\nДОСТУПНІ НЕВИКОРИСТАНІ СЦЕНИ (candidate — номер C):\n"
                + available.scenes.enumerated().map { "C\($0.offset + 1) [\($0.element.id)]: \($0.element.text)" }.joined(separator: "\n")
        }
    }

    /// Keep sound rows immutable. An invented suffix is never interpreted as
    /// an alias: only the model can select a different, available source ID.
    func repairNeeded(from raw: String, format: EssayFormat = .analytical) throws -> Repair? {
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let root = JSONVariantParser.deserializeTolerant(json) as? [String: Any],
              let rows = root["selection"] as? [Any], !rows.isEmpty, rows.count <= 50 else { return nil }
        var seen = Set<String>(), indices: [Int] = [], problems: [String] = [], roles: [Int: String] = [:]
        for (index, row) in rows.enumerated() {
            if let object = row as? [String: Any] {
                roles[index] = object.first { ["role", "actrole"].contains($0.key.lowercased()) }?.value as? String
            } else if let tuple = row as? [Any], tuple.count > 1 { roles[index] = tuple[1] as? String }
            do {
                let moment = try decodeMoments(from: [row])[0]
                guard let scene = scenes.first(where: { $0.start == moment.startTime && $0.end == moment.endTime }) else { continue }
                guard seen.insert(scene.id).inserted else {
                    throw SelectionError(detail: "ID \(scene.id) уже используется другой сценой. Нужен другой ID, а не суффикс _alt.")
                }
            } catch {
                indices.append(index); problems.append("Рядок \(index + 1): " + error.localizedDescription)
            }
        }
        // Replacing a bad ID can expose an underfilled act. Request only the
        // missing slots as additions; keep every sound existing row intact.
        var next = rows.count
        for role in format.roles {
            let count = roles.values.filter { LongformActType(promptKey: $0) == role }.count
            let minimum = role == .hook ? 1 : format.minimumScenes(role)
            for _ in 0..<max(0, minimum - count) {
                indices.append(next); roles[next] = role.promptKey
                problems.append("Рядок \(next + 1): додай відсутню сцену акту \(role.promptKey), не змінюючи прийняті рядки.")
                next += 1
            }
        }
        guard next <= format.sceneCount.upperBound else { return nil }
        guard !indices.isEmpty else { return nil }
        return Repair(original: json, indices: indices, problems: problems, roles: roles,
                      available: EssaySceneCatalogue(scenes: scenes.filter { !seen.contains($0.id) }))
    }

    func applyingRepair(_ raw: String, to repair: Repair) throws -> String {
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let response = JSONVariantParser.deserializeTolerant(json) as? [String: Any],
              let replacements = response["replacements"] as? [[String: Any]],
              replacements.count == repair.indices.count,
              var root = JSONVariantParser.deserializeTolerant(repair.original) as? [String: Any],
              var rows = root["selection"] as? [Any] else {
            throw SelectionError(detail: "Исправление должно содержать только replacements для ошибочных строк.")
        }
        let additions = repair.indices.filter { $0 >= rows.count }.count
        rows += [Any](repeating: NSNull(), count: additions)
        var changed = Set<Int>()
        for replacement in replacements {
            guard let value = replacement["index"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue.rounded() == value.doubleValue, value.doubleValue >= 1,
                  value.doubleValue <= Double(rows.count) else {
                throw SelectionError(detail: "Некорректный индекс исправляемой строки.")
            }
            let index = value.intValue - 1
            guard repair.indices.contains(index), changed.insert(index).inserted else {
                throw SelectionError(detail: "Модель попыталась изменить уже принятую сцену или повторила индекс.")
            }
            var row = replacement; row.removeValue(forKey: "index")
            if let candidate = row.removeValue(forKey: "candidate") {
                guard let number = candidate as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= 1, number.doubleValue <= Double(repair.available.scenes.count) else {
                    throw SelectionError(detail: "candidate должен быть номером показанной свободной сцены C.")
                }
                guard row.keys.allSatisfy({ !["id", "sceneid"].contains($0.lowercased()) }) else {
                    throw SelectionError(detail: "Используйте один номер candidate вместо нескольких полей ID.")
                }
                row["id"] = repair.available.scenes[number.intValue - 1].id
            }
            let moment = try repair.available.decodeMoments(from: [row])[0]
            if let role = repair.roles[index], let originalRole = LongformActType(promptKey: role), moment.actRole != originalRole {
                throw SelectionError(detail: "Исправление не должно менять смысловую роль сцены.")
            }
            rows[index] = row
        }
        _ = try decodeMoments(from: rows)
        root["selection"] = rows
        return String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
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
                    case "weight", "dramaticweight", "confidence": canonical = "weight"
                    case "featured", "is_confirmed", "isconfirmed": canonical = "featured"
                    case "explanation", "supports", "reason", "reasoning", "text": canonical = "explanation"
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
                  LongformActType.allCases.contains(role),
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
