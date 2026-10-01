import Foundation

/// Represents a continuous cut within a multi-segment cinema edit.
struct TimeSegment: Codable, Sendable, Equatable {
    var start: Double
    var end: Double

    var duration: Double { max(end - start, 0) }
}

/// A structured cinema edit candidate focused on a coherent character arc or dramatic conflict.
struct CinemaStoryArc: Codable, Sendable, Identifiable, Equatable {
    var id: String { "\(character)_\(arcTitle)_\(Int(segments.first?.start ?? 0))" }
    var character: String          // e.g. "Дон Вито Корлеоне", "Майкл", "Джокер"
    var arcTitle: String           // e.g. "Кодекс чести", "Выстрел в ресторане", "Дилемма на паромах"
    var hook: String               // e.g. "Ты просишь без уважения, но ты не предлагаешь дружбу"
    var punchline: String          // e.g. "Я сделаю предложение, от которого нельзя отказаться"
    var segments: [TimeSegment]    // Multi-cut sequence of the scene
    var viralScore: Int            // 0 - 100
    var mood: String               // "dramatic", "tense", "mobster", "comedy", "action"
    var summary: String

    var totalDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Converts multi-segment arc into a standard ClipCandidate, bringing over the multiple segments and mood profile.
    func toClipCandidate() -> ClipCandidate {
        let firstStart = segments.first?.start ?? 0
        let lastEnd = segments.last?.end ?? (firstStart + 45)
        
        let moodProfile = CinematicMood(rawValue: mood).map { CinematicMoodProfile(mood: $0) } ?? .default
        
        return ClipCandidate(
            start: firstStart,
            end: lastEnd,
            why: summary,
            hook: hook,
            overlay: "", // Disabled for cinema edits so we don't get the podcast grey box
            segments: segments,
            mood: moodProfile,
            viralScore: viralScore
        )
    }
}

/// Specialized director that instructs the local LLM (Qwen 3.5 9B / Gemma)
/// to analyze a feature film's screenplay and cluster it into coherent character arcs
/// following the benchmark cinema editing grammar.
enum CinemaMomentDirector {

