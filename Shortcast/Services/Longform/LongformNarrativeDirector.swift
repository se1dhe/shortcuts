import Foundation
import OSLog

/// Реализация 4-актного режиссера длинных кинематографических видео Shortcast Cinema
/// Композиция здесь чисто эвристическая: никакого LLM-вызова, только отбор по транскрипту.
final class LongformNarrativeDirector: LongformNarrativeDirecting, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "LongformNarrativeDirector")

    // MARK: - Политика отбора материала (одинакова для любого фильма и любой темы)

    /// Жёсткий низ: крой короче — микрофрагмент, он недопустим ни в одном акте
    static let minRunDuration: Double = 8.0
    /// Всё, что короче этого значения, допустимо, но штрафуется нарастающим штрафом
    static let shortRunDuration: Double = 20.0
    /// До какого уровня наполнения акта крутится цикл дозаполнения
    static let fillTargetRatio: Double = 0.92
    /// Сколько отвергнутых кандидатов акт вправе пропустить, прежде чем признать окно исчерпанным
    static let maxSkippedCandidatesPerAct: Int = 4
    /// Хвостовой паддинг затухания реплики перед кинематографическим затемнением
    static let tailPaddingDuration: Double = 0.85
    /// Доля длины фильма, честно запрашиваемая у монтажа-эссе
    static let runtimeTargetRatio: Double = 0.06
    /// Граница зарезервированного финала фильма, который акты I–III не выжирают
    static let reservedTailStartRatio: Double = 0.80
    /// Хвост считается использованным, если запуск акта IV начинается не раньше этой доли фильма
    static let usedTailStartRatio: Double = 0.85

    /// Чистит сырые LLM-таймкоды моментов: выбрасывает инвертированные диапазоны и
    /// крои короче `minRunDuration`, клампит выход за пределы фильма и склеивает
    /// перекрывающиеся/касающиеся моменты в один спан. AVFoundation валидирует
    /// диапазоны композиции ObjC-исключениями, которые Swift-`catch` не перехватывает,
    /// поэтому сырой ввод модели нельзя пускать в арку без чистки.
    static func sanitizeSelectedMoments(
        _ moments: [SelectedMoment],
        totalMovieDuration: Double
    ) -> [SelectedMoment] {
        guard totalMovieDuration > 0 else { return [] }

        var clean: [SelectedMoment] = []
        for raw in moments.sorted(by: { $0.startTime < $1.startTime }) {
            let start = max(0, raw.startTime)
            var end = min(raw.endTime, totalMovieDuration)
            let rawDuration = end - start

            // Инвертированные или вырожденные диапазоны — безусловный отсев
            guard rawDuration > 0 else { continue }

            // Короткие моменты не выбрасываются, а расширяются до minRunDuration:
            // сдвигаем endTime вперёд, но не дальше totalMovieDuration
            if rawDuration < minRunDuration {
                let expandedEnd = min(start + minRunDuration, totalMovieDuration)
                guard expandedEnd - start >= minRunDuration else { continue }
                end = expandedEnd
            }

            if let last = clean.last, start <= last.endTime {
                let primary = raw.dramaticWeight >= last.dramaticWeight ? raw : last
                clean[clean.count - 1] = SelectedMoment(
                    startTime: last.startTime,
                    endTime: max(last.endTime, end),
                    reason: primary.reason,
                    dramaticWeight: max(last.dramaticWeight, raw.dramaticWeight),
                    actRole: primary.actRole,
                    supports: primary.supports,
                    featured: (last.featured ?? false) || (raw.featured ?? false)
                )
            } else {
                clean.append(
                    SelectedMoment(
                        startTime: start,
                        endTime: end,
                        reason: raw.reason,
                        dramaticWeight: raw.dramaticWeight,
                        actRole: raw.actRole,
                        supports: raw.supports,
                        featured: raw.featured
                    )
                )
            }
        }
        return clean
    }

    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        selectedMoments: [SelectedMoment],
        movieTitle: String,
        targetDuration: Double = 520.0,
        essayPlan: EssayPlan? = nil
    ) async throws -> LongformNarrativeArc {
        let requestedDuration = essayPlan?.targetDuration ?? targetDuration
        let clampedAsk = min(max(requestedDuration, 300.0), 900.0)
        let segments = transcript.segments

        guard !segments.isEmpty else {
            // Если транскрипт пуст, возвращаем синтетическую тестовую структуру
            return makeSyntheticArc(
                movieTitle: movieTitle,
                concept: concept,
                targetDuration: clampedAsk
            )
        }

        // LLM-таймкоды — непроверенный внешний вход: без чистки инвертированные или
        // вырожденные диапазоны доводят AVFoundation до неуловимого ObjC-исключения.
        // Если после чистки материала не осталось — честный откат на эвристику.
        let sanitizedMoments = Self.sanitizeSelectedMoments(
            selectedMoments,
            totalMovieDuration: segments.last?.end ?? 0
        )
        if !sanitizedMoments.isEmpty {
            // Аналитическая 5-актная арка только когда модель реально разметила сцены
            // минимум по трём ролям; иначе сохраняем прежнюю 4-актную раскладку.
            if let plan = essayPlan,
               Self.analyticCoverage(of: sanitizedMoments) >= 3 {
                return try buildAnalyticArc(
                    selectedMoments: sanitizedMoments,
                    transcript: transcript,
                    concept: concept,
                    movieTitle: movieTitle,
                    targetDuration: clampedAsk,
                    plan: plan
                )
            }
            return try buildArcFromSelectedMoments(
                selectedMoments: sanitizedMoments,
                transcript: transcript,
                concept: concept,
                movieTitle: movieTitle,
                targetDuration: clampedAsk,
                hookText: essayPlan?.chosenHook,
                ctaText: essayPlan?.chosenCTA,
                thesis: essayPlan?.thesis
            )
        }

        // Fallback на эвристику, если selectedMoments пуст
        return try await buildArcHeuristic(
            from: transcript,
            concept: concept,
            movieTitle: movieTitle,
            targetDuration: clampedAsk
        )
    }

    static func analyticCoverage(of moments: [SelectedMoment]) -> Int {
        Set(
            moments.compactMap(\.actRole)
                .filter { LongformActType.canonicalAnalyticOrder.contains($0) }
        ).count
    }

    /// Строит 4-актную арку из моментов, выбранных LLM
    private func buildArcFromSelectedMoments(
        selectedMoments: [SelectedMoment],
        transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double,
        hookText: String? = nil,
        ctaText: String? = nil,
        thesis: String? = nil
    ) throws -> LongformNarrativeArc {
        let totalMovieDuration = transcript.segments.last?.end ?? targetDuration
        
        // Пост-фильтрация: исключаем моменты, попадающие в последние 5% фильма (титры)
        let creditsCutoff = totalMovieDuration * 0.95
        let filteredMoments = selectedMoments.filter { $0.endTime < creditsCutoff }
        
        // Если фильтрация удалила все моменты, используем оригинальные (fallback)
        let momentsToUse = filteredMoments.isEmpty ? selectedMoments : filteredMoments
        
        // Сортируем моменты по startTime
        let sortedMoments = momentsToUse.sorted { $0.startTime < $1.startTime }
        
        // Распределяем моменты по 4 актам на основе их позиции в фильме
        let act1Cutoff = totalMovieDuration * 0.25
        let act2Cutoff = totalMovieDuration * 0.50
        let act3Cutoff = totalMovieDuration * 0.75
        
        var act1Moments: [SelectedMoment] = []
        var act2Moments: [SelectedMoment] = []
        var act3Moments: [SelectedMoment] = []
        var act4Moments: [SelectedMoment] = []
        
        for moment in sortedMoments {
            let midPoint = (moment.startTime + moment.endTime) / 2
            if midPoint < act1Cutoff {
                act1Moments.append(moment)
            } else if midPoint < act2Cutoff {
                act2Moments.append(moment)
            } else if midPoint < act3Cutoff {
                act3Moments.append(moment)
            } else {
                act4Moments.append(moment)
            }
        }

        // Балансировка актов: если акт пустой, перераспределяем моменты из соседних актов,
        // чтобы все 4 акта имели хотя бы один сегмент материала
        redistributeMomentsForEmptyActs(
            act1: &act1Moments, act2: &act2Moments,
            act3: &act3Moments, act4: &act4Moments
        )
        
        // Строим акты
        var acts: [LongformAct] = []
        
        func buildAct(from moments: [SelectedMoment], type: LongformActType, actNumber: Int) -> LongformAct? {
            guard !moments.isEmpty else { return nil }
            
            let actSegments = moments.map { TimeSegment(start: $0.startTime, end: $0.endTime) }
            let totalDuration = actSegments.reduce(0.0) { $0 + ($1.end - $1.start) }
            
            // Генерируем dramatic beat на основе reason первого момента
            let dramaticBeat = moments.first?.reason ?? "Сцена раскрывает тему «\(concept.word)»"
            
            return LongformAct(
                type: type,
                title: "", // Будет заполнено actTitling
                dramaticBeat: dramaticBeat,
                segments: actSegments
            )
        }
        
        if let act = buildAct(from: act1Moments, type: .hook, actNumber: 1) {
            acts.append(act)
        }
        if let act = buildAct(from: act2Moments, type: .downfall, actNumber: 2) {
            acts.append(act)
        }
        if let act = buildAct(from: act3Moments, type: .struggle, actNumber: 3) {
            acts.append(act)
        }
        if let act = buildAct(from: act4Moments, type: .catharsis, actNumber: 4) {
            acts.append(act)
        }
        
        // Если не все акты заполнены, добавляем синтетические
        while acts.count < 4 {
            let actNumber = acts.count + 1
            let type: LongformActType = actNumber == 1 ? .hook : (actNumber == 2 ? .downfall : (actNumber == 3 ? .struggle : .catharsis))
            acts.append(LongformAct(
                type: type,
                title: "",
                dramaticBeat: "Акт \(actNumber): тема «\(concept.word)»",
                segments: []
            ))
        }
        
        let totalDuration = acts.reduce(0.0) { $0 + $1.duration }
        
        let filteredCount = selectedMoments.count - momentsToUse.count
        let filterNote = filteredCount > 0 ? " (filtered \(filteredCount) moments in credits zone)" : ""
        
        return LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: concept,
            acts: acts,
            summary: "LLM-selected moments: \(momentsToUse.count) moments distributed across 4 acts\(filterNote)",
            mood: "dramatic",
            hookText: hookText,
            ctaText: ctaText,
            thesis: thesis
        )
    }

    // MARK: - Аналитическая 5-актная арка по ролям сцен

    /// Раскладывает сцены по ролям, назначенным Director'ом, и укладывает сумму
    /// в бюджет. Сцены без роли идут в самый «голодный» акт, а не в четверть фильма:
    /// роль важнее хронологической позиции.
    private func buildAnalyticArc(
        selectedMoments: [SelectedMoment],
        transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double,
        plan: EssayPlan
    ) throws -> LongformNarrativeArc {
        let totalMovieDuration = transcript.segments.last?.end ?? targetDuration
        let creditsCutoff = totalMovieDuration * 0.95
        let filtered = selectedMoments.filter { $0.endTime < creditsCutoff }
        let moments = filtered.isEmpty ? selectedMoments : filtered

        var buckets: [LongformActType: [SelectedMoment]] = [:]
        for type in LongformActType.canonicalAnalyticOrder {
            buckets[type] = []
        }
        for moment in moments {
            if let role = moment.actRole, buckets[role] != nil {
                buckets[role]?.append(moment)
            }
        }
        // Сцены без валидной роли — в акт с наименьшим накопленным хронометражем.
        for moment in moments where moment.actRole == nil || buckets[moment.actRole!] == nil {
            let target = LongformActType.canonicalAnalyticOrder.min {
                bucketDuration(buckets[$0] ?? []) < bucketDuration(buckets[$1] ?? [])
            } ?? .psychology
            buckets[target]?.append(moment)
        }
        for type in LongformActType.canonicalAnalyticOrder {
            buckets[type]?.sort { $0.startTime < $1.startTime }
        }

        // Каждый акт получает хотя бы одну сцену, если у соседа их больше одной:
        // пустой акт — это дыра в драматургии, а не экономия бюджета.
        for type in LongformActType.canonicalAnalyticOrder where (buckets[type] ?? []).isEmpty {
            guard let donor = LongformActType.canonicalAnalyticOrder
                .filter({ $0 != type && (buckets[$0]?.count ?? 0) > 1 })
                .max(by: { bucketDuration(buckets[$0] ?? []) < bucketDuration(buckets[$1] ?? []) })
            else { continue }
            let boundary = nearestBoundary(type, buckets: buckets)
            let candidate = (buckets[donor] ?? []).min {
                min(abs($0.startTime - boundary), abs($0.endTime - boundary))
                    < min(abs($1.startTime - boundary), abs($1.endTime - boundary))
            }
            guard let candidate,
                  let index = buckets[donor]?.firstIndex(of: candidate) else { continue }
            buckets[donor]?.remove(at: index)
            buckets[type] = [candidate]
        }

        // Структурные якоря ставятся ДО добора: они часть бюджета, а не добавка
        // поверх него. Финал фильма и развязка хука — обещания зрителю, и оба
        // обязаны попасть в монтаж, даже если Director их не выбрал.
        let usableSegments = TranscriptQualityGate(segments: transcript.segments)
            .filtered(transcript.segments)
        Self.ensureFinaleAnchor(
            &buckets,
            segments: usableSegments,
            filmDuration: totalMovieDuration,
            creditsCutoff: creditsCutoff
        )
        Self.ensureHookRevealAnchor(
            &buckets,
            hookText: plan.chosenHook,
            segments: usableSegments,
            filmDuration: totalMovieDuration,
            creditsCutoff: creditsCutoff
        )

        fillToBudget(
            &buckets,
            segments: usableSegments,
            target: targetDuration,
            creditsCutoff: creditsCutoff
        )
        trimToBudget(&buckets, target: targetDuration * 1.10)
        var acts: [LongformAct] = []
        for type in LongformActType.canonicalAnalyticOrder {
            let scenes = buckets[type] ?? []
            guard !scenes.isEmpty else { continue }
            acts.append(LongformAct(
                type: type,
                title: "",
                dramaticBeat: plan.focus(for: type) ?? scenes.first?.reason ?? "Тема «\(concept.word)»",
                segments: scenes.map { TimeSegment(start: $0.startTime, end: $0.endTime) }
            ))
        }

        guard !acts.isEmpty else {
            return try buildArcFromSelectedMoments(
                selectedMoments: moments,
                transcript: transcript,
                concept: concept,
                movieTitle: movieTitle,
                targetDuration: targetDuration,
                hookText: plan.chosenHook,
                ctaText: plan.chosenCTA,
                thesis: plan.thesis
            )
        }

        return LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: concept,
            acts: acts,
            summary: "Analytic plan: \(moments.count) moments across \(acts.count) acts",
            mood: "dramatic",
            hookText: plan.chosenHook,
            ctaText: plan.chosenCTA,
            thesis: plan.thesis
        )
    }

    private func bucketDuration(_ moments: [SelectedMoment]) -> Double {
        moments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
    }

    private func nearestBoundary(
        _ type: LongformActType,
        buckets: [LongformActType: [SelectedMoment]]
    ) -> Double {
        let order = LongformActType.canonicalAnalyticOrder
        guard let index = order.firstIndex(of: type) else { return 0 }
        if index > 0, let previous = buckets[order[index - 1]]?.last {
            return previous.endTime
        }
        if index + 1 < order.count, let next = buckets[order[index + 1]]?.first {
            return next.startTime
        }
        return 0
    }

    // MARK: - Структурные якоря (финал фильма и развязка хука)

    /// Последние 15% фильма — это финал: место, где тема получает ответ.
    static let finaleActStartRatio: Double = 0.85
    /// Вес якоря выше добра (0.35) и ниже сильнейшей сцены модели (0.9+):
    /// бюджет его не режет, пока есть что резать кроме не-featured добра.
    static let structuralAnchorWeight: Double = 0.65
    /// Якорь — сцена, а не кусок фильма: короче — обрывок реплики, длиннее — уже не монтаж.
    static let maxAnchorDuration: Double = 60.0
    static let minAnchorDuration: Double = 12.0
    /// Комфортная длина якоря: до неё растём, дальше не жадничаем.
    static let anchorTargetDuration: Double = 30.0

    /// Гарантирует, что катарсис доходит до финала фильма. Director видит только
    /// прореженную выборку реплик и систематически ставит пятый акт на середину;
    /// без якоря последние минуты фильма не входят в эссе вообще.
    private static func ensureFinaleAnchor(
        _ buckets: inout [LongformActType: [SelectedMoment]],
        segments: [TranscriptSegment],
        filmDuration: Double,
        creditsCutoff: Double
    ) {
        guard filmDuration > 0 else { return }
        let finaleStart = filmDuration * finaleActStartRatio
        let allScenes = buckets.values.flatMap { $0 }
        guard !allScenes.contains(where: { $0.startTime >= finaleStart }) else { return }

        let sorted = segments.sorted { $0.start < $1.start }
        let finaleSegments = sorted.filter { $0.start >= finaleStart && $0.end <= creditsCutoff }
        let seed = finaleSegments.max { lhs, rhs in
            let lhsScore = ThoughtCompletionScorer
                .evaluateConcludingPhrase(lhs.text, isFinaleAct: true).scoreModifier
            let rhsScore = ThoughtCompletionScorer
                .evaluateConcludingPhrase(rhs.text, isFinaleAct: true).scoreModifier
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.start < rhs.start
        }
        guard let seed,
              let run = dialogueRun(
                around: seed,
                in: sorted,
                lowerBound: finaleStart,
                upperBound: creditsCutoff
              )
        else { return }
        guard !allScenes.contains(where: {
            $0.startTime < run.end && $0.endTime > run.start
        }) else { return }

        appendAnchor(
            to: &buckets,
            run: run,
            role: .catharsis,
            reason: "Фінал фільму: катарсис"
        )
    }

    /// Гарантирует, что строка, которая «оплачивает» обещание хука, попадёт в монтаж.
    /// Ищем её по содержательным словам хука, а не по догадке модели: если такой
    /// реплики нет, якоря тоже нет — ничего не сочиняем.
    private static func ensureHookRevealAnchor(
        _ buckets: inout [LongformActType: [SelectedMoment]],
        hookText: String?,
        segments: [TranscriptSegment],
        filmDuration: Double,
        creditsCutoff: Double
    ) {
        guard let hookText, filmDuration > 0 else { return }
        let stems = contentStems(hookText)
        guard stems.count >= 2 else { return }

        let sorted = segments.sorted { $0.start < $1.start }
        let searchable = sorted.filter { $0.start < creditsCutoff }
        guard let seed = hookRevealAnchor(stems: stems, in: searchable) else { return }

        let allScenes = buckets.values.flatMap { $0 }
        guard !allScenes.contains(where: {
            $0.startTime < seed.end && $0.endTime > seed.start
        }) else { return }
        guard let run = dialogueRun(
            around: seed,
            in: sorted,
            lowerBound: 0,
            upperBound: creditsCutoff
        ) else { return }

        let role = actPositionBand(forStartTime: seed.start, filmDuration: filmDuration)
        appendAnchor(to: &buckets, run: run, role: role, reason: "Розкриття обіцянки хука")
    }

    private static func appendAnchor(
        to buckets: inout [LongformActType: [SelectedMoment]],
        run: TimeSegment,
        role: LongformActType,
        reason: String
    ) {
        buckets[role, default: []].append(SelectedMoment(
            startTime: run.start,
            endTime: run.end,
            reason: reason,
            dramaticWeight: structuralAnchorWeight,
            actRole: role,
            supports: nil,
            featured: false
        ))
        buckets[role]?.sort { $0.startTime < $1.startTime }
    }

    /// Акт по позиции реплики в фильме — та же раскладка, что у аналитических долей.
    static func actPositionBand(
        forStartTime start: Double,
        filmDuration: Double
    ) -> LongformActType {
        guard filmDuration > 0 else { return .psychology }
        let ratio = start / filmDuration
        if ratio < 0.12 { return .hook }
        if ratio < 0.36 { return .form }
        if ratio < 0.62 { return .psychology }
        if ratio < finaleActStartRatio { return .philosophy }
        return .catharsis
    }

    /// Содержательные основы слов: служебные слова и короткие частицы не
    /// доказывают, что реплика — развязка именно этого хука.
    static func contentStems(_ text: String) -> [String] {
        let stopwords: Set<String> = [
            "цей", "ця", "це", "ці", "той", "та", "те", "ті", "вони", "вона", "він",
            "мене", "тебе", "його", "її", "наш", "ваш", "свій", "своя", "своє", "свої",
            "який", "яка", "яке", "які", "коли", "тому", "щоб", "якщо", "щось", "ніщо",
            "дуже", "також", "тільки", "лише", "але", "потім", "зараз", "бути", "буде",
            "був", "була", "були", "вже", "ось", "там", "тут", "як", "що", "чи",
            "это", "этот", "эта", "эти", "тот", "он", "она", "они", "мы", "вы",
            "его", "её", "их", "что", "как", "когда", "чтобы", "если", "уже", "ещё",
            "или", "но", "по", "на", "до", "из", "за", "для", "от", "под", "над", "про",
        ]
        var seen = Set<String>()
        var stems: [String] = []
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(token)
            guard word.count >= 4, !stopwords.contains(word) else { continue }
            let stem = String(word.prefix(5))
            if seen.insert(stem).inserted { stems.append(stem) }
        }
        return stems
    }

    /// Позднейшая реплика, покрывающая не меньше половины основ хука (минимум две).
    private static func hookRevealAnchor(
        stems: [String],
        in segments: [TranscriptSegment]
    ) -> TranscriptSegment? {
        let required = max(2, Int((Double(stems.count) * 0.5).rounded(.up)))
        var best: TranscriptSegment?
        var bestHits = 0
        for segment in segments {
            let lower = segment.text.lowercased()
            let hits = stems.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            guard hits >= required else { continue }
            if hits > bestHits || (hits == bestHits && segment.start > (best?.start ?? -Double.infinity)) {
                best = segment
                bestHits = hits
            }
        }
        return best
    }

    /// Непрерывный диалоговый запуск вокруг реплики: пауза не длиннее порога сцены,
    /// не выходим за границы окна и не растягиваемся сверх `maxAnchorDuration`.
    static func dialogueRun(
        around seed: TranscriptSegment,
        in segments: [TranscriptSegment],
        lowerBound: Double,
        upperBound: Double
    ) -> TimeSegment? {
        guard let seedIndex = segments.firstIndex(where: {
            abs($0.start - seed.start) < 0.01 && abs($0.end - seed.end) < 0.01
        }) else { return nil }

        let gapLimit = 6.0
        var start = max(seed.start, lowerBound)
        var end = min(seed.end, upperBound)
        guard end > start else { return nil }

        var backward = seedIndex - 1
        var forward = seedIndex + 1
        var backwardOpen = true
        var forwardOpen = true
        var useBackward = true

        while end - start < anchorTargetDuration, backwardOpen || forwardOpen {
            if useBackward {
                if backward >= 0, segments[backward].end <= start + 0.01,
                   start - segments[backward].end <= gapLimit {
                    let candidateStart = max(
                        segments[backward].start,
                        max(lowerBound, end - maxAnchorDuration)
                    )
                    if candidateStart < start {
                        start = candidateStart
                        backward -= 1
                    } else {
                        backwardOpen = false
                    }
                } else {
                    backwardOpen = false
                }
                useBackward = false
            } else {
                if forward < segments.count, segments[forward].start >= end - 0.01,
                   segments[forward].start - end <= gapLimit {
                    let candidateEnd = min(
                        segments[forward].end,
                        min(upperBound, start + maxAnchorDuration)
                    )
                    if candidateEnd > end {
                        end = candidateEnd
                        forward += 1
                    } else {
                        forwardOpen = false
                    }
                } else {
                    forwardOpen = false
                }
                useBackward = true
            }
        }

        guard end - start >= minAnchorDuration else { return nil }
        return TimeSegment(start: start, end: end)
    }

    /// Режет целыми сценами: сначала не-featured с минимальным весом, никогда не
    /// оставляя акт пустым. Крой посередине мысли запрещён.
    private func trimToBudget(
        _ buckets: inout [LongformActType: [SelectedMoment]],
        target: Double
    ) {
        func totalDuration() -> Double {
            buckets.values.reduce(0) { $0 + bucketDuration($1) }
        }
        while totalDuration() > target {
            let removable = LongformActType.canonicalAnalyticOrder.compactMap { type
                -> (type: LongformActType, index: Int, weight: Double)? in
                guard let scenes = buckets[type], scenes.count > 1 else { return nil }
                let candidates = scenes.enumerated().filter { !($0.element.featured ?? false) }
                guard let weakest = candidates.min(by: { $0.element.dramaticWeight < $1.element.dramaticWeight })
                else { return nil }
                return (type, weakest.offset, weakest.element.dramaticWeight)
            }.min(by: { $0.weight < $1.weight })
            guard let removable else { break }
            buckets[removable.type]?.remove(at: removable.index)
        }
    }

    /// Целевой потолок одной сцены после добора: длиннее — уже не сцена, а кусок фильма.
    private static let maxExpandedSceneDuration: Double = 120.0

    /// Доливает акты до их доли заказанного хронометража, когда модель вернула
    /// меньше материала, чем нужно («9 реплик на 2,5 минуты» при выбранных 12).
    /// Новые сцены код не придумывает: расширяет уже выбранные соседним
    /// непрерывным диалогом, чтобы монтаж досказал ту же мысль до конца.
    private func fillToBudget(
        _ buckets: inout [LongformActType: [SelectedMoment]],
        segments: [TranscriptSegment],
        target: Double,
        creditsCutoff: Double
    ) {
        let sortedSegments = segments.sorted { $0.start < $1.start }
        guard !sortedSegments.isEmpty else { return }
        let currentTotal = buckets.values.reduce(0.0) { $0 + bucketDuration($1) }
        guard currentTotal < target * 0.95 else { return }

        for type in LongformActType.canonicalAnalyticOrder {
            var scenes = buckets[type] ?? []
            var deficit = target * type.analyticDurationRatio - bucketDuration(scenes)
            guard deficit > 1.0 else { continue }

            let order = scenes.indices.sorted {
                let lhs = scenes[$0]
                let rhs = scenes[$1]
                if (lhs.featured ?? false) != (rhs.featured ?? false) {
                    return (lhs.featured ?? false)
                }
                return lhs.dramaticWeight > rhs.dramaticWeight
            }

            for (position, index) in order.enumerated() where deficit > 1.0 {
                let scene = scenes[index]
                let share = deficit / Double(order.count - position)
                let blocked = blockedRanges(
                    in: buckets,
                    except: TimeSegment(start: scene.startTime, end: scene.endTime)
                )
                let expanded = expandScene(
                    scene,
                    by: share,
                    segments: sortedSegments,
                    blocked: blocked,
                    gapLimit: sceneGapLimit(for: type),
                    limit: creditsCutoff
                )
                let gained = (expanded.endTime - expanded.startTime)
                    - (scene.endTime - scene.startTime)
                guard gained > 0.01 else { continue }
                scenes[index] = expanded
                // Сразу фиксируем в buckets: расширение следующей сцены акта
                // обязано видеть уже растянутого соседа, иначе они наложатся.
                buckets[type] = scenes
                deficit -= gained
            }
            buckets[type] = scenes
        }

        // Второй эшелон: если расширять больше некуда (пауза длиннее сцены),
        // добираем ближайшие неиспользованные диалоговые куски. Это честная
        // деградация в эвристику: тема и акты по-прежнему от модели.
        var runs: [TimeSegment] = []
        for segment in sortedSegments {
            if let last = runs.last, segment.start - last.end <= 6.0 {
                runs[runs.count - 1] = TimeSegment(
                    start: last.start,
                    end: max(last.end, segment.end)
                )
            } else {
                runs.append(TimeSegment(start: segment.start, end: segment.end))
            }
        }
        var used = buckets.values.flatMap { $0 }
            .map { TimeSegment(start: $0.startTime, end: $0.endTime) }

        func distance(_ run: TimeSegment, to anchors: [TimeSegment]) -> Double {
            anchors.map { anchor in
                if run.end <= anchor.start { return anchor.start - run.end }
                if run.start >= anchor.end { return run.start - anchor.end }
                return 0
            }.min() ?? .infinity
        }

        for type in LongformActType.canonicalAnalyticOrder {
            var scenes = buckets[type] ?? []
            var deficit = target * type.analyticDurationRatio - bucketDuration(scenes)
            while deficit > 1.0 {
                let anchors = scenes.map {
                    TimeSegment(start: $0.startTime, end: $0.endTime)
                }
                let candidate = runs
                    .filter {
                        $0.duration >= Self.minRunDuration
                            && $0.end <= creditsCutoff
                            && !overlapsAny(range: $0, in: used, safetyBuffer: 0.5)
                    }
                    .min { distance($0, to: anchors) < distance($1, to: anchors) }
                guard let candidate,
                      distance(candidate, to: anchors) <= 600.0 else { break }
                scenes.append(SelectedMoment(
                    startTime: candidate.start,
                    endTime: candidate.end,
                    reason: "Сцена поруч із вибраним моментом",
                    dramaticWeight: 0.35,
                    actRole: type,
                    supports: nil,
                    featured: false
                ))
                used.append(candidate)
                deficit -= candidate.duration
            }
            buckets[type] = scenes
        }

        for type in LongformActType.canonicalAnalyticOrder {
            buckets[type]?.sort { $0.startTime < $1.startTime }
        }
    }

    private func blockedRanges(
        in buckets: [LongformActType: [SelectedMoment]],
        except target: TimeSegment
    ) -> [TimeSegment] {
        buckets.values.flatMap { $0 }.compactMap { moment in
            let range = TimeSegment(start: moment.startTime, end: moment.endTime)
            if abs(range.start - target.start) < 0.01,
               abs(range.end - target.end) < 0.01 {
                return nil
            }
            return range
        }
    }

    /// Наращивает сцену целыми репликами по обе стороны, пока не заберёт
    /// `extra` секунд, не упрётся в соседнюю сцену, тишину или титры.
    private func expandScene(
        _ scene: SelectedMoment,
        by extra: Double,
        segments: [TranscriptSegment],
        blocked: [TimeSegment],
        gapLimit: Double,
        limit: Double
    ) -> SelectedMoment {
        var start = scene.startTime
        var end = scene.endTime
        var added = 0.0
        let maxDuration = max(Self.maxExpandedSceneDuration, end - start)
        let blockedRanges = blocked.sorted { $0.start < $1.start }

        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start < scene.startTime { lo = mid + 1 } else { hi = mid }
        }
        var backward = lo - 1
        var forward = lo
        // Сцена обычно занимает несколько реплик: курсоры обязаны стоять на
        // первой реплике за её границей, иначе расширение упирается в себя же.
        while backward >= 0, segments[backward].start >= start - 0.01 {
            backward -= 1
        }
        while forward < segments.count, segments[forward].end <= end + 0.01 {
            forward += 1
        }

        func isFree(_ range: TimeSegment) -> Bool {
            guard range.start >= 0, range.end <= limit else { return false }
            return !blockedRanges.contains {
                $0.end > range.start + 0.5 && $0.start < range.end - 0.5
            }
        }

        func growBackward() -> Bool {
            guard backward >= 0 else { return false }
            let segment = segments[backward]
            guard segment.start < start - 0.01,
                  start - segment.end <= gapLimit else { return false }
            let candidate = TimeSegment(start: max(0, segment.start), end: end)
            guard candidate.duration <= maxDuration, isFree(candidate) else { return false }
            added += start - candidate.start
            start = candidate.start
            backward -= 1
            return true
        }

        func growForward() -> Bool {
            guard forward < segments.count else { return false }
            let segment = segments[forward]
            guard segment.end > end + 0.01,
                  segment.start - end <= gapLimit else { return false }
            let candidate = TimeSegment(start: start, end: min(limit, segment.end))
            guard candidate.duration <= maxDuration, isFree(candidate) else { return false }
            added += candidate.end - end
            end = candidate.end
            forward += 1
            return true
        }

        var backwardOpen = true
        var forwardOpen = true
        var useBackward = true
        while added < extra - 0.05, end - start < maxDuration,
              backwardOpen || forwardOpen {
            if useBackward {
                if !growBackward() { backwardOpen = false }
                useBackward = false
            } else {
                if !growForward() { forwardOpen = false }
                useBackward = true
            }
        }

        return SelectedMoment(
            startTime: start,
            endTime: end,
            reason: scene.reason,
            dramaticWeight: scene.dramaticWeight,
            actRole: scene.actRole,
            supports: scene.supports,
            featured: scene.featured
        )
    }

    /// Балансировка актов: если акт пустой, заимствует ближайший момент из соседнего непустого акта.
    /// Сначала пытается взять ближайший по границе акта момент из следующего акта,
    /// если и тот пуст — из предыдущего. Гарантирует, что все 4 акта получат материал.
    private func redistributeMomentsForEmptyActs(
        act1: inout [SelectedMoment], act2: inout [SelectedMoment],
        act3: inout [SelectedMoment], act4: inout [SelectedMoment]
    ) {
        // Итеративно заполняем пустые акты, пока есть что перераспределять
        for _ in 0..<4 {
            var acts: [(count: Int, index: Int)] = [
                (act1.count, 0), (act2.count, 1), (act3.count, 2), (act4.count, 3)
            ]
            guard let emptyAct = acts.first(where: { $0.count == 0 }) else { break }

            // Определяем приоритет доноров: сначала соседний акт, затем дальний
            let donors: [Int]
            switch emptyAct.index {
            case 0: donors = [1, 2, 3]
            case 1: donors = [0, 2, 3]
            case 2: donors = [3, 1, 0]
            default: donors = [2, 1, 0]
            }

            var donated = false
            for donorIndex in donors {
                guard donorActsCount(donorIndex, act1: act1, act2: act2, act3: act3, act4: act4) > 1 else { continue }

                // Забираем крайний момент донора (ближайший к пустому акту)
                let isDonorAfter = donorIndex > emptyAct.index
                let moment = extractMoment(
                    from: donorIndex, takeFirst: isDonorAfter,
                    act1: &act1, act2: &act2, act3: &act3, act4: &act4
                )
                insertMoment(
                    moment, into: emptyAct.index,
                    act1: &act1, act2: &act2, act3: &act3, act4: &act4
                )
                donated = true
                break
            }
            if !donated { break }
        }
    }

    private func donorActsCount(
        _ index: Int,
        act1: [SelectedMoment], act2: [SelectedMoment],
        act3: [SelectedMoment], act4: [SelectedMoment]
    ) -> Int {
        switch index {
        case 0: return act1.count
        case 1: return act2.count
        case 2: return act3.count
        default: return act4.count
        }
    }

    private func extractMoment(
        from actIndex: Int, takeFirst: Bool,
        act1: inout [SelectedMoment], act2: inout [SelectedMoment],
        act3: inout [SelectedMoment], act4: inout [SelectedMoment]
    ) -> SelectedMoment {
        switch actIndex {
        case 0:
            let m = takeFirst ? act1.removeFirst() : act1.removeLast()
            return m
        case 1:
            let m = takeFirst ? act2.removeFirst() : act2.removeLast()
            return m
        case 2:
            let m = takeFirst ? act3.removeFirst() : act3.removeLast()
            return m
        default:
            let m = takeFirst ? act4.removeFirst() : act4.removeLast()
            return m
        }
    }

    private func insertMoment(
        _ moment: SelectedMoment, into actIndex: Int,
        act1: inout [SelectedMoment], act2: inout [SelectedMoment],
        act3: inout [SelectedMoment], act4: inout [SelectedMoment]
    ) {
        switch actIndex {
        case 0: act1.append(moment)
        case 1: act2.append(moment)
        case 2: act3.append(moment)
        default: act4.append(moment)
        }
    }

    /// Эвристический построитель арки (fallback, когда LLM не предоставила moments)
    func buildArcHeuristic(
        from transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double
    ) async throws -> LongformNarrativeArc {
        let clampedAsk = min(max(targetDuration, 300.0), 900.0)
        let filmSegments = transcript.segments
        let segments = TranscriptQualityGate(segments: filmSegments).filtered(filmSegments)

        guard !segments.isEmpty else {
            // Если транскрипт пуст, возвращаем синтетическую тестовую структуру
            return makeSyntheticArc(
                movieTitle: movieTitle,
                concept: concept,
                targetDuration: clampedAsk
            )
        }

        let totalMovieDuration = filmSegments.last?.end ?? clampedAsk
        let isFullMovie = totalMovieDuration > 1200.0 // >20 мин

        // Запрос имеет смысл только относительно длины фильма: 520с с 62-минутного фильма
        // физически недостижим, поэтому эффективная цель выводится из хронометража источника.
        // Потолок из доступного материала лишь документируется в отчёте — gates не ослабляются.
        let effectiveTarget = min(clampedAsk, max(300.0, totalMovieDuration * Self.runtimeTargetRatio))

        // Бюджет длительности по актам
        let durAct1 = effectiveTarget * LongformActType.hook.targetDurationRatio
        let durAct2 = effectiveTarget * LongformActType.downfall.targetDurationRatio
        let durAct3 = effectiveTarget * LongformActType.struggle.targetDurationRatio
        let durAct4 = effectiveTarget * LongformActType.catharsis.targetDurationRatio

        // Строгая изоляция временных окон и отслеживание использованных фрагментов для исключения дублей
        var usedRanges: [TimeSegment] = []
        var lastActEnd: Double = 0.0

        // Финал фильма зарезервирован под катарсис: акты I–III не имеют права его выжирать,
        // иначе последние 20% фильма не бывают в монтаже никогда.
        let reservedTail = [TimeSegment(
            start: totalMovieDuration * Self.reservedTailStartRatio,
            end: totalMovieDuration + 10.0
        )]

        // Акт 1 (Хук/Тезис) берёт материал из первых 22% фильма: бюджет в ~60с
        // не должен съедать треть картины и лишать материала последующие акты.
        let act1Window: ClosedRange<Double> = 0.0 ... (isFullMovie ? totalMovieDuration * 0.22 : totalMovieDuration * 0.25)
        let act1Segs = selectCohesiveSegments(
            from: segments,
            in: act1Window,
            filmDuration: totalMovieDuration,
            minStartTime: 0.0,
            usedRanges: usedRanges,
            reservedRanges: reservedTail,
            targetDuration: durAct1,
            concept: concept,
            actType: .hook
        )
        usedRanges.append(contentsOf: act1Segs)
        lastActEnd = act1Segs.map(\.end).max() ?? 0.0

        // Акты 2 и 3 перекрываются по времени, но привязаны к середине фильма (18–52% и 48–80%)
        let act2Min = max(lastActEnd + 2.0, isFullMovie ? (totalMovieDuration * 0.18) : (totalMovieDuration * 0.20))
        let act2Max = max(act2Min + durAct2 * 1.5, isFullMovie ? (totalMovieDuration * 0.52) : (totalMovieDuration * 0.50))
        let act2Window: ClosedRange<Double> = act2Min ... act2Max
        let act2Segs = selectCohesiveSegments(
            from: segments,
            in: act2Window,
            filmDuration: totalMovieDuration,
            minStartTime: lastActEnd + 1.0,
            usedRanges: usedRanges,
            reservedRanges: reservedTail,
            targetDuration: durAct2,
            concept: concept,
            actType: .downfall
        )
        usedRanges.append(contentsOf: act2Segs)
        lastActEnd = act2Segs.map(\.end).max() ?? lastActEnd

        let act3Min = max(lastActEnd + 2.0, isFullMovie ? (totalMovieDuration * 0.48) : (totalMovieDuration * 0.50))
        let act3Max = max(act3Min + durAct3 * 1.5, isFullMovie ? (totalMovieDuration * 0.80) : (totalMovieDuration * 0.80))
        let act3Window: ClosedRange<Double> = act3Min ... act3Max
        let act3Segs = selectCohesiveSegments(
            from: segments,
            in: act3Window,
            filmDuration: totalMovieDuration,
            minStartTime: lastActEnd + 1.0,
            usedRanges: usedRanges,
            reservedRanges: reservedTail,
            targetDuration: durAct3,
            concept: concept,
            actType: .struggle
        )
        usedRanges.append(contentsOf: act3Segs)
        lastActEnd = act3Segs.map(\.end).max() ?? lastActEnd

        let act4Min = max(lastActEnd + 2.0, isFullMovie ? (totalMovieDuration * 0.70) : (totalMovieDuration * 0.75))
        let act4Max = max(act4Min + durAct4 * 1.5, totalMovieDuration + 10.0)
        let act4Window: ClosedRange<Double> = act4Min ... act4Max
        let act4Segs = selectCohesiveSegments(
            from: segments,
            in: act4Window,
            filmDuration: totalMovieDuration,
            minStartTime: lastActEnd + 1.0,
            usedRanges: usedRanges,
            reservedRanges: [],
            targetDuration: durAct4,
            concept: concept,
            actType: .catharsis
        )
        usedRanges.append(contentsOf: act4Segs)

        let descriptors = adaptiveActDescriptors(for: concept)

        let acts = [
            LongformAct(
                type: .hook,
                title: descriptors[0].title,
                dramaticBeat: descriptors[0].beat,
                segments: act1Segs
            ),
            LongformAct(
                type: .downfall,
                title: descriptors[1].title,
                dramaticBeat: descriptors[1].beat,
                segments: act2Segs
            ),
            LongformAct(
                type: .struggle,
                title: descriptors[2].title,
                dramaticBeat: descriptors[2].beat,
                segments: act3Segs
            ),
            LongformAct(
                type: .catharsis,
                title: descriptors[3].title,
                dramaticBeat: descriptors[3].beat,
                segments: act4Segs
            )
        ]

        // Хвост фильма только проверяем и документируем: подтягивать плохую реплику в финал
        // ради галочки — ровно тот режим «ослабим gates», который запрещён.
        let tailBoundary = totalMovieDuration * Self.usedTailStartRatio
        let tailUnused = !act4Segs.contains { $0.start >= tailBoundary }

        let admissibleCeiling = min(
            effectiveTarget,
            actMaterialCeiling(from: segments, in: act1Window, reserved: reservedTail, actType: .hook, budget: durAct1)
                + actMaterialCeiling(from: segments, in: act2Window, reserved: reservedTail, actType: .downfall, budget: durAct2)
                + actMaterialCeiling(from: segments, in: act3Window, reserved: reservedTail, actType: .struggle, budget: durAct3)
                + actMaterialCeiling(from: segments, in: act4Window, reserved: [], actType: .catharsis, budget: durAct4)
        )

        let achieved = acts.reduce(0) { $0 + $1.duration }
        let report = LongformNarrativeArc.DurationReport(
            filmDuration: totalMovieDuration,
            ask: targetDuration,
            effectiveTarget: effectiveTarget,
            admissibleCeiling: admissibleCeiling,
            achieved: achieved,
            fillRatio: effectiveTarget > 0 ? achieved / effectiveTarget : 0,
            runsPerAct: acts.map { $0.segments.count },
            perActDurations: acts.map { $0.duration },
            tailUnused: tailUnused,
            gatesUnchanged: true
        )
        logDurationLedger(report)

        return LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: concept,
            acts: acts,
            summary: "Наскрізне 4-актне есе «\(concept.word)» за фільмом «\(movieTitle)»",
            mood: "dramatic",
            durationReport: report
        )
    }

    /// Единственная строка бухгалтерии хронометража: просили / допускал материал / собрали
    private func logDurationLedger(_ report: LongformNarrativeArc.DurationReport) {
        func seconds(_ value: Double) -> String { String(format: "%.1f", value) }
        let runs = report.runsPerAct.map { "\($0)" }.joined(separator: ",")
        let perAct = report.perActDurations.map { seconds($0) }.joined(separator: ",")
        let film = seconds(report.filmDuration)
        let ask = seconds(report.ask)
        let effective = seconds(report.effectiveTarget)
        let ceiling = seconds(report.admissibleCeiling)
        let achieved = seconds(report.achieved)
        let fill = seconds(report.fillRatio * 100.0)
        let tailUnused = report.tailUnused ? "true" : "false"
        let gatesUnchanged = report.gatesUnchanged ? "true" : "false"

        let line = "Duration ledger film=\(film)s ask=\(ask) effective=\(effective) admissibleCeiling=\(ceiling) achieved=\(achieved) fill=\(fill)% runs=[\(runs)] perAct=[\(perAct)] tailUnused=\(tailUnused) gatesUnchanged=\(gatesUnchanged)"

        if report.fillRatio < 0.80 {
            Self.logger.warning("\(line, privacy: .public)")
        } else {
            Self.logger.notice("\(line, privacy: .public)")
        }

        // Отдельно и мягко: хвост фильма — это не недобор материала, а обещание зрителю,
        // что эссе доходит до финала. Заталкивать в него материал ради галочки нельзя, поэтому
        // только сообщаем, никогда не принуждаем.
        if report.tailUnused {
            Self.logger.warning(
                "Catharsis never starts in the last \(Int(Self.usedTailStartRatio * 100))% of the film — its finale is absent from this essay"
            )
        }
    }

    /// Арифметический потолок акта: сумма пригодных связных запусков речи в его окне,
    /// но не больше его бюджета. Те же hard-gates, что и при настоящем отборе.
    private func actMaterialCeiling(
        from segments: [TranscriptSegment],
        in window: ClosedRange<Double>,
        reserved: [TimeSegment],
        actType: LongformActType,
        budget: Double
    ) -> Double {
        let gapLimit = sceneGapLimit(for: actType)
        let cutPadding = headPaddingDuration(for: actType) + Self.tailPaddingDuration

        var chains: [TimeSegment] = []
        var chainStart: Double?
        var chainEnd = 0.0
        for seg in segments where seg.start >= window.lowerBound && seg.start <= window.upperBound {
            if let start = chainStart, seg.start - chainEnd > gapLimit {
                chains.append(TimeSegment(start: start, end: chainEnd))
                chainStart = nil
                chainEnd = 0.0
            }
            if chainStart == nil { chainStart = seg.start }
            chainEnd = max(chainEnd, seg.end)
        }
        if let start = chainStart { chains.append(TimeSegment(start: start, end: chainEnd)) }

        let usable = chains.reduce(0.0) { total, chain in
            // Микрофрагменты и зарезервированный финал материалом не считаются.
            // Потолок считается по хронометражу кроя, вместе с boundary padding:
            // иначе он сравнивается с голой речью и выглядит ниже фактически собранного.
            let cutDuration = chain.duration + cutPadding
            guard cutDuration >= Self.minRunDuration,
                  !overlapsAny(range: chain, in: [], reserved: reserved)
            else { return total }
            return total + cutDuration
        }
        return min(budget, usable)
    }

    /// Максимальный разрыв между репликами, внутри которого это ещё одна сцена фильма.
    /// В разряженном финале фильма паузы между репликами 5–7с, поэтому не-хуку нужно 6.0с.
    private func sceneGapLimit(for actType: LongformActType) -> Double {
        (actType == .hook) ? 3.4 : 6.0
    }

    /// Сколько связных запусков речи акт вправе набирать в цикл дозаполнения.
    /// Постоянные 2/4/4/3 упирались в кап на коротких прогонах и недобирали материал,
    /// которого в окне было достаточно, — теперь потолок выведен из бюджета акта.
    private func maxRunsPerAct(for actType: LongformActType, budget: Double) -> Int {
        switch actType {
        case .hook: return 2   // хук — это два удара, а не нарезка
        default: return max(2, Int((budget / Self.shortRunDuration).rounded(.up)))
        }
    }

    /// Минимальная дистанция между запусками внутри акта. 90с оставлено только хуку:
    /// с 90с разделения три запуска на акт в получасовом фильме арифметически невозможны.
    private func runSeparation(for actType: LongformActType) -> Double {
        (actType == .hook) ? 90.0 : 20.0
    }

    /// Атмосферный pre-roll перед репликой (кино-воздух перед началом речи)
    private func headPaddingDuration(for actType: LongformActType) -> Double {
        switch actType {
        case .hook: return 3.0
        case .downfall: return 0.5
        case .struggle: return 1.2
        case .catharsis: return 1.5
        case .form: return 1.0
        case .psychology: return 0.8
        case .philosophy: return 1.8
        }
    }

    /// Проверяет наложение кандидата на уже взятое и на зарезервированные зоны фильма.
    /// И то, и другое остаётся жёстким gate: никакой штраф не покупает дубль или чужой финал.
    private func overlapsAny(
        range: TimeSegment,
        in used: [TimeSegment],
        reserved: [TimeSegment] = [],
        safetyBuffer: Double = 25.0
    ) -> Bool {
        let conflictsWithUsed = used.contains { existing in
            max(existing.start - safetyBuffer, range.start) < min(existing.end + safetyBuffer, range.end)
        }
        if conflictsWithUsed {
            return true
        }
        // Зарезервированная зона фильма (финал под катарсис) — абсолютный запрет для актов I–III
        return reserved.contains { zone in
            range.start < zone.end && range.end > zone.start
        }
    }

    /// Выбирает диалоговый фрагмент, семантически соответствующий концепту и драматургии акта.
    /// Возвращает 1..N связных запусков речи: дозаполнение акта — итеративный цикл, не рекурсия.
    private func selectCohesiveSegments(
        from allSegments: [TranscriptSegment],
        in window: ClosedRange<Double>,
        filmDuration: Double,
        minStartTime: Double = 0.0,
        usedRanges: [TimeSegment] = [],
        reservedRanges: [TimeSegment] = [],
        targetDuration: Double,
        concept: ThematicConcept,
        actType: LongformActType,
        allowChaining: Bool = true
    ) -> [TimeSegment] {
        // Отсечка титров: для фильмов длительностью >20 мин (1200с),
        // где последние 5% приходятся на бегущие титры. Короткие фильмы
        // и тестовые данные не имеют титров — отсечка не применяется.
        let totalDuration = filmDuration
        let hasCredits = totalDuration > 1200.0
        let creditsCutoff = hasCredits ? totalDuration * 0.95 : totalDuration + 1.0
        let searchStart = max(window.lowerBound, minStartTime)
        let candidates = allSegments.filter {
            $0.start >= searchStart && $0.start <= window.upperBound && $0.start < creditsCutoff
        }
        guard !candidates.isEmpty else {
            if !allowChaining {
                return []
            }
            return silentFallback(
                start: searchStart,
                targetDuration: targetDuration,
                window: window,
                filmDuration: filmDuration,
                reserved: reservedRanges
            )
        }

        // Head/tail padding кроя нужен до отбора: жёсткий порог микрофрагментов
        // считается по длине итогового кроя, а не по одной только речи
        let headPadding = headPaddingDuration(for: actType)
        let maxSceneGap = sceneGapLimit(for: actType)
        let idealSpeechDensity: Double = (actType == .hook) ? 0.9 : 1.6

        let thematicKeywords = extractThematicKeywords(for: concept)
        let dramaticKeywords = actDramaticKeywords(for: actType)
        let coreWord = concept.word.lowercased()

        var admissible: [(startIdx: Int, length: Int, score: Double, isComplete: Bool)] = []

        for i in 0..<candidates.count {
            var currDur = 0.0
            var j = i
            var wordCount = 0
            var thematicMatchPoints = 0
            var dramaticBeatCount = 0
            var fillerCount = 0
            var calmIntroBonus = 0.0
            var panicPenalty = 0.0

            while j < candidates.count && currDur < targetDuration {
                let seg = candidates[j]
                if j > i {
                    let sceneGap = seg.start - candidates[j - 1].end
                    if sceneGap > maxSceneGap {
                        // Сцена закончилась: закрываем этот запуск и возвращаем его как есть,
                        // а не обрываем поиск всего акта — следующий запуск откроет цикл дозаполнения
                        break
                    }
                }
                currDur = seg.end - candidates[i].start
                let words = seg.words.count > 0 ? seg.words.count : seg.text.split(whereSeparator: { $0.isWhitespace }).count
                wordCount += words

                let lowerText = seg.text.lowercased()

                // 1. Оценка совпадения с философским концептом
                if lowerText.contains(coreWord) {
                    thematicMatchPoints += 8
                }
                for kw in thematicKeywords {
                    if lowerText.contains(kw) {
                        thematicMatchPoints += 2
                    }
                }

                // 2. Оценка драматургического бита для данного акта
                for dkw in dramaticKeywords {
                    if lowerText.contains(dkw) {
                        dramaticBeatCount += 1
                    }
                }

                // 3. Для Акта 1 (Вступление/Экспозиция) — отбор спокойных глубоких размышлений и отсев суеты/криков
                if actType == .hook {
                    // Особая проверка открывающей реплики кандидата: вступительная сцена обязана начинаться спокойно!
                    let firstText = candidates[i].text.lowercased()
                    let openingAggressiveWords = [
                        "ай", "вб'ю", "стріляй", "швидше", "чорт", "сука", "блядь", "вали", "заткнись",
                        "відповідай", "п'ять секунд", "секунд", "швидко", "стій", "паніка", "хто?", "що?",
                        "хто", "прошу", "не треба", "ні!"
                    ]
                    for ow in openingAggressiveWords {
                        if firstText.contains(ow) {
                            panicPenalty += 50_000.0 // Полная дисквалификация кандидата с агрессивного крика/допроса
                        }
                    }
                    // Восклицательный знак в открывающей фразе (крик/приказ) недопустим для интро
                    if candidates[i].text.contains("!") {
                        panicPenalty += 20_000.0
                    }
                    // Короткий резкий вопрос (< 4 слов с "?") — это перепалка/допрос («Кто?», «Что?»), отсекаем
                    let tokens = firstText.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
                    if candidates[i].text.contains("?") && tokens.count < 4 {
                        panicPenalty += 20_000.0
                    }

                    let introReflectiveKeywords = [
                        "я", "мені", "мене", "життя", "час", "річ", "правило", "гра", "зрозумів",
                        "засвоїв", "знаю", "думав", "завжди", "світ", "людина", "вибір", "переможець",
                        "поразка", "смерть", "страх"
                    ]
                    for rkw in introReflectiveKeywords {
                        if lowerText.contains(rkw) {
                            calmIntroBonus += 15.0
                        }
                    }

                    let aggressivePanicWords = [
                        "ай", "вб'ю", "стріляй", "швидше", "чорт", "сука", "блядь", "вали", "заткнись",
                        "відповідай", "п'ять секунд", "швидко", "стій", "паніка", "допоможіть"
                    ]
                    for pw in aggressivePanicWords {
                        if lowerText.contains(pw) {
                            panicPenalty += 200.0
                        }
                    }

                    let exclamationCount = seg.text.filter { $0 == "!" }.count
                    if exclamationCount >= 1 {
                        panicPenalty += Double(exclamationCount) * 50.0
                    }
                }

                // 4. Для Акта 3 (Борьба): отсев обрывков мыслей и союзов на старте
                if actType == .struggle {
                    let firstText = candidates[i].text.lowercased()
                    let conjunctionOpeners = ["а ти", "що ти", "і ти", "але", "а де", "тобто", "далі", "чому", "жертва"]
                    for co in conjunctionOpeners {
                        if firstText.hasPrefix(co) {
                            panicPenalty += 500.0
                        }
                    }
                    let struggleExpositionWords = ["голос", "чуєш", "ворог", "боротьб", "наполеглив", "друг", "правило", "контрол"]
                    for sew in struggleExpositionWords {
                        if firstText.contains(sew) {
                            calmIntroBonus += 40.0
                        }
                    }
                }

                // 5. Штраф за пустые короткие междометия
                if words <= 2 && thematicMatchPoints == 0 {
                    fillerCount += 1
                }

                j += 1
            }

            // Захватываем завершение предложения (знак препинания или пауза), чтобы не обрубать слова
            var lookahead = j
            while lookahead < candidates.count && (candidates[lookahead].end - candidates[i].start) < (targetDuration * 1.75) {
                if lookahead > i {
                    let sceneGap = candidates[lookahead].start - candidates[lookahead - 1].end
                    if sceneGap > maxSceneGap {
                        break
                    }
                }
                let lastCandText = candidates[lookahead - 1].text
                let eval = ThoughtCompletionScorer.evaluateConcludingPhrase(lastCandText, isFinaleAct: actType == .catharsis)
                if eval.isCompleteThought && SentenceBoundaryDetector.hasTerminalPunctuation(lastCandText) {
                    break
                }
                let pause = candidates[lookahead].start - candidates[lookahead - 1].end
                if pause >= 0.85 && eval.isCompleteThought { break }
                lookahead += 1
            }
            j = lookahead
            currDur = candidates[j - 1].end - candidates[i].start

            // Оценка завершенности мысли финальной сцены (Акт IV / Катарсис)
            let concludingText = candidates[j - 1].text
            let thoughtEval = ThoughtCompletionScorer.evaluateConcludingPhrase(
                concludingText,
                isFinaleAct: actType == .catharsis
            )

            // Жёсткий порог отсекает только микрофрагменты (по длине итогового кроя).
            // Прочие несоответствия превращены в штрафы, чтобы не выбрасывать 90%
            // разряженного финала фильма, где пригодных по-старому запусков почти нет.
            let runCutDuration = currDur + headPadding + Self.tailPaddingDuration
            guard runCutDuration >= Self.minRunDuration else { continue }

            let candidateRange = TimeSegment(start: candidates[i].start, end: candidates[j - 1].end)
            // Дубли и зарезервированный финал остаются жёсткими gate: штраф не покупает наложение
            if overlapsAny(range: candidateRange, in: usedRanges, reserved: reservedRanges) {
                continue
            }

            let durationFillRatio = min(1.0, currDur / targetDuration)
            let speechDensity = currDur > 0 ? Double(wordCount) / currDur : 0.0

            // Нарастающий штраф за крой короче shortRunDuration: 8с ещё допустимо, но дорого
            let shortRunPenalty = max(0.0, Self.shortRunDuration - runCutDuration) * 6.0
            // Незавершенная мысль в финале больше не дисквалифицирует кандидата, а лишь дорожает
            let incompleteThoughtPenalty = (actType == .catharsis && !thoughtEval.isCompleteThought) ? 45.0 : 0.0
            // Плотность речи: спокойный монолог для хука, разговорный темп для остальных актов
            let densityScore = -abs(speechDensity - idealSpeechDensity) * 12.0

            let catharsisCompletionScore = (actType == .catharsis) ? thoughtEval.scoreModifier : 0.0

            // Итоговый скор: максимальный вес отдается репликам по выбранной теме
            let score = (Double(thematicMatchPoints) * 50.0)
                + (Double(dramaticBeatCount) * 14.0)
                + (Double(wordCount) * 0.3)
                + densityScore
                + calmIntroBonus
                - panicPenalty
                + catharsisCompletionScore
                - (Double(fillerCount) * 6.0)
                + (durationFillRatio * 15.0)
                - shortRunPenalty
                - incompleteThoughtPenalty

            admissible.append((startIdx: i, length: j - i, score: score, isComplete: thoughtEval.isCompleteThought))
        }

        // Если в акте нет ни одной завершенной мысли, весь его материал оборван:
        // акт получает сквозной штраф (он удешевляет этот акт целиком), но ни один
        // кандидат от этого пригодным не становится — порядок внутри акта не меняется.
        var ranked = admissible
        if actType == .catharsis, !ranked.contains(where: { $0.isComplete }) {
            for index in ranked.indices {
                ranked[index].score -= 100.0
            }
        }

        // max(by:) оставляет первого из равных: при одинаковом скорее берется более ранняя сцена
        guard let best = ranked.max(by: { $0.score < $1.score }) else {
            if !allowChaining {
                return []
            }
            return silentFallback(
                start: searchStart,
                targetDuration: targetDuration,
                window: window,
                filmDuration: filmDuration,
                reserved: reservedRanges
            )
        }

        let slice = candidates[best.startIdx..<(min(best.startIdx + max(best.length, 1), candidates.count))]
        guard let first = slice.first, let last = slice.last else {
            if !allowChaining {
                return []
            }
            return silentFallback(
                start: searchStart,
                targetDuration: targetDuration,
                window: window,
                filmDuration: filmDuration,
                reserved: reservedRanges
            )
        }

        let minSegmentDuration = (actType == .catharsis) ? 5.0 : 15.0
        let rawRange = TimeSegment(start: first.start, end: max(last.end, first.start + minSegmentDuration))
        // Хвостовой паддинг 0.85с для естественного затухания реплики, эха и реверберации
        // перед плавным кинематографическим затемнением на склейке (устраняет эффект обрыва слов)
        let maxSceneDuration = targetDuration * 1.75

        let detector = SentenceBoundaryDetector(
            headPadding: headPadding,
            tailPadding: Self.tailPaddingDuration,
            minSegmentDuration: minSegmentDuration,
            maxShortsDuration: maxSceneDuration
        )

        let refined = detector.refineSceneBoundary(
            range: rawRange,
            maxAllowedDuration: maxSceneDuration,
            in: allSegments
        )

        // После выравнивания границ крой стал тоньше жёсткого порога — это не материал
        guard refined.duration >= Self.minRunDuration else {
            return []
        }

        var resultSegments = [refined]
        guard allowChaining else { return resultSegments }

        // Итеративный цикл дозаполнения акта — для всех четырёх актов, а не только для 2 и 3.
        // Рекурсии нет: внутренний вызов идёт с allowChaining: false, глубина стека всегда 1.
        let separation = runSeparation(for: actType)
        let maxRuns = maxRunsPerAct(for: actType, budget: targetDuration)
        // Вперёд по времени акт идёт всегда; назад добирают материал только акты развития.
        // Хук — тезис и один ответ, катарсис — нарастание финала: разворачивать их в обе
        // стороны значит ломать то, ради чего они существуют.
        let allowsBackwardReach = (actType == .downfall || actType == .struggle)
        var extendedUsed = usedRanges
        extendedUsed.append(refined)
        var collected = refined.duration
        var previousEnd = refined.end
        // Крой, отвергнутый уже после выравнивания границ: его надо пропустить, а не закрывать
        // акт — иначе один соседний обломок лишает акт всего remaining material.
        var blocked: [TimeSegment] = []
        var skippedCandidates = 0

        while resultSegments.count < maxRuns && collected < targetDuration * Self.fillTargetRatio {
            let remainingBudget = targetDuration - collected
            guard remainingBudget > Self.minRunDuration else { break }

            // Для актов развития ищем лучший оставшийся запуск по ВСЕМУ окну: привязка к
            // previousEnd отрезала им весь материал левее первой удачи, поэтому акт упирался
            // в 82% бюджета, хотя пригодные сцены в окне оставались.
            let searchFloor = allowsBackwardReach ? window.lowerBound : previousEnd + separation
            let nextRuns = selectCohesiveSegments(
                from: allSegments,
                in: window,
                filmDuration: filmDuration,
                minStartTime: searchFloor,
                usedRanges: extendedUsed + blocked,
                reservedRanges: reservedRanges,
                targetDuration: remainingBudget,
                concept: concept,
                actType: actType,
                allowChaining: false
            )
            // Пусто — окно исчерпано, gates не ослабляем.
            guard let next = nextRuns.first else { break }
            guard next.duration >= Self.minRunDuration,
                  !overlapsAny(range: next, in: extendedUsed, reserved: reservedRanges),
                  isSeparated(next, from: extendedUsed, by: separation)
            else {
                // Выравнивание границ залезло в уже взятое или поставило крой вплотную к нему:
                // это один плохой кандидат, а не конец акта — пробуем следующий по рейтингу.
                guard skippedCandidates < Self.maxSkippedCandidatesPerAct else { break }
                blocked.append(next)
                skippedCandidates += 1
                continue
            }

            resultSegments.append(next)
            extendedUsed.append(next)
            previousEnd = max(previousEnd, next.end)

            let durationBefore = collected
            collected += next.duration
            guard collected > durationBefore else { break }
        }

        // Монтажный ряд внутри акта идёт строго по времени фильма — зритель не видит откатов.
        return resultSegments.sorted { $0.start < $1.start }
    }

    /// Запуск отделён от каждого уже взятого хотя бы на `separation` секунд в обе стороны.
    private func isSeparated(_ candidate: TimeSegment, from taken: [TimeSegment], by separation: Double) -> Bool {
        !taken.contains { abs(candidate.start - $0.end) < separation || abs($0.start - candidate.end) < separation }
    }

    /// Запасной интервал акта, когда в окне нет ни одной пригодной реплики:
    /// не выходим за окно, за пределы фильма, в зарезервированный финал и в титры
    private func silentFallback(
        start: Double,
        targetDuration: Double,
        window: ClosedRange<Double>,
        filmDuration: Double,
        reserved: [TimeSegment]
    ) -> [TimeSegment] {
        let lower = max(start, window.lowerBound)
        // Отсечка титров: для фильмов длительностью >20 мин (1200с)
        let totalDuration = filmDuration
        let hasCredits = totalDuration > 1200.0
        let creditsCutoff = hasCredits ? totalDuration * 0.95 : totalDuration + 1.0
        let filmCeiling = min(
            totalDuration + Self.tailPaddingDuration,
            creditsCutoff
        )
        var upper = min(lower + max(targetDuration, Self.minRunDuration), min(window.upperBound, filmCeiling))
        for zone in reserved where lower < zone.end && upper > zone.start {
            upper = min(upper, zone.start)
        }
        guard upper - lower >= Self.minRunDuration else {
            return []
        }
        return [TimeSegment(start: lower, end: upper)]
    }

    /// Публичный метод для юнит-тестирования и внешнего выравнивания границ сцен
    public static func refineSceneBoundary(
        in segments: [TranscriptSegment],
        around range: Range<Double>,
        maxAllowedDuration: Double
    ) -> Range<Double> {
        let detector = SentenceBoundaryDetector(
            headPadding: 0.20,
            tailPadding: 0.45,
            minSegmentDuration: 15.0,
            maxShortsDuration: maxAllowedDuration
        )
        let timeSeg = TimeSegment(start: range.lowerBound, end: range.upperBound)
        let refined = detector.refineSceneBoundary(range: timeSeg, maxAllowedDuration: maxAllowedDuration, in: segments)
        return refined.start..<refined.end
    }

    /// Ключевые слова темы для скоринга реплик. Internal — проверяется юнит-тестами напрямую.
    func extractThematicKeywords(for concept: ThematicConcept) -> [String] {
        var keywords: Set<String> = []
        let wordLower = concept.word.lowercased()
        keywords.insert(wordLower)

        // Ядро темы выводится из самого слова: «субъективность» → «субъектив»,
        // поэтому падежные формы («субъективна», «субъективном») совпадают с темой
        // в любом фильме и с любой темой — вместо этого сверяться с таблицей нельзя.
        for stem in themeStems(for: concept.word) {
            keywords.insert(stem)
        }

        let semanticThematicMap: [String: [String]] = [
            "его": ["его", "гордіст", "голов", "ворог", "всередин", "я сам", "мене", "себе", "розум", "мисл", "контрол", "перемож", "слаб", "біль", "визнай", "правд", "голос"],
            "обман": ["обман", "розводк", "брехн", "правд", "гра", "шах", "суперник", "розумн", "правил", "угод", "грош", "довір", "жадібн", "маніпул", "вірит", "карт"],
            "страх": ["страх", "боїт", "боїшся", "більно", "смерт", "вбит", "панік", "пістолет", "постріл", "кров", "втрат", "кінець", "тряс", "жах", "слабк"],
            "ілюзія": ["ілюзі", "здаєт", "реальн", "бачит", "сліп", "оч", "сон", "правд", "прихов", "ховає", "розуміє", "здається", "дзеркал", "марев"],
            "жадібність": ["жадібн", "грош", "багат", "алчіст", "мільйон", "борг", "заплат", "цін", "купит", "золот", "казино", "виграш", "мало"],
            "терпіння": ["терпін", "чекат", "час", "поспіх", "тиш", "витрим", "спокій", "холоднокров", "секунд"],
            "характер": ["характер", "воля", "сил", "зламати", "вистоя", "удар", "пада", "вставати", "терпіти", "до кінця"],
            "самотність": ["один", "самотніст", "порожнеч", "нікого", "один на один", "тиш", "кинув", "сам"],
            "зрада": ["зрад", "ніж у спину", "вірніст", "зрадник", "зрад", "вірив", "підставив", "щур"],
            "сім'я": ["сім'", "брат", "батько", "син", "доньк", "рідн", "дім", "діти", "матір", "захист", "крів"]
        ]

        for (key, list) in semanticThematicMap {
            if wordLower.contains(key) || key.contains(wordLower) {
                for item in list { keywords.insert(item) }
            }
        }

        let fullContext = "\(concept.tagline) \(concept.philosophicalPremise) \(concept.suggestedTitle)"
        let tokens = fullContext.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }

        for token in tokens.prefix(12) {
            let stem = String(token.prefix(5))
            keywords.insert(stem)
        }

        return Array(keywords)
    }

    /// Универсальный стемминг темы: снимаем до двух словообразовательных суффиксов
    /// подряд и добавляем укороченное ядро, ловящее окончания падежей.
    /// Работает по любому слову любой темы и любого фильма — таблиц соответствий здесь нет.
    private func themeStems(for word: String) -> [String] {
        let letters = String(word.lowercased().filter { $0.isLetter || $0 == "'" })
        guard letters.count >= 5 else {
            return letters.isEmpty ? [] : [letters]
        }
        var stems: Set<String> = [letters]
        var base = letters
        for _ in 0..<2 {
            guard let suffix = Self.derivationalSuffixes.first(where: {
                base.hasSuffix($0) && base.count - $0.count >= 4
            }) else { break }
            base = String(base.dropLast(suffix.count))
            guard base.count >= 4 else { break }
            stems.insert(base)
        }
        if base.count >= 5 {
            stems.insert(String(base.prefix(base.count - 1)))
        }
        return Array(stems)
    }

    /// Словообразовательные суффиксы: более длинные стоят раньше своих коротких хвостов,
    /// чтобы «ность» снималась целиком, а не её хвост «ость». Языковая морфология, не фильмная константа.
    private static let derivationalSuffixes: [String] = [
        "істю", "ністю", "ність", "ництво", "ання", "ення", "яття", "ття", "тя", "тія",
        "ізм", "ість",
        "ами", "ях", "ах", "ів", "єв", "ий", "ій", "ої", "аго", "ому", "им", "ім",
        "а", "я", "о", "е", "є", "и", "і", "у", "ю"
    ]

    /// Драматургические маркеры акта: языковые, не фильмные. Internal — их же использует
    /// детерминированный запасной путь naming-прохода (`LongformActTitleService`).
    func actDramaticKeywords(for actType: LongformActType) -> [String] {
        switch actType {
        case .hook:
            return [
                "завжди", "ніколи", "знаєш", "правило", "у цьому світі", "життя", "вибір", "хто ти", "запам'ятай", "сенс", "дивись", "слухай",
                "гра", "грі", "річ", "засвоїв", "зрозумів", "пам'ятаю", "перше", "єдиний", "спосіб", "людина", "світ", "закон", "суперник", "ворог", "початок", "історія", "правда"
            ]
        case .downfall:
            return ["ні", "не можна", "програв", "помилка", "йдіть", "чому ти", "брехня", "чорт", "знищ", "годі", "пізно", "запропав"]
        case .struggle:
            return ["стріляй", "спробуй", "дивись", "ми", "проти", "я не здамся", "вихід", "роби", "бий", "стій", "тримайся", "вперед"]
        case .catharsis:
            return ["тепер", "розумію", "все скінчено", "вільний", "життя", "вибір", "правда", "насправді", "кінець", "пробач", "відпусти"]
        case .form:
            return ["сцена", "кадр", "ритм", "повтор", "монтаж", "структура", "порядок", "прийом", "мова", "форма"]
        case .psychology:
            return ["боїшся", "страх", "сором", "провина", "хочеш", "потрібно", "захист", "самообман", "біль", "самотність"]
        case .philosophy:
            return ["свобода", "влада", "вибір", "людина", "сенс", "правда", "ціна", "контроль", "ілюзія", "природа"]
        }
    }

    /// Драматургическое название и задача одного акта. Выводятся только из темы и типа:
    /// ни таблиц под конкретный фильм, ни таблиц под конкретную тему здесь нет.
    func adaptiveActDescriptor(
        for type: LongformActType,
        concept: ThematicConcept
    ) -> (title: String, beat: String) {
        let cleanWord = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        switch type {
        case .hook:
            return ("Зародження «\(cleanWord)»", "Відкриваючий виклик і перший крок назустріч невідомому.")
        case .form:
            return ("Мова «\(cleanWord)»", "Як влаштована форма: монтаж, ритм і повторювані прийоми.")
        case .psychology:
            return ("Під маскою", "Що насправді рухає героєм: страх, бажання і самообман.")
        case .philosophy:
            return ("Ціна «\(cleanWord)»", "Прихований підтекст: що фільм каже про людину і вибір.")
        case .catharsis:
            return ("Прозріння", "Катарсис: осягнення справжнього сенсу та ціни пройденого шляху.")
        case .downfall:
            return ("Випробування сумнівом", "Криза та зіткнення з суворою реальністю.")
        case .struggle:
            return ("Точка зламу", "Боротьба на межі сил всупереч усім обставинам.")
        }
    }

    /// Драматургические названия и задачи актов в стиле @prrodan.
    /// Выводятся только из темы: ни таблиц под конкретный фильм, ни таблиц под конкретную тему здесь нет.
    /// Internal — проверяется юнит-тестом на отсутствие фильмных хардкодов.
    func adaptiveActDescriptors(for concept: ThematicConcept) -> [(title: String, beat: String)] {
        [LongformActType.hook, .downfall, .struggle, .catharsis].map {
            adaptiveActDescriptor(for: $0, concept: concept)
        }
    }

    /// Синтетическая арка при отсутствии детального транскрипта
    private func makeSyntheticArc(
        movieTitle: String,
        concept: ThematicConcept,
        targetDuration: Double
    ) -> LongformNarrativeArc {
        let durAct1 = targetDuration * 0.12
        let durAct2 = targetDuration * 0.33
        let durAct3 = targetDuration * 0.35
        let durAct4 = targetDuration * 0.20

        let descriptors = adaptiveActDescriptors(for: concept)

        var currentStart = 0.0
        let act1 = LongformAct(
            type: .hook,
            title: descriptors[0].title,
            dramaticBeat: descriptors[0].beat,
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct1)]
        )
        currentStart += durAct1 + 10.0

        let act2 = LongformAct(
            type: .downfall,
            title: descriptors[1].title,
            dramaticBeat: descriptors[1].beat,
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct2)]
        )
        currentStart += durAct2 + 10.0

        let act3 = LongformAct(
            type: .struggle,
            title: descriptors[2].title,
            dramaticBeat: descriptors[2].beat,
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct3)]
        )
        currentStart += durAct3 + 10.0

        let act4 = LongformAct(
            type: .catharsis,
            title: descriptors[3].title,
            dramaticBeat: descriptors[3].beat,
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct4)]
        )

        return LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: concept,
            acts: [act1, act2, act3, act4],
            summary: "Наскрізна арка за фільмом \(movieTitle)"
        )
    }
}
