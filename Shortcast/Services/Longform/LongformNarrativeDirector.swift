import Foundation

/// Реализация 4-актного режиссера длинных кинематографических видео Shortcast Cinema
final class LongformNarrativeDirector: LongformNarrativeDirecting, Sendable {

    /// Подсказка для LLM при анализе полного фильма
    static func directorPrompt(
        movieTitle: String,
        concept: ThematicConcept,
        targetDuration: Double
    ) -> String {
        """
        Ты — главный режиссер монтажа глубоких кинематографических эссе Shortcast Cinema.
        Твоя задача — из полного фильма "\(movieTitle)" смонтировать 4-актный ролик хронометражем \(Int(targetDuration)) секунд (7-10 минут) вокруг темы: "\(concept.word)".
        
        Смысловой посыл: "\(concept.philosophicalPremise)"

        СТРОГАЯ 4-АКТНАЯ СТРУКТУРА:
        1. Акт 1: "Хук и Тезис" (~50-70с). Сильнейший диалог или монолог, задающий главный конфликт.
        2. Акт 2: "Падение и Испытание" (~150-180с). Разрушение стабильности, потеря, кризис, сомнения героя.
        3. Акт 3: "Борьба и Упорство" (~160-190с). Пик напряжения, борьба вопреки всему, способность терпеть боль.
        4. Акт 4: "Катарсис и Прорыв" (~90-120с). Финальное откровение, триумф духа или пронзительное экзистенциальное одиночество.
        """
    }

    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double = 520.0
    ) async throws -> LongformNarrativeArc {
        let clampedTarget = min(max(targetDuration, 300.0), 600.0)
        let segments = transcript.segments

        guard !segments.isEmpty else {
            // Если транскрипт пуст, возвращаем синтетическую тестовую структуру
            return makeSyntheticArc(
                movieTitle: movieTitle,
                concept: concept,
                targetDuration: clampedTarget
            )
        }

        let totalMovieDuration = segments.last?.end ?? clampedTarget
        let isFullMovie = totalMovieDuration > 900.0 // >15 мин

        // Бюджет длительности по актам
        let durAct1 = clampedTarget * LongformActType.hook.targetDurationRatio
        let durAct2 = clampedTarget * LongformActType.downfall.targetDurationRatio
        let durAct3 = clampedTarget * LongformActType.struggle.targetDurationRatio
        let durAct4 = clampedTarget * LongformActType.catharsis.targetDurationRatio

        // Строгая изоляция временных окон и отслеживание использованных фрагментов для исключения дублей
        var usedRanges: [TimeSegment] = []
        var lastActEnd: Double = 0.0

        // Для первого акта (Хук/Тезис) охватываем первую треть фильма (до 35%),
        // чтобы можно было гибко выбрать сильный эпизод как из пролога, так и из середины первой половины.
        let act1Window: ClosedRange<Double> = 0.0 ... (isFullMovie ? totalMovieDuration * 0.35 : totalMovieDuration * 0.25)
        let act1Segs = selectCohesiveSegments(
            from: segments,
            in: act1Window,
            minStartTime: 0.0,
            usedRanges: usedRanges,
            targetDuration: durAct1,
            concept: concept,
            actType: .hook
        )
        usedRanges.append(contentsOf: act1Segs)
        lastActEnd = act1Segs.map(\.end).max() ?? 0.0

        let act2Min = max(lastActEnd + 2.0, isFullMovie ? (totalMovieDuration * 0.15) : (totalMovieDuration * 0.20))
        let act2Max = max(act2Min + durAct2 * 1.5, isFullMovie ? (totalMovieDuration * 0.60) : (totalMovieDuration * 0.50))
        let act2Window: ClosedRange<Double> = act2Min ... act2Max
        let act2Segs = selectCohesiveSegments(
            from: segments,
            in: act2Window,
            minStartTime: lastActEnd + 1.0,
            usedRanges: usedRanges,
            targetDuration: durAct2,
            concept: concept,
            actType: .downfall
        )
        usedRanges.append(contentsOf: act2Segs)
        lastActEnd = act2Segs.map(\.end).max() ?? lastActEnd

        let act3Min = max(lastActEnd + 2.0, isFullMovie ? (totalMovieDuration * 0.50) : (totalMovieDuration * 0.50))
        let act3Max = max(act3Min + durAct3 * 1.5, isFullMovie ? (totalMovieDuration * 0.82) : (totalMovieDuration * 0.80))
        let act3Window: ClosedRange<Double> = act3Min ... act3Max
        let act3Segs = selectCohesiveSegments(
            from: segments,
            in: act3Window,
            minStartTime: lastActEnd + 1.0,
            usedRanges: usedRanges,
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
            targetDuration: durAct4,
            concept: concept,
            actType: .catharsis
        )
        usedRanges.append(contentsOf: act4Segs)

        let descriptors = adaptiveActDescriptors(for: concept, movieTitle: movieTitle)

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

        return LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: concept,
            acts: acts,
            summary: "Сквозное 4-актное эссе «\(concept.word)» по фильму «\(movieTitle)»",
            mood: "dramatic"
        )
    }

    private func overlapsAny(range: TimeSegment, in used: [TimeSegment]) -> Bool {
        used.contains { existing in
            max(existing.start, range.start) < min(existing.end, range.end)
        }
    }

    /// Выбирает диалоговый фрагмент, семантически соответствующий концепту и драматургии акта
    private func selectCohesiveSegments(
        from allSegments: [TranscriptSegment],
        in window: ClosedRange<Double>,
        minStartTime: Double = 0.0,
        usedRanges: [TimeSegment] = [],
        targetDuration: Double,
        concept: ThematicConcept,
        actType: LongformActType,
        allowChaining: Bool = true
    ) -> [TimeSegment] {
        let candidates = allSegments.filter {
            $0.start >= max(window.lowerBound, minStartTime) && $0.start <= window.upperBound
        }
        guard !candidates.isEmpty else {
            let start = max(window.lowerBound, minStartTime)
            return [TimeSegment(start: start, end: start + targetDuration)]
        }

        let thematicKeywords = extractThematicKeywords(for: concept)
        let dramaticKeywords = actDramaticKeywords(for: actType)
        let coreWord = concept.word.lowercased()

        var bestStartIdx = -1
        var bestLength = 0
        var bestScore: Double = -Double.greatestFiniteMagnitude

        for i in 0..<candidates.count {
            var currDur = 0.0
            var j = i
            var wordCount = 0
            var thematicMatchPoints = 0
            var dramaticBeatCount = 0
            var fillerCount = 0
            var calmIntroBonus = 0.0
            var panicPenalty = 0.0

            let maxSceneGap: Double = (actType == .hook) ? 3.4 : 4.5

            while j < candidates.count && currDur < targetDuration {
                let seg = candidates[j]
                if j > i {
                    let sceneGap = seg.start - candidates[j - 1].end
                    if sceneGap > maxSceneGap {
                        // Сцена закончилась, далее идет другой эпизод фильма
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

                // 5. Для Акта 4 (Катарсис): бонус за ключевые философские цитаты-откровения фильма
                if actType == .catharsis {
                    let revelationKeywords = [
                        "он — это ты", "он это ты", "разводк", "лучшая разводка",
                        "заставил тебя поверить", "шахматн", "правила игры", "враг внутри",
                        "поверить, что он", "поверить что он", "победа над собой"
                    ]
                    for rk in revelationKeywords {
                        if lowerText.contains(rk) {
                            thematicMatchPoints += 25
                        }
                    }
                }

                // 6. Штраф за пустые короткие междометия
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

            // Если это финал (Акт IV), кандидат ОБЯЗАН быть законченной мыслью
            if actType == .catharsis && !thoughtEval.isCompleteThought {
                continue
            }

            let minAllowedDur: Double
            if actType == .catharsis {
                // Если фраза несет высший катарсис, допускаем лаконичный афоризм от 5.0с
                minAllowedDur = thoughtEval.isCompleteThought ? 5.0 : min(20.0, targetDuration * 0.40)
            } else {
                minAllowedDur = min(20.0, targetDuration * 0.40)
            }
            guard currDur >= minAllowedDur else { continue }

            let candidateRange = TimeSegment(start: candidates[i].start, end: candidates[j - 1].end)
            if overlapsAny(range: candidateRange, in: usedRanges) {
                continue
            }

            let durationFillRatio = min(1.0, currDur / targetDuration)
            let speechDensity = currDur > 0 ? Double(wordCount) / currDur : 0.0

            // Оценка плотности речи:
            // Для Акта 1 (Хук/Экспозиция) идеален спокойный, размеренный монолог (0.4 ... 1.15 слов/сек)
            let densityScore: Double
            if actType == .hook {
                if speechDensity >= 0.4 && speechDensity <= 1.15 {
                    densityScore = 25.0
                } else if speechDensity > 1.35 {
                    densityScore = -25.0
                } else {
                    densityScore = 5.0
                }
            } else {
                densityScore = (speechDensity >= 1.0 ? 12.0 : -6.0)
            }

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

            if score > bestScore {
                bestScore = score
                bestStartIdx = i
                bestLength = j - i
            }
        }

        guard bestStartIdx >= 0 else {
            let start = max(window.lowerBound, minStartTime)
            return [TimeSegment(start: start, end: start + targetDuration)]
        }

        let slice = candidates[bestStartIdx..<(min(bestStartIdx + max(bestLength, 1), candidates.count))]
        guard let first = slice.first, let last = slice.last else {
            return [TimeSegment(start: window.lowerBound, end: window.lowerBound + targetDuration)]
        }

        let isAct1 = (actType == .hook)
        let isAct3 = (actType == .struggle)
        let isAct4 = (actType == .catharsis)
        let minSegmentDuration = isAct4 ? 5.0 : 15.0
        let rawRange = TimeSegment(start: first.start, end: max(last.end, first.start + minSegmentDuration))
        let headPadding: Double = isAct1 ? 3.0 : (isAct3 ? 1.2 : (isAct4 ? 1.5 : 0.5))
        // Хвостовой паддинг строго 0.35с для естественного затухания реплики без захвата следующих сцен фильма.
        // Финальный хвост послевкусия (черный экран и затухающая музыка) добавляется на этапе AVComposition.
        let tailPadding: Double = 0.35
        let maxSceneDuration = targetDuration * 1.75

        let detector = SentenceBoundaryDetector(
            headPadding: headPadding,
            tailPadding: tailPadding,
            minSegmentDuration: minSegmentDuration,
            maxShortsDuration: maxSceneDuration
        )

        let refined = detector.refineSceneBoundary(
            range: rawRange,
            maxAllowedDuration: maxSceneDuration,
            in: allSegments
        )

        var resultSegments = [refined]

        // Для Актов 2 и 3: если главная сцена короче 65% от целевого хронометража (например, 70с из 170с),
        // дополняем ее второй смысловой сценой из того же окна сюжета без наложения для выхода на хронометраж 7-10 минут
        if allowChaining && (actType == .downfall || actType == .struggle) && refined.duration < (targetDuration * 0.65) {
            let remainingBudget = targetDuration - refined.duration
            let secondaryMinStartTime = refined.end + 6.0
            var extendedUsed = usedRanges
            extendedUsed.append(refined)

            let secondaryCandidates = allSegments.filter {
                $0.start >= max(window.lowerBound, secondaryMinStartTime) && $0.start <= window.upperBound
            }
            if !secondaryCandidates.isEmpty {
                let secondarySegments = selectCohesiveSegments(
                    from: allSegments,
                    in: window,
                    minStartTime: secondaryMinStartTime,
                    usedRanges: extendedUsed,
                    targetDuration: remainingBudget,
                    concept: concept,
                    actType: actType,
                    allowChaining: false
                )
                if let secFirst = secondarySegments.first, secFirst.duration >= 18.0 {
                    resultSegments.append(secFirst)
                }
            }
        }

        return resultSegments
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

    private func extractThematicKeywords(for concept: ThematicConcept) -> [String] {
        var keywords: Set<String> = []
        let wordLower = concept.word.lowercased()
        keywords.insert(wordLower)

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

    /// Адаптивные драматургические названия и задачи актов под тему и фильм в стиле @prrodan
    private func adaptiveActDescriptors(
        for concept: ThematicConcept,
        movieTitle: String
    ) -> [(title: String, beat: String)] {
        let w = concept.word.lowercased()
        let t = movieTitle.lowercased()

        if w.contains("иллюзи") || w.contains("эго") || w.contains("обман") || t.contains("револьвер") || t.contains("revolver") {
            return [
                ("Шахматная партия", "Правила игры, в которой ты думаешь, что контролируешь ситуацию."),
                ("Голос, которому ты веришь", "Разрушение уверенности: главный враг говорит твоим голосом."),
                ("Смерть своего эго", "Предел страха: признать ложь и встретиться с истинным врагом."),
                ("Кто дёргает за ниточки", "Катарсис: освобождение от власти иллюзии и победа над собой.")
            ]
        } else if w.contains("деньг") || w.contains("успех") || w.contains("жадност") || w.contains("власт") {
            return [
                ("Правила игры", "Открывающий конфликт: цена власти и первый крупный куш."),
                ("Голод без насыщения", "Разрушение принципов, потеря контроля и растущие аппетиты."),
                ("Точка невозврата", "Пик давления: когда система начинает пожирать тебя самого."),
                ("Пустота на вершине", "Катарсис: что остаётся, когда всё куплено, но ничего не спасает.")
            ]
        } else if w.contains("дисциплин") || w.contains("терпен") || w.contains("характер") || w.contains("вол") || w.contains("сил") {
            return [
                ("Вызов и амбиция", "Исходная точка: готовность пойти дальше, чем готовы пойти другие."),
                ("Кровь и сомнения", "Падение: когда кажется, что все усилия были напрасны."),
                ("Предел прочности", "Кульминация борьбы: способность терпеть боль и продолжать идти."),
                ("Триумф характера", "Катарсис: победа не над соперником, а над собственной слабостью.")
            ]
        } else if w.contains("одиночеств") || w.contains("пустот") || w.contains("страх") || w.contains("груст") || t.contains("сопрано") || t.contains("soprano") {
            return [
                ("Тяжесть фасада", "Внешняя сила и внутренняя трещина, которую никто не видит."),
                ("Круг сужается", "Одиночество среди людей: потеря доверия и страх ошибки."),
                ("Один на один с тьмой", "Пик экзистенциального кризиса: от чего не спасают статус и влияние."),
                ("Момент тишины", "Катарсис: осознание правды о себе, когда всё лишнее отброшено.")
            ]
        } else {
            let cleanWord = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
            return [
                ("Зарождение «\(cleanWord)»", "Открывающий вызов и первый шаг навстречу неизвестности."),
                ("Испытание сомнением", "Кризис и столкновение с суровой реальностью."),
                ("Точка слома", "Борьба на пределе сил вопреки всем обстоятельствам."),
                ("Прозрение", "Катарсис: обретение подлинного смысла и цены пройденного пути.")
            ]
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

        let descriptors = adaptiveActDescriptors(for: concept, movieTitle: movieTitle)

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
