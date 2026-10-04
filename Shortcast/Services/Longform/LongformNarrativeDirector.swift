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
        Твоя задача — из полного фильма "\(movieTitle)" смонтировать 4-актный ролик хронометражем \(Int(targetDuration)) секунд (5-8 минут) вокруг темы: "\(concept.word)".
        
        Смысловой посыл: "\(concept.philosophicalPremise)"

        СТРОГАЯ 4-АКТНАЯ СТРУКТУРА:
        1. Акт 1: "Хук и Тезис" (~40-50с). Сильнейший диалог или монолог, задающий главный конфликт.
        2. Акт 2: "Падение и Испытание" (~110-140с). Разрушение стабильности, потеря, кризис, сомнения героя.
        3. Акт 3: "Борьба и Упорство" (~120-150с). Пик напряжения, борьба вопреки всему, способность терпеть боль.
        4. Акт 4: "Катарсис и Прорыв" (~70-100с). Финальное откровение, триумф духа или пронзительное экзистенциальное одиночество.
        """
    }

    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double = 380.0
    ) async throws -> LongformNarrativeArc {
        let clampedTarget = min(max(targetDuration, 300.0), 480.0)
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

        // Распределяем временные окна поиска актов
        let act1Window: ClosedRange<Double> = isFullMovie ? (0.0 ... totalMovieDuration * 0.25) : (0.0 ... totalMovieDuration * 0.20)
        let act2Window: ClosedRange<Double> = isFullMovie ? (totalMovieDuration * 0.15 ... totalMovieDuration * 0.50) : (totalMovieDuration * 0.20 ... totalMovieDuration * 0.50)
        let act3Window: ClosedRange<Double> = isFullMovie ? (totalMovieDuration * 0.45 ... totalMovieDuration * 0.80) : (totalMovieDuration * 0.50 ... totalMovieDuration * 0.80)
        let act4Window: ClosedRange<Double> = isFullMovie ? (totalMovieDuration * 0.70 ... totalMovieDuration) : (totalMovieDuration * 0.80 ... totalMovieDuration)

        // Бюджет длительности по актам
        let durAct1 = clampedTarget * LongformActType.hook.targetDurationRatio
        let durAct2 = clampedTarget * LongformActType.downfall.targetDurationRatio
        let durAct3 = clampedTarget * LongformActType.struggle.targetDurationRatio
        let durAct4 = clampedTarget * LongformActType.catharsis.targetDurationRatio

        let act1Segs = selectCohesiveSegments(
            from: segments,
            in: act1Window,
            targetDuration: durAct1,
            concept: concept,
            actType: .hook
        )
        let act2Segs = selectCohesiveSegments(
            from: segments,
            in: act2Window,
            targetDuration: durAct2,
            concept: concept,
            actType: .downfall
        )
        let act3Segs = selectCohesiveSegments(
            from: segments,
            in: act3Window,
            targetDuration: durAct3,
            concept: concept,
            actType: .struggle
        )
        let act4Segs = selectCohesiveSegments(
            from: segments,
            in: act4Window,
            targetDuration: durAct4,
            concept: concept,
            actType: .catharsis
        )

        let acts = [
            LongformAct(
                type: .hook,
                title: "Акт I: Исходная точка и вызов",
                dramaticBeat: "Открывающий монолог о цене пути и выборе.",
                segments: act1Segs
            ),
            LongformAct(
                type: .downfall,
                title: "Акт II: Испытание на прочность",
                dramaticBeat: "Крах иллюзий, кризис и непонимание окружения.",
                segments: act2Segs
            ),
            LongformAct(
                type: .struggle,
                title: "Акт III: Выдержка во тьме",
                dramaticBeat: "Пик борьбы, преодоление себя вопреки обстоятельствам.",
                segments: act3Segs
            ),
            LongformAct(
                type: .catharsis,
                title: "Акт IV: Цена победы и прозрение",
                dramaticBeat: "Катарсис: что остается, когда цель достигнута.",
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

    /// Выбирает диалоговый фрагмент, семантически соответствующий концепту и драматургии акта
    private func selectCohesiveSegments(
        from allSegments: [TranscriptSegment],
        in window: ClosedRange<Double>,
        targetDuration: Double,
        concept: ThematicConcept,
        actType: LongformActType
    ) -> [TimeSegment] {
        let candidates = allSegments.filter { $0.start >= window.lowerBound && $0.end <= window.upperBound }
        guard !candidates.isEmpty else {
            let start = window.lowerBound
            return [TimeSegment(start: start, end: start + targetDuration)]
        }

        let thematicKeywords = extractThematicKeywords(for: concept)
        let dramaticKeywords = actDramaticKeywords(for: actType)
        let coreWord = concept.word.lowercased()

        var bestStartIdx = 0
        var bestLength = 0
        var bestScore: Double = -10_000.0

        for i in 0..<candidates.count {
            var currDur = 0.0
            var j = i
            var wordCount = 0
            var thematicMatchPoints = 0
            var dramaticBeatCount = 0
            var fillerCount = 0

            while j < candidates.count && currDur < targetDuration {
                let seg = candidates[j]
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

                // 3. Штраф за пустые короткие междометия
                if words <= 2 && thematicMatchPoints == 0 {
                    fillerCount += 1
                }

                j += 1
            }

            guard currDur >= min(20.0, targetDuration * 0.40) else { continue }

            let durationFillRatio = min(1.0, currDur / targetDuration)
            let speechDensity = currDur > 0 ? Double(wordCount) / currDur : 0.0

            // Итоговый скор: максимальный вес отдается репликам по выбранной теме
            let score = (Double(thematicMatchPoints) * 50.0)
                + (Double(dramaticBeatCount) * 14.0)
                + (Double(wordCount) * 0.3)
                + (speechDensity >= 1.2 ? 15.0 : -10.0)
                - (Double(fillerCount) * 6.0)
                + (durationFillRatio * 15.0)

            if score > bestScore {
                bestScore = score
                bestStartIdx = i
                bestLength = j - i
            }
        }

        let slice = candidates[bestStartIdx..<(min(bestStartIdx + max(bestLength, 1), candidates.count))]
        guard let first = slice.first, let last = slice.last else {
            return [TimeSegment(start: window.lowerBound, end: window.lowerBound + targetDuration)]
        }

        let rawRange = TimeSegment(start: first.start, end: max(last.end, first.start + 15.0))
        let detector = SentenceBoundaryDetector(
            headPadding: 0.20,
            tailPadding: 0.45,
            minSegmentDuration: 15.0,
            maxShortsDuration: targetDuration * 1.35
        )

        var refined = detector.refineSceneBoundary(
            range: rawRange,
            maxAllowedDuration: targetDuration * 1.35,
            in: allSegments
        )

        // Для финального катарсиса (Акт 4) добавляем 2.8с атмосферного видеоряда
        // после завершения речи для кинематографического затухания в темноту
        if actType == .catharsis {
            refined = TimeSegment(start: refined.start, end: refined.end + 2.8)
        }

        return [refined]
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
            return ["всегда", "никогда", "знаешь", "правило", "в этом мире", "жизнь", "выбор", "кто ты", "запомни", "смысл", "смотри", "слушай"]
        case .downfall:
            return ["нет", "нельзя", "проиграл", "ошибка", "уходи", "почему ты", "ложь", "черт", "уничтож", "хватит", "поздно", "пропал"]
        case .struggle:
            return ["стреляй", "попробуй", "смотри", "мы", "против", "я не сдамся", "выход", "делай", "бей", "стой", "держись", "вперед"]
        case .catharsis:
            return ["теперь", "понимаю", "всё кончено", "свободен", "жизнь", "выбор", "правда", "на самом деле", "конец", "прости", "отпусти"]
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

        var currentStart = 0.0
        let act1 = LongformAct(
            type: .hook,
            title: "Хук и Тезис",
            dramaticBeat: "Открывающий конфликт",
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct1)]
        )
        currentStart += durAct1 + 10.0

        let act2 = LongformAct(
            type: .downfall,
            title: "Падение",
            dramaticBeat: "Кризис и сомнения",
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct2)]
        )
        currentStart += durAct2 + 10.0

        let act3 = LongformAct(
            type: .struggle,
            title: "Борьба",
            dramaticBeat: "Преодоление предела",
            segments: [TimeSegment(start: currentStart, end: currentStart + durAct3)]
        )
        currentStart += durAct3 + 10.0

        let act4 = LongformAct(
            type: .catharsis,
            title: "Катарсис",
            dramaticBeat: "Прорыв и финал",
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
