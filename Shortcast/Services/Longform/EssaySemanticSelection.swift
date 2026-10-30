import Foundation

/// Подтверждение отдельного редакторского решения модели, а не частоты слова.
struct EssaySemanticProof: Codable, Equatable, Sendable {
    static let currentVersion = 1
    struct Evidence: Codable, Equatable, Sendable {
        let scene: Int
        let quote: String
        var line: Int? = nil
    }
    let version: Int
    let theme: String
    let reason: String
    let hook: String
    let hookReason: String
    let evidence: [Evidence]
    let modelID: String
}

struct EssayThemeRejected: LocalizedError {
    let reason: String
    let preferredTheme: String?
    var errorDescription: String? { "Тема не прошла смысловую проверку: " + reason }
}

enum EssaySemanticSelection {
    static let maxTokens = 2_048
    static let instructions = """
    Ти — незалежний редактор українського кіноесе. Перевір вибрану тему за РЕАЛЬНИМИ
    сценами нижче, а не за красивим обґрунтуванням попереднього автора.
    Спочатку визнач звичайне СЛОВНИКОВЕ значення СЛОВА без епітетів і слогана.
    Чи саме цей предмет розкривають сцени? Есе досліджує одну грань, а не весь фільм.
    Широка тема прийнятна лише у її ПРЯМОМУ значенні. Назва уточнює грань,
    але не має права переозначити слово й виправдати сторонній предмет розмови.
    Додавання слів про душу, дух чи особистість не рятує невідповідний термін. Не вимагай, щоб одне слово описувало кожен мотив і весь сюжет.
    Не відхиляй тему лише тому, що інше слово здається трохи вужчим чи цікавішим.
    verdict="strained" потрібен, якщо слово обіцяє ІНШИЙ предмет розмови,
    виправдовується лише прихованим переозначенням або не є нормативним
    українським словом. Якщо прямий зміст підтверджений сценами, verdict="direct".
    Слово може НЕ звучати у репліках: важливий зміст, рішення та їхні наслідки.
    Лише при відмові порівняй альтернативи й укажи точнішу у preferredTheme.
    Вона має бути нормативним українським словом з наданих кандидатів і
    відповідати цим самим сценам. Не пропонуй вигаданих слів. Якщо відповідної
    альтернативи немає, preferredTheme=null: буде новий пошук кандидатів.
    Якщо preferredTheme відрізняється від поточної теми, verdict обов'язково "strained".

    Якщо verdict="direct": сам визнач ОДИН найкращий хук. Внутрішньо порівняй можливі
    формулювання за конкретністю, зв'язком із початковою сценою та відповіддю у фіналі.
    Глядачеві не пропонуй варіанти. hook — коротке природне запитання або суперечність,
    яке саме ці сцени розкривають. hookReason пояснює вибір і те, як фінал виконує обіцянку.
    title — окрема ясна назва ролика з 4–12 слів, а не повтор слова теми.
    Без орфографічних помилок і порожньої провокації.
    Перед відповіддю вичитай назву й хук: природна українська, правильні відмінки та
    узгодження, без кальок. Неприродне питання переформулюй сам, без списку варіантів.
    Для прийняття обери 3–4 сцени з РІЗНИХ актів: обов'язково
    з hook і catharsis та ще одного акта. scene — номер SCENE з наданого списку.
    Саме ці сцени мають підтверджувати ПРЯМЕ значення слова.
    Репліки не переписуй і не вигадуй їхніх номерів: програма збереже текст
    показаних реплік вибраних сцен як посилання на вихідний матеріал.
    Поверни лише JSON. Для відмови достатньо verdict, preferredTheme та reason.
    {"verdict":"direct|strained","preferredTheme":null,"reason":"до 240 символів",
     "title":"до 100 символів","hook":"один хук до 160 символів",
     "hookReason":"до 240 символів","evidence":[{"scene":1}]}
    """

    static func prompt(analysis: ThematicAnalysisResult, candidates: [ThematicConcept],
                       transcript: Transcript, materialChars: Int) -> String {
        let header = "ТЕМА: \(analysis.primaryConcept.word)\nТЕЗА: \(analysis.essayPlan?.thesis ?? analysis.primaryConcept.philosophicalPremise)\n"
            + "КАНДИДАТИ:\n" + candidates.map { "\($0.word): \($0.tagline)" }.joined(separator: "\n")
        let cap = max(80, (materialChars - header.count - analysis.selectedMoments.count * 80)
            / max(1, analysis.selectedMoments.count))
        let quality = TranscriptQualityGate(segments: transcript.segments)
        let blocks = analysis.selectedMoments.enumerated().map { index, scene in
            let lines = transcript.segments.enumerated().filter {
                $0.element.end > scene.startTime && $0.element.start < scene.endTime && quality.isUsable($0.element)
            }
                .map { (id: $0.offset, text: "L\($0.offset): \($0.element.text)") }
            var chosen = Set<Int>()
            var remaining = cap
            // Начало и конец сцены сохраняются целыми репликами, а не обрывками.
            for offset in lines.indices {
                for position in [offset, lines.count - offset - 1] where !chosen.contains(position) {
                    if lines[position].text.count <= remaining {
                        chosen.insert(position)
                        remaining -= lines[position].text.count + 1
                    }
                }
            }
            let excerpt = chosen.sorted().map { lines[$0].text }.joined(separator: "\n")
            return "SCENE \(index + 1) role=\(scene.actRole?.promptKey ?? "unknown")\nВСЕРЕДИНІ:\n\(excerpt)"
        }
        return header + "\n" + blocks.joined(separator: "\n\n")
    }