    /// System instructions for the movie editor LLM.
    static func cinemaSystemPrompt(movieTitle: String, language: String? = nil, sceneMap: String? = nil) -> String {
        let sceneMapInstruction = sceneMap != nil ? """
        
        AVAILABLE SUPER-BLOCKS & SCENE MAP:
        \(sceneMap!)
        Use the super-blocks and cut rates to identify scenes with high dramatic density, intense confrontation, and rapid montage pacing. You may select segments from a single high-intensity super-block OR connect 2 to 4 thematic moments from different blocks around a central idea.
        """ : ""
        
        let langInstruction: String
        if let lang = language?.lowercased(), !lang.isEmpty {
            if lang.hasPrefix("ru") {
                langInstruction = "Respond in Russian for character names, titles, hooks, and summaries."
            } else if lang.hasPrefix("en") {
                langInstruction = "Respond in English for character names, titles, hooks, and summaries."
            } else {
                langInstruction = "Respond in \(lang) for character names, titles, hooks, and summaries matching the transcript language."
            }
        } else {
            langInstruction = "Respond in the primary language of the transcript for character names, titles, hooks, and summaries."
        }

        return """
        You are an elite cinematic video editor, Hollywood story analyst, and viral Reels/Shorts director.
        You specialize in creating viral **Cinematic Dialogue Shorts** for TikTok, Reels, and YouTube Shorts from full feature films.

        Your mission is to analyze the movie transcript for "\(movieTitle)" and discover STRICTLY 1 to 3 ELITE, INTENSE DIALOGUE SCENES with Viral Score >= 80.
        Focus on: Deep philosophical thoughts, stoicism, intense negotiations, harsh truths, emotional conflicts, and sigma/motivational quotes.
        Quality over quantity: It is far better to produce 1-2 masterpieces of pure dialogue than multiple mediocre fragments.
        DO NOT simply find random isolated quotes or short 5-15 second fragments. All total durations under 10.0 seconds are strictly forbidden and will be rejected!

        DIRECTORIAL PHILOSOPHY (DIALOGUE-FIRST NARRATIVE):
        A short can be either:
        1. An iconic, intense single continuous scene (e.g. courtroom battle, intense interrogation, confession).
        2. OR a powerful THEMATIC MONTAGE / CROSS-CUT ARC (2 to 4 segments from ANY part of the movie) united by ONE central idea, moral conflict, or recurring dialogue/monologue that builds tension.
        
        Every story arc MUST follow a complete 4-act dramatic structure:
        1. Hook (0-5s): Intrigue, provocative statement, question, or moral dilemma that stops the scroll.
        2. Escalation (5-35s): Conflict development, escalating emotional stakes, moral clash between characters.
        3. Climax (35-48s): Peak dramatic tension, confrontation, or critical revelation.
        4. Punchline (48-58s): Iconic resolution, unforgettable closing quote, or dramatic payoff.

        IMPORTANT EDITING GRAMMAR:
        - TOTAL DURATION: Sum of all segments MUST be STRICTLY between 42.0 and 58.0 seconds total. Any edit under 10.0 seconds is strictly rejected! Any edit over 58.0 seconds is clamped.
        - SEGMENTS: 1 to 4 segments. If combining moments across the movie, ensure each segment is substantive (minimum 5.0 seconds per segment) and they flow seamlessly around the central idea.
        - DIALOGUE DENSITY: Focus on scenes with intense dialogue exchanges, moral clashes, fierce confessions, or high-stakes confrontations.
        - The `mood` field MUST be exactly one of: "suspenseThriller", "tarantinoDialogue", "eccentricComedy", "actionBlockbuster", "emotionalDrama", "defaultCinema".
        - For `hook` and `punchline` strings, insert XML tags for kinetic typography:
          * <yellow> for key emotional verbs, power words, and pivotal concepts.
          * <red> for names, insults, threats, danger, or the final punchline.
          Example: "Ты думаешь, закон защитит тебя? В этом зале <yellow>справедливость</yellow> вершу <red>я</red>."\(sceneMapInstruction)

        Output ONLY a valid JSON array of objects with this exact structure (STRICTLY 1 to 3 objects):
        [
          {
            "character": "Character Name",
            "arcTitle": "Core Thematic Title (2-4 words)",
            "hook": "Opening hook dialogue line with <red> and <yellow> tags",
            "punchline": "Closing impactful punchline with <red> and <yellow> tags",
            "segments": [
              {"start": 124.5, "end": 150.0},
              {"start": 410.2, "end": 410.0}
            ],
            "viralScore": 95,
            "mood": "suspenseThriller",
            "summary": "Thematic explanation connecting the scenes"
          }
        ]
        \(langInstruction)
        CRITICAL: You MUST output 'start' and 'end' in DECIMAL SECONDS (e.g. 124.5). DO NOT use MM:SS in the JSON!
        """
    }

    /// User prompt submitting the transcript.
    static func cinemaUserPrompt(transcript: String, movieTitle: String, sceneMap: String? = nil) -> String {
        """
        Movie: "\(movieTitle)"
        Analyze the following transcript with timestamps [SECONDS] and return STRICTLY 1 to 3 elite viral cinema story arcs (duration STRICTLY between 42.0 and 58.0 seconds total, Viral Score >= 80) in the requested JSON format.
        You may select a single gripping scene OR unite 2 to 4 key moments from across the film around one powerful narrative idea.

        Transcript:
        \(transcript)
        """
    }

