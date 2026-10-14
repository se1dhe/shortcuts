import Foundation

/// Результат поиска диалогового момента в транскрипте фильма
struct TranscriptMomentMatch: Identifiable, Sendable, Equatable {
    let id: UUID
    /// Время начала сцены с учетом пред-отступа (секунды)
    let start: Double
    /// Время окончания сцены с учетом пост-отступа (секунды)
    let end: Double
    /// Текст найденной реплики или диалога
    let matchedDialogue: String
    /// Полный контекст с предшествующей и последующей фразами
    let fullContextText: String
    /// Оценка релевантности (чем выше, тем точнее совпадение)
    let score: Double
    /// Сегменты транскрипта, вошедшие в найденный момент
    let matchedSegments: [TranscriptSegment]

    init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        matchedDialogue: String,
        fullContextText: String,
        score: Double,
        matchedSegments: [TranscriptSegment]
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.matchedDialogue = matchedDialogue
        self.fullContextText = fullContextText
        self.score = score
        self.matchedSegments = matchedSegments
    }

    /// Длительность найденного момента
    var duration: Double {
        max(0.0, end - start)
    }
}

/// Протокол поиска культовых диалоговых моментов в транскрипте фильма
protocol TranscriptMomentSearchingProtocol: Sendable {
    func searchMoments(
        query: String,
        in segments: [TranscriptSegment],
        contextPaddingBefore: Double,
        contextPaddingAfter: Double
    ) -> [TranscriptMomentMatch]
}

extension TranscriptMomentSearchingProtocol {
    func searchMoments(
        query: String,
        in segments: [TranscriptSegment],
        contextPaddingBefore: Double = 1.0,
        contextPaddingAfter: Double = 2.0
    ) -> [TranscriptMomentMatch] {
        searchMoments(
            query: query,
            in: segments,
            contextPaddingBefore: contextPaddingBefore,
            contextPaddingAfter: contextPaddingAfter
        )
    }
}

/// Сервис интеллектуального поиска диалогов и сцен по транскрипту фильма
/// Поддерживает точный и нечеткий поиск, учет морфологии/окончаний,
/// кластеризацию смежных реплик диалога (пауза <= 3.5с) и контекстные отступы.
struct TranscriptMomentSearchService: TranscriptMomentSearchingProtocol {

    private let maxClusterPause: Double = 3.5
    private let maxWindowSegments: Int = 5

    init() {}

    func searchMoments(
        query: String,
        in segments: [TranscriptSegment],
        contextPaddingBefore: Double,
        contextPaddingAfter: Double
    ) -> [TranscriptMomentMatch] {
        guard !segments.isEmpty else { return [] }

        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let queryWords = normalizedQuery.split(separator: " ").map(String.init)
        guard !queryWords.isEmpty else { return [] }

        // 1. Поиск кандидатных окон сегментов транскрипта
        var candidates: [CandidateWindow] = []

        for i in 0..<segments.count {
            // Окно должно начинаться с сегмента, содержащего хотя бы одно слово из запроса
            guard segmentMatchesAnyWord(segments[i], queryWords: queryWords) else {
                continue
            }

            var currentWindow: [TranscriptSegment] = []
            let maxLen = min(maxWindowSegments, segments.count - i)

            for j in 0..<maxLen {
                let seg = segments[i + j]

                if let last = currentWindow.last {
                    let pause = seg.start - last.end
                    if pause > maxClusterPause {
                        break // Слишком большая пауза между репликами — сцена прерывается
                    }
                }

                currentWindow.append(seg)

                // Кандидатное окно должно заканчиваться сегментом, содержащим слово из запроса
                guard segmentMatchesAnyWord(seg, queryWords: queryWords) else {
                    continue
                }

                let score = evaluateMatch(
                    window: currentWindow,
                    normalizedQuery: normalizedQuery,
                    queryWords: queryWords
                )

                if score > 0 {
                    candidates.append(CandidateWindow(
                        startIndex: i,
                        endIndex: i + j,
                        segments: currentWindow,
                        score: score
                    ))
                    if score >= 100.0 {
                        // Точное совпадение найдено в минимальном окне, расширять дальше не требуется
                        break
                    }
                }
            }
        }

        guard !candidates.isEmpty else { return [] }

        // 2. Кластеризация идущих подряд или близких фраз (пауза <= 3.5с)
        // Сортируем кандидатов по релевантности, чтобы сильные совпадения формировали ядра кластеров
        candidates.sort { $0.score > $1.score }

        var clusters: [MomentCluster] = []

        for candidate in candidates {
            let candStart = candidate.segments.first?.start ?? 0
            let candEnd = candidate.segments.last?.end ?? 0

            var merged = false
            for idx in 0..<clusters.count {
                let cl = clusters[idx]

                // Если кандидат пересекается с уже существующим более релевантным кластером
                let overlaps = candidate.startIndex <= cl.endIndex && candidate.endIndex >= cl.startIndex
                if overlaps {
                    // Более релевантный кластер уже сформирован для этого момента речи — поглощаем без расширения
                    merged = true
                    break
                }

                let clStart = cl.segments.first?.start ?? 0
                let clEnd = cl.segments.last?.end ?? 0

                // Если кандидат не пересекается, но находится в пределах диалоговой паузы (пауза <= 3.5с)
                let isAdjacent = (candStart > clEnd && candStart <= clEnd + maxClusterPause) ||
                                 (clStart > candEnd && clStart <= candEnd + maxClusterPause)

                if isAdjacent {
                    // Объединяем разделенные реплики одного диалога
                    let newStartIdx = min(cl.startIndex, candidate.startIndex)
                    let newEndIdx = max(cl.endIndex, candidate.endIndex)
                    let mergedSegs = Array(segments[newStartIdx...newEndIdx])
                    let highestScore = max(cl.score, candidate.score)

                    clusters[idx] = MomentCluster(
                        startIndex: newStartIdx,
                        endIndex: newEndIdx,
                        segments: mergedSegs,
                        score: highestScore
                    )
                    merged = true
                    break
                }
            }

            if !merged {
                clusters.append(MomentCluster(
                    startIndex: candidate.startIndex,
                    endIndex: candidate.endIndex,
                    segments: candidate.segments,
                    score: candidate.score
                ))
            }
        }

        // 3. Формирование итоговых TranscriptMomentMatch с контекстом и отступами
        let padBefore = max(0.0, contextPaddingBefore)
        let padAfter = max(0.0, contextPaddingAfter)

        var matches: [TranscriptMomentMatch] = []

        for cluster in clusters {
            guard let firstSeg = cluster.segments.first, let lastSeg = cluster.segments.last else {
                continue
            }

            let start = max(0.0, firstSeg.start - padBefore)
            let end = max(start + 0.2, lastSeg.end + padAfter)
            let dialogue = cluster.segments.map(\.text).joined(separator: " ")

            // Формируем расширенный контекст (соседние реплики до и после)
            let prevText = cluster.startIndex > 0 ? segments[cluster.startIndex - 1].text : nil
            let nextText = cluster.endIndex + 1 < segments.count ? segments[cluster.endIndex + 1].text : nil

            var contextParts: [String] = []
            if let prev = prevText, !prev.isEmpty {
                contextParts.append("[\(prev)]")
            }
            contextParts.append(dialogue)
            if let next = nextText, !next.isEmpty {
                contextParts.append("[\(next)]")
            }
            let fullContext = contextParts.joined(separator: " ")

            matches.append(TranscriptMomentMatch(
                id: UUID(),
                start: start,
                end: end,
                matchedDialogue: dialogue,
                fullContextText: fullContext,
                score: cluster.score,
                matchedSegments: cluster.segments
            ))
        }

        // 4. Сортировка: сначала самые релевантные (высокий score), при равенстве — по времени фильма
        matches.sort {
            if abs($0.score - $1.score) > 0.01 {
                return $0.score > $1.score
            }
            return $0.start < $1.start
        }

        return matches
    }