    static func apply(_ raw: String, to analysis: ThematicAnalysisResult, candidates: [ThematicConcept],
                      transcript: Transcript, modelID: String, presentedLineIDs: Set<Int>? = nil) throws -> ThematicAnalysisResult {
        guard let json = JSONVariantParser.extractJSONObject(from: raw), let data = json.data(using: .utf8),
              let decision = try? JSONDecoder().decode(Decision.self, from: data),
              !decision.reason.trimmed.isEmpty else {
            throw ThematicDiscoveryError.noGroundedTheme("редактор не вернул полный ответ по теме и хуку")
        }
        guard decision.verdict == "direct" else {
            guard decision.verdict == "strained" else {
                throw ThematicDiscoveryError.noGroundedTheme("неизвестный вердикт смысловой проверки")
            }
            let preferred = decision.preferredTheme.flatMap { word in
                candidates.first { key($0.word) == key(word) && key(word) != key(analysis.primaryConcept.word) }?.word
            }
            throw EssayThemeRejected(reason: String(decision.reason.prefix(400)), preferredTheme: preferred)
        }
        guard decision.preferredTheme == nil || key(decision.preferredTheme ?? "") == key(analysis.primaryConcept.word),
              validText(decision.hook, limit: 160), validText(decision.hookReason, limit: 400),
              validText(decision.title, limit: 100), decision.title.split(whereSeparator: \.isWhitespace).count >= 3 else {
            throw ThematicDiscoveryError.noGroundedTheme("редактор не определил один согласованный хук и название")
        }
        let evidence: [EssaySemanticProof.Evidence] = try decision.evidence.map { entry in
            guard (1...analysis.selectedMoments.count).contains(entry.scene) else {
                throw ThematicDiscoveryError.noGroundedTheme("редактор выбрал отсутствующую сцену")
            }
            let scene = analysis.selectedMoments[entry.scene - 1]
            guard let index = transcript.segments.indices.first(where: { index in
                let line = transcript.segments[index]
                return line.start < scene.endTime && line.end > scene.startTime
                    && (presentedLineIDs?.contains(index) ?? true)
                    && normalize(line.text).split(separator: " ").count >= 3
                    && normalize(line.text).count >= 12
            }) else {
                throw ThematicDiscoveryError.noGroundedTheme("в выбранной сцене нет показанной исходной реплики")
            }
            return EssaySemanticProof.Evidence(scene: entry.scene, quote: transcript.segments[index].text, line: index)
        }
        let proof = EssaySemanticProof(version: EssaySemanticProof.currentVersion,
            theme: analysis.primaryConcept.word, reason: String(decision.reason.prefix(400)),
            hook: decision.hook.trimmed, hookReason: decision.hookReason.trimmed,
            evidence: evidence, modelID: modelID)
        guard evidenceIsValid(proof, analysis: analysis, transcript: transcript) else {
            throw ThematicDiscoveryError.noGroundedTheme("смысловая проверка не подтверждена цитатами начала, развития и финала")
        }
        var result = analysis
        result.primaryConcept.suggestedTitle = decision.title.trimmed
        result.primaryConcept.aiReasoning = proof.reason
        result.aiReasoning = proof.reason
        var plan = result.essayPlan ?? EssayPlan()
        let hook = EssayPlan.TextVariant(text: proof.hook, source: .llm)
        plan.hookVariants = [hook] // совместимость архива; это уже один выбор модели
        plan.selectedHook = hook
        plan.hookReason = proof.hookReason
        result.essayPlan = plan
        result.semanticProof = proof
        return result
    }

    static let languageInstructions = """
    Ти — коректор української мови. Вичитай ДВІ вже затверджені фрази: title і hook.
    Виправ лише граматику, відмінки, керування дієслів, узгодження та описки.
    Особливо перевір відносні займенники після іменників: їхній відмінок визначає
    дієслово підрядного речення. Збережи зміст, питання, порядок думки та лексику.
    Не переобирай тему, не скорочуй і не переписуй фрази заради стилю.
    Якщо фраза правильна, залиш її без змін. Один результат, без варіантів.
    Поверни лише JSON: {"title":"вичитана назва","hook":"вичитаний хук"}.
    """