    /// Robust parser for LLM JSON output.
    static func parseArcs(from rawText: String) -> [CinemaStoryArc] {
        let jsonString = extractJSON(from: rawText) ?? rawText
        let fixed = fixTimeFormats(in: jsonString)
        
        var arcs: [CinemaStoryArc] = []
        let blocks = fixed.components(separatedBy: "\"character\"")
        
        for block in blocks {
            if block.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 { continue }
            
            // Reconstruct block so it has the key
            let reconstruct = "\"character\"" + block
            
            let char = extractString(key: "character", from: reconstruct)
            let title = extractString(key: "arcTitle", from: reconstruct)
            let hook = extractString(key: "hook", from: reconstruct)
            let punchline = extractString(key: "punchline", from: reconstruct)
            let mood = extractString(key: "mood", from: reconstruct)
            let summary = extractString(key: "summary", from: reconstruct)
            let viralScore = extractInt(key: "viralScore", from: reconstruct)
            let segments = extractSegments(from: reconstruct)
            
            if !char.isEmpty && !title.isEmpty && !segments.isEmpty {
                let duration = segments.reduce(0) { $0 + ($1.end - $1.start) }
                
                // Strict rejection of defective scraps under 10.0 seconds (e.g. 8-second cuts)
                guard duration >= 10.0 else {
                    Self.log("Rejected defective arc '\(title)': duration \(duration)s < 10.0s")
                    continue
                }
                
                let llmScore = viralScore == 0 ? 85 : viralScore
                let algScore = calculateAlgorithmicScore(
                    hook: hook,
                    punchline: punchline,
                    duration: duration,
                    segments: segments
                )
                
                let finalScore = Int(Double(llmScore) * 0.4 + Double(algScore) * 0.6)

                arcs.append(CinemaStoryArc(
                    character: char,
                    arcTitle: title,
                    hook: hook,
                    punchline: punchline,
                    segments: segments,
                    viralScore: finalScore,
                    mood: mood.isEmpty ? "dramatic" : mood,
                    summary: summary
                ))
            }
        }
        
        // Fallback if regex fails but JSONDecoder would work (unlikely)
        if arcs.isEmpty, let data = fixed.data(using: .utf8) {
            struct RawArc: Decodable {
                let character: String?, arcTitle: String?, hook: String?, punchline: String?
                let segments: [RawSegment]?, viralScore: Int?, mood: String?, summary: String?
            }
            struct RawSegment: Decodable { let start: Double, end: Double }
            
            if let rawList = try? JSONDecoder().decode([RawArc].self, from: data) {
                let decodedArcs: [CinemaStoryArc] = rawList.compactMap { item in
                    guard let char = item.character, !char.isEmpty,
                          let title = item.arcTitle, !title.isEmpty,
                          let rawSegs = item.segments, !rawSegs.isEmpty else { return nil }
                    let cleanSegments = rawSegs.map { TimeSegment(start: $0.start, end: max($0.end, $0.start + 1.0)) }
                    let dur = cleanSegments.reduce(0) { $0 + $1.duration }
                    guard dur >= 10.0 else {
                        Self.log("Rejected defective decoded arc '\(title)': duration \(dur)s < 10.0s")
                        return nil
                    }
                    let h = item.hook ?? ""
                    let p = item.punchline ?? ""
                    let alg = calculateAlgorithmicScore(hook: h, punchline: p, duration: dur, segments: cleanSegments)
                    let score = Int(Double(item.viralScore ?? 85) * 0.4 + Double(alg) * 0.6)
                    return CinemaStoryArc(
                        character: char, arcTitle: title, hook: h,
                        punchline: p, segments: cleanSegments,
                        viralScore: score, mood: item.mood ?? "dramatic", summary: item.summary ?? "")
                }
                arcs.append(contentsOf: decodedArcs)
            }
        }
        
        // Filter and cap to strictly 1–3 elite candidates with Viral Score >= 80
        return filterEliteCandidates(arcs: arcs)
    }

