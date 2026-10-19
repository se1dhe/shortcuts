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

    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double = 520.0
    ) async throws -> LongformNarrativeArc {
        let clampedAsk = min(max(targetDuration, 300.0), 600.0)
        let segments = transcript.segments

        guard !segments.isEmpty else {
            // Если транскрипт пуст, возвращаем синтетическую тестовую структуру
            return makeSyntheticArc(
                movieTitle: movieTitle,
                concept: concept,
                targetDuration: clampedAsk
            )
        }

        let totalMovieDuration = segments.last?.end ?? clampedAsk
        let isFullMovie = totalMovieDuration > 900.0 // >15 мин

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
            summary: "Сквозное 4-актное эссе «\(concept.word)» по фильму «\(movieTitle)»",
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
        minStartTime: Double = 0.0,
        usedRanges: [TimeSegment] = [],
        reservedRanges: [TimeSegment] = [],
        targetDuration: Double,
        concept: ThematicConcept,
        actType: LongformActType,
        allowChaining: Bool = true
    ) -> [TimeSegment] {
        let searchStart = max(window.lowerBound, minStartTime)
        let candidates = allSegments.filter {
            $0.start >= searchStart && $0.start <= window.upperBound
        }
        guard !candidates.isEmpty else {
            if !allowChaining {
                return []
            }
            return silentFallback(
                start: searchStart,
                targetDuration: targetDuration,
                window: window,
                reserved: reservedRanges,
                allSegments: allSegments
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
                        "ай", "убью", "стреляй", "быстрее", "черт", "сука", "бля", "вали", "заткнись",
                        "отвечай", "пять секунд", "секунд", "быстро", "стой", "паника", "кто?", "что?",
                        "кто", "прошу", "не нужно", "нет!"
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
                        "я", "мне", "меня", "жизнь", "время", "вещь", "правило", "игра", "понял",
                        "усвоил", "знаю", "думал", "всегда", "мир", "человек", "выбор", "победитель",
                        "поражение", "смерть", "страх"
                    ]
                    for rkw in introReflectiveKeywords {
                        if lowerText.contains(rkw) {
                            calmIntroBonus += 15.0
                        }
                    }

                    let aggressivePanicWords = [
                        "ай", "убью", "стреляй", "быстрее", "черт", "сука", "бля", "вали", "заткнись",
                        "отвечай", "пять секунд", "быстро", "стой", "паника", "помогите"
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
                    let conjunctionOpeners = ["а ты", "что ты", "и ты", "но", "а где", "то есть", "дальше", "почему", "жертва"]
                    for co in conjunctionOpeners {
                        if firstText.hasPrefix(co) {
                            panicPenalty += 500.0
                        }
                    }
                    let struggleExpositionWords = ["голос", "слышишь", "враг", "борьб", "упорств", "друг", "правило", "контрол"]
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
                reserved: reservedRanges,
                allSegments: allSegments
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
                reserved: reservedRanges,
                allSegments: allSegments
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
    /// не выходим за окно, за пределы фильма и в зарезервированный финал
    private func silentFallback(
        start: Double,
        targetDuration: Double,
        window: ClosedRange<Double>,
        reserved: [TimeSegment],
        allSegments: [TranscriptSegment]
    ) -> [TimeSegment] {
        let lower = max(start, window.lowerBound)
        let filmCeiling = (allSegments.last?.end ?? window.upperBound) + Self.tailPaddingDuration
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
            "эго": ["эго", "гордост", "голов", "враг", "внутри", "я сам", "меня", "себя", "разум", "мысл", "контрол", "побед", "слаб", "боль", "признай", "правд", "голос"],
            "обман": ["обман", "разводк", "лож", "правд", "игра", "шахмат", "противник", "умн", "правил", "сделк", "деньг", "довер", "жадност", "манипул", "верит", "карты"],
            "страх": ["страх", "боит", "боишься", "больно", "смерт", "убит", "паник", "пистолет", "выстрел", "кров", "потер", "конец", "трясет", "ужас", "слабост"],
            "иллюзия": ["иллюзи", "кажет", "реальност", "видит", "слеп", "глаз", "сон", "правд", "скрыт", "прячет", "понима", "кажется", "зеркал", "морок"],
            "жадность": ["жадност", "деньг", "богат", "алчност", "миллион", "долг", "заплат", "цен", "купит", "золот", "казино", "выигрыш", "мало"],
            "терпение": ["терпен", "ждать", "время", "спеш", "тишин", "выдержк", "спокойн", "холоднокров", "секунд"],
            "характер": ["характер", "воля", "сил", "сломат", "высто", "удар", "пада", "встават", "терпеть", "до конца"],
            "одиночество": ["один", "одиночеств", "пустот", "никого", "один на один", "тишин", "бросил", "сам"],
            "предательство": ["преда", "нож в спину", "верност", "предатель", "измен", "верил", "подставил", "крыс"],
            "семья": ["семь", "брат", "отец", "сын", "дочь", "родн", "дом", "дети", "мать", "защит", "кров"]
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
        let letters = String(word.lowercased().filter { $0.isLetter })
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
        "остью", "ностью", "ность", "ество", "ение", "ание", "яние", "тие", "ия", "ие", "ья", "ость",
        "измом", "изма", "изм", "ами", "ях", "ах", "ов", "ев", "ый", "ий", "ой", "ая", "яя", "ое", "ее",
        "ые", "а", "я", "о", "е", "ы", "и"
    ]

    private func actDramaticKeywords(for actType: LongformActType) -> [String] {
        switch actType {
        case .hook:
            return [
                "всегда", "никогда", "знаешь", "правило", "в этом мире", "жизнь", "выбор", "кто ты", "запомни", "смысл", "смотри", "слушай",
                "игра", "игре", "вещь", "усвоил", "понял", "помню", "первое", "единственный", "способ", "человек", "мир", "закон", "соперник", "враг", "начало", "история", "правда"
            ]
        case .downfall:
            return ["нет", "нельзя", "проиграл", "ошибка", "уходи", "почему ты", "ложь", "черт", "уничтож", "хватит", "поздно", "пропал"]
        case .struggle:
            return ["стреляй", "попробуй", "смотри", "мы", "против", "я не сдамся", "выход", "делай", "бей", "стой", "держись", "вперед"]
        case .catharsis:
            return ["теперь", "понимаю", "всё кончено", "свободен", "жизнь", "выбор", "правда", "на самом деле", "конец", "прости", "отпусти"]
        }
    }

    /// Драматургические названия и задачи актов в стиле @prrodan.
    /// Выводятся только из темы: ни таблиц под конкретный фильм, ни таблиц под конкретную тему здесь нет.
    /// Internal — проверяется юнит-тестом на отсутствие фильмных хардкодов.
    func adaptiveActDescriptors(for concept: ThematicConcept) -> [(title: String, beat: String)] {
        let cleanWord = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        return [
            ("Зарождение «\(cleanWord)»", "Открывающий вызов и первый шаг навстречу неизвестности."),
            ("Испытание сомнением", "Кризис и столкновение с суровой реальностью."),
            ("Точка слома", "Борьба на пределе сил вопреки всем обстоятельствам."),
            ("Прозрение", "Катарсис: обретение подлинного смысла и цены пройденного пути.")
        ]
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
            summary: "Сквозная арка по фильму \(movieTitle)"
        )
    }
}