    static func applyingLanguagePolish(_ raw: String, to analysis: ThematicAnalysisResult) throws -> ThematicAnalysisResult {
        struct Polish: Decodable { let title: String; let hook: String }
        guard let proof = analysis.semanticProof,
              let json = JSONVariantParser.extractJSONObject(from: raw),
              let reply = try? JSONDecoder().decode(Polish.self, from: Data(json.utf8)),
              validText(reply.title, limit: 100), reply.title.split(whereSeparator: \.isWhitespace).count >= 3,
              validText(reply.hook, limit: 160),
              retainsWording(reply.title, original: analysis.primaryConcept.suggestedTitle),
              retainsWording(reply.hook, original: proof.hook) else {
            throw ThematicDiscoveryError.noGroundedTheme("языковая вычитка изменила содержание или вернула неверный формат")
        }
        var result = analysis
        result.primaryConcept.suggestedTitle = reply.title.trimmed
        let hook = EssayPlan.TextVariant(text: reply.hook.trimmed, source: .llm)
        result.essayPlan?.selectedHook = hook
        result.essayPlan?.hookVariants = [hook]
        result.semanticProof = EssaySemanticProof(version: proof.version, theme: proof.theme,
            reason: proof.reason, hook: hook.text, hookReason: proof.hookReason,
            evidence: proof.evidence, modelID: proof.modelID)
        return result
    }

    private static func retainsWording(_ text: String, original: String) -> Bool {
        let before = Set(normalize(original).split(separator: " "))
        let after = Set(normalize(text).split(separator: " "))
        return !before.isEmpty && Double(before.intersection(after).count) / Double(max(before.count, after.count)) >= 0.6
    }

    static func evidenceIsValid(_ proof: EssaySemanticProof, analysis: ThematicAnalysisResult,
                                transcript: Transcript) -> Bool {
        guard proof.version == EssaySemanticProof.currentVersion, key(proof.theme) == key(analysis.primaryConcept.word),
              analysis.selectedMoments.count >= 3,
              validText(proof.hook, limit: 160), validText(proof.hookReason, limit: 400),
              !proof.reason.trimmed.isEmpty, !proof.modelID.trimmed.isEmpty, (3...5).contains(proof.evidence.count)
        else { return false }
        var seen = Set<Int>()
        var roles = Set<LongformActType>()
        for entry in proof.evidence {
            guard (1...analysis.selectedMoments.count).contains(entry.scene), seen.insert(entry.scene).inserted else { return false }
            let scene = analysis.selectedMoments[entry.scene - 1]
            if let index = entry.line {
                guard transcript.segments.indices.contains(index) else { return false }
                let line = transcript.segments[index]
                guard line.start < scene.endTime && line.end > scene.startTime,
                      normalize(line.text) == normalize(entry.quote) else { return false }
            }
            let text = transcript.segments.filter { $0.end > scene.startTime && $0.start < scene.endTime }
                .map(\.text).joined(separator: " ")
            let quote = normalize(entry.quote)
            guard quote.count >= 12, quote.split(separator: " ").count >= 3,
                  (" " + normalize(text) + " ").contains(" " + quote + " "),
                  let role = scene.actRole else { return false }
            roles.insert(role)
        }
        return roles.count >= 3 && roles.contains(.hook) && roles.contains(.catharsis)
    }

    private static func validText(_ text: String, limit: Int) -> Bool {
        !text.trimmed.isEmpty && text.count <= limit && !text.contains("\n")
            && !text.contains("<") && TextUtilities.dominantScript(text) == "Cyrillic"
    }
    private static func key(_ text: String) -> String { text.trimmed.lowercased() }
    private static func normalize(_ text: String) -> String {
        DirectorArtifactGate.dropApostrophes(text.lowercased())
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func presentedLineIDs(in prompt: String) -> Set<Int> {
        Set(prompt.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("L"), let colon = line.firstIndex(of: ":") else { return nil }
            return Int(line[line.index(after: line.startIndex)..<colon])
        })
    }
    private struct Decision: Decodable {
        let verdict: String
        let preferredTheme: String?
        let reason: String
        let title: String
        let hook: String
        let hookReason: String
        struct Reference: Decodable {
            let scene: Int
            private enum CodingKeys: String, CodingKey { case scene }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let number = try? values.decode(Int.self, forKey: .scene) { scene = number; return }
                let raw = try values.decode(String.self, forKey: .scene).trimmed.uppercased()
                let digits = raw.hasPrefix("SCENE ") ? String(raw.dropFirst(6)).trimmed : raw
                guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let number = Int(digits) else {
                    throw DecodingError.dataCorruptedError(forKey: .scene, in: values, debugDescription: "Unknown scene reference")
                }
                scene = number
            }
        }
        let evidence: [Reference]
        private enum CodingKeys: String, CodingKey {
            case verdict, preferredTheme, reason, title, hook, hookReason, evidence
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            verdict = try values.decode(String.self, forKey: .verdict)
            preferredTheme = try values.decodeIfPresent(String.self, forKey: .preferredTheme)
            reason = try values.decode(String.self, forKey: .reason)
            title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
            hook = try values.decodeIfPresent(String.self, forKey: .hook) ?? ""
            hookReason = try values.decodeIfPresent(String.self, forKey: .hookReason) ?? ""
            evidence = try values.decodeIfPresent([Reference].self, forKey: .evidence) ?? []
        }
    }
}
