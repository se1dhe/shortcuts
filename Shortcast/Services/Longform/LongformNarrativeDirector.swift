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

        let act1Segs = selectCohesiveSegments(from: segments, in: act1Window, targetDuration: durAct1)
        let act2Segs = selectCohesiveSegments(from: segments, in: act2Window, targetDuration: durAct2)
        let act3Segs = selectCohesiveSegments(from: segments, in: act3Window, targetDuration: durAct3)
        let act4Segs = selectCohesiveSegments(from: segments, in: act4Window, targetDuration: durAct4)

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

    /// Выбирает непрерывный связный блок диалога заданной длительности внутри временного окна
    private func selectCohesiveSegments(
        from allSegments: [TranscriptSegment],
        in window: ClosedRange<Double>,
        targetDuration: Double
    ) -> [TimeSegment] {
        let candidates = allSegments.filter { $0.start >= window.lowerBound && $0.end <= window.upperBound }
        guard !candidates.isEmpty else {
            let start = window.lowerBound
            return [TimeSegment(start: start, end: start + targetDuration)]
        }

        // Ищем плотный блок диалогов с наилучшей смысловой насыщенностью
        var bestStartIdx = 0
        var bestLength = 0
        var bestScore = 0

        for i in 0..<candidates.count {
            var currDur = 0.0
            var j = i
            var wordCount = 0
            while j < candidates.count && currDur < targetDuration {
                currDur = candidates[j].end - candidates[i].start
                wordCount += candidates[j].words.count
                j += 1
            }
            if wordCount > bestScore {
                bestScore = wordCount
                bestStartIdx = i
                bestLength = j - i
            }
        }

        let slice = candidates[bestStartIdx..<(min(bestStartIdx + max(bestLength, 1), candidates.count))]
        guard let first = slice.first, let last = slice.last else {
            return [TimeSegment(start: window.lowerBound, end: window.lowerBound + targetDuration)]
        }

        let actualDur = last.end - first.start
        if actualDur > targetDuration * 1.35 {
            // Обрезаем до целевой длительности
            return [TimeSegment(start: first.start, end: first.start + targetDuration)]
        }

        return [TimeSegment(start: first.start, end: max(last.end, first.start + 15.0))]
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