    // MARK: - Private Evaluation & Matching

    private func evaluateMatch(
        window: [TranscriptSegment],
        normalizedQuery: String,
        queryWords: [String]
    ) -> Double {
        let rawText = window.map(\.text).joined(separator: " ")
        let normalizedText = normalize(rawText)
        guard !normalizedText.isEmpty else { return 0.0 }

        let windowWords = normalizedText.split(separator: " ").map(String.init)

        // 1. Точное совпадение полной фразы
        if normalizedText.contains(normalizedQuery) {
            let lengthBonus = min(10.0, 10.0 * Double(normalizedQuery.count) / Double(max(normalizedQuery.count, normalizedText.count)))
            return 100.0 + lengthBonus
        }

        // 2. Проверка соответствия слов
        var matchedQueryWordsCount = 0
        var matchedWindowIndices: [Int] = []
        var lastWindowIdx = -1
        var allInOrder = true

        for qWord in queryWords {
            var foundIdx: Int?
            for (wIdx, wWord) in windowWords.enumerated() {
                if wordsMatch(qWord, wWord) {
                    foundIdx = wIdx
                    break
                }
            }

            if let found = foundIdx {
                matchedQueryWordsCount += 1
                matchedWindowIndices.append(found)
                if found < lastWindowIdx {
                    allInOrder = false
                }
                lastWindowIdx = found
            } else {
                allInOrder = false
            }
        }

        let matchRatio = Double(matchedQueryWordsCount) / Double(queryWords.count)

        // Все слова найдены
        if matchedQueryWordsCount == queryWords.count {
            let densityBonus = min(10.0, 10.0 * Double(queryWords.count) / Double(max(queryWords.count, windowWords.count)))
            if allInOrder {
                return 80.0 + densityBonus
            } else {
                return 70.0 + densityBonus
            }
        }

        // Частичное совпадение (более половины слов найдено)
        if matchRatio >= 0.5 {
            let density = Double(matchedQueryWordsCount) / Double(max(matchedQueryWordsCount, windowWords.count))
            return 40.0 * matchRatio + (density * 5.0)
        }

        return 0.0
    }

    /// Сравнение слов с учетом морфологических форм и окончаний (русский/английский)
    private func wordsMatch(_ w1: String, _ w2: String) -> Bool {
        if w1 == w2 { return true }
        if w1.contains(w2) || w2.contains(w1) { return true }

        let minLen = min(w1.count, w2.count)
        if minLen >= 4 {
            let prefixLen = min(minLen, 5)
            let p1 = w1.prefix(prefixLen)
            let p2 = w2.prefix(prefixLen)
            if p1 == p2 { return true }
        }
        return false
    }

    private func segmentMatchesAnyWord(_ segment: TranscriptSegment, queryWords: [String]) -> Bool {
        let norm = normalize(segment.text)
        guard !norm.isEmpty else { return false }
        let words = norm.split(separator: " ").map(String.init)
        return queryWords.contains { qWord in
            words.contains { wordsMatch(qWord, $0) }
        }
    }

    private func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        var result = ""
        for char in lower {
            if char.isLetter || char.isNumber {
                result.append(char)
            } else {
                result.append(" ")
            }
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Internal Helper Types

    private struct CandidateWindow {
        let startIndex: Int
        let endIndex: Int
        let segments: [TranscriptSegment]
        let score: Double
    }

    private struct MomentCluster {
        var startIndex: Int
        var endIndex: Int
        var segments: [TranscriptSegment]
        var score: Double
    }
}