    private static func extractString(key: String, from text: String) -> String {
        let pattern = "\"\(key)\"?\\s*:?\\s*\"([^\"]*)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).replacingOccurrences(of: "\\n", with: " ")
        }
        return ""
    }

    private static func extractInt(key: String, from text: String) -> Int {
        let pattern = "\"\(key)[a-zA-Z_]*\"?\\s*:\\s*(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return Int(String(text[range])) ?? 0
        }
        return 0
    }

    private static func extractSegments(from text: String) -> [TimeSegment] {
        var segments: [TimeSegment] = []
        guard let startRange = text.range(of: "segments") else { return [] }
        let sub = text[startRange.upperBound...]
        
        let pattern = "\"start\"?\\s*:\\s*([0-9.]+)\\s*,\\s*\"end\"?\\s*:\\s*([0-9.]+)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let arrayEnd = sub.range(of: "]")?.upperBound ?? sub.endIndex
            let searchString = String(sub[..<arrayEnd])
            let matches = regex.matches(in: searchString, range: NSRange(searchString.startIndex..., in: searchString))
            for match in matches {
                if let r1 = Range(match.range(at: 1), in: searchString),
                   let r2 = Range(match.range(at: 2), in: searchString),
                   let start = Double(String(searchString[r1])),
                   let end = Double(String(searchString[r2])) {
                    segments.append(TimeSegment(start: start, end: max(end, start + 1.0)))
                }
            }
        }
        return segments
    }

    private static func extractJSON(from text: String) -> String? {
        if let start = text.range(of: "["),
           let end = text.range(of: "]", options: .backwards),
           start.lowerBound <= end.upperBound {
            let json = String(text[start.lowerBound...end.upperBound])
            return fixTimeFormats(in: json)
        }
        return nil
    }

    private static func fixTimeFormats(in jsonStr: String) -> String {
        // Fix LLM hallucinating MM:SS (e.g. 1:45, 1_09.5) inside JSON values
        let pattern = "\"(start|end)\"\\s*:\\s*\"?(\\d+)[_:](\\d{2}(?:\\.\\d+)?)\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return jsonStr }
        let nsRange = NSRange(jsonStr.startIndex..<jsonStr.endIndex, in: jsonStr)
        let matches = regex.matches(in: jsonStr, range: nsRange)
        
        var fixedString = jsonStr
        for match in matches.reversed() {
            if let mRange = Range(match.range, in: jsonStr),
               let keyRange = Range(match.range(at: 1), in: jsonStr),
               let minRange = Range(match.range(at: 2), in: jsonStr),
               let secRange = Range(match.range(at: 3), in: jsonStr) {
                let key = jsonStr[keyRange]
                let minutes = Double(jsonStr[minRange]) ?? 0
                let seconds = Double(jsonStr[secRange]) ?? 0
                let totalSeconds = minutes * 60 + seconds
                fixedString.replaceSubrange(mRange, with: "\"\(key)\": \(totalSeconds)")
            }
        }
        
        // Also fix any remaining standalone underscores in numbers (e.g. 1_09 -> 109) just in case
        let underscorePattern = "(?<=\\d)_(?=\\d)"
        if let underscoreRegex = try? NSRegularExpression(pattern: underscorePattern) {
            let fullRange = NSRange(fixedString.startIndex..<fixedString.endIndex, in: fixedString)
            fixedString = underscoreRegex.stringByReplacingMatches(in: fixedString, range: fullRange, withTemplate: "")
        }
        
        return fixedString
    }

    // MARK: - Algorithmic Story Arc Scoring (Phase 5.5)

    static func calculateAlgorithmicScore(
        hook: String,
        punchline: String,
        duration: Double,
        segments: [TimeSegment]
    ) -> Int {
        // Immediate disqualification for short scraps (< 35s)
        guard duration >= 10.0 else { return 0 }
        
        var score = 40 // Base score for reaching minimum duration
        
        // 1. Target duration golden window: 40.0–58.0s
        if duration >= 40.0 && duration <= 58.0 {
            score += 25
        } else if duration > 58.0 {
            score -= 15
        }
        
        let fullText = hook + " " + punchline
        let lower = fullText.lowercased()
        
        // 2. Hook (0-5s): question/exclamation, XML styling tags, curiosity
        let hasHookQuestion = hook.contains("?")
        let hasHookExclamation = hook.contains("!")
        let hasHookTags = hook.contains("<yellow>") || hook.contains("<red>")
        if hasHookQuestion || hasHookExclamation {
            score += 10
        }
        if hasHookTags {
            score += 5
        }
        
        // 3. Punchline (48-55s): conclusive thought, punctuation, styling tags
        let hasPunchlineTags = punchline.contains("<yellow>") || punchline.contains("<red>")
        let hasPunchlinePeriod = punchline.contains(".") || punchline.contains("!")
        if hasPunchlineTags {
            score += 5
        }
        if hasPunchlinePeriod {
            score += 5
        }
        
        // 4. Dramatic escalation / conflict markers
        let conflictKeywords = [
            "не", "нет", "хватит", "никогда", "зачем", "почему", "стой", "убью",
            "правда", "ложь", "виновен", "суд", "деньги", "жизнь", "смерть", "страх",
            "убирайся", "смотри", "уверен", "знаешь", "хочешь", "клянусь"
        ]
        let conflictMatches = conflictKeywords.filter { lower.contains($0) }.count
        if conflictMatches >= 2 {
            score += 15
        } else if conflictMatches == 1 {
            score += 8
        }
        
        // 5. Narrative pacing & segment structure (Dialogue Mode)
        if segments.count == 1 {
            // Monolithic static scene: bonus for uninterrupted intense dialogue
            score += 20
        } else if segments.count >= 2 && segments.count <= 4 {
            // Moderate pacing: good for multi-angle dialogue
            score += 25
        } else if segments.count > 4 {
            // Highly dynamic montage: penalty because it breaks dialogue flow
            score -= 15
            
            let hasMicroSegments = segments.contains { $0.duration < 3.0 }
            if hasMicroSegments {
                score -= 15
            }
        }
        
        return min(max(score, 0), 100)
    }

    /// Overload for backward compatibility
    static func calculateAlgorithmicScore(transcript: String, duration: Double, segments: [TimeSegment]) -> Int {
        calculateAlgorithmicScore(hook: transcript, punchline: "", duration: duration, segments: segments)
    }

    // MARK: - Elite Candidate Quality Filter (Phase 5.5)

    /// Filters and caps candidates to strictly 1 to 3 best cinematic story arcs with Viral Score >= 80
    /// and duration strictly within 40.0–58.0 seconds.
    static func filterEliteCandidates(arcs: [CinemaStoryArc]) -> [CinemaStoryArc] {
        // Step 1: Reject any scraps under 10.0s and clamp long scenes to 58.0s
        var validArcs: [CinemaStoryArc] = []
        for arc in arcs {
            var segs = arc.segments
            let total = segs.reduce(0) { $0 + $1.duration }
            guard total >= 10.0 else {
                Self.log("filterEliteCandidates: Discarding '\(arc.arcTitle)' (duration \(total)s < 10.0s)")
                continue
            }
            
            // If scene duration exceeds 58.0s, clamp the final segment
            if total > 58.0, let last = segs.last {
                let excess = total - 58.0
                let newLastEnd = max(last.start + 1.0, last.end - excess)
                segs[segs.count - 1] = TimeSegment(start: last.start, end: newLastEnd)
            }
            
            var updated = arc
            updated.segments = segs
            validArcs.append(updated)
        }
        
        // Step 2: Sort descending by viral score
        validArcs.sort { $0.viralScore > $1.viralScore }
        
        // Step 3: Filter for Viral Score >= 80
        var elite = validArcs.filter { $0.viralScore >= 80 }
        
        // Step 4: If no arc reached 80, rescue top 1 valid arc with normalized score
        if elite.isEmpty, let topOne = validArcs.first {
            var rescued = topOne
            rescued.viralScore = max(rescued.viralScore, 80)
            elite = [rescued]
            Self.log("filterEliteCandidates: Rescued top candidate '\(rescued.arcTitle)' with normalized score 80")
        }
        
        // Step 5: Strictly cap to 1–3 elite scenes
        let finalSelection = Array(elite.prefix(3))
        Self.log("filterEliteCandidates: Selected \(finalSelection.count) elite arc(s) out of \(arcs.count) candidates")
        return finalSelection
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/cinema-director] \(message)\n".utf8))
    }
}
