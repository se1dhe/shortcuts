import Foundation

/// Длительность определяется материалом темы: минимум четыре минуты,
/// без верхнего ограничения и сокращения плана ради хронометража.
enum EssayDurationPolicy {

    /// Бесконечная верхняя граница сохраняет общий API проверок диапазона.
    static let rendered: ClosedRange<Double> = 240...Double.infinity

    /// Одна цельная сцена из диалогов фильма, а не отдельная реплика.
    static let sceneLength: ClosedRange<Double> = 18...40

    /// Ранжованный пул сцен, который просим у модели.
    static let pool: ClosedRange<Int> = 14...22

    /// Минимальный запас: cold open + аутро + четыре межактных разделения.
    /// После редакторского прохода длительность финальной карточки рассчитывает
    /// LongformTimeline по объёму текста; приёмка арки использует точный таймлайн.
    static let fixedPadding: Double = LongformTimeline.intro + LongformTimeline.outro
        + 4 * LongformTimeline.interActGap

    /// Граница внутри акта (между сценой и сценой одного акта).
    static let intraActGap: Double = LongformTimeline.intraActGap

    /// Запасная цель для проекта без записанной длительности.
    static let defaultRenderedTarget: Double = 360

    /// Сколько «чистого» материала остаётся под выбранное окно. Единственная
    /// формула перехода «рендер ↔ контент»: монтаж мыслит именно ею, а `rendered`
    /// остаётся свойством готового файла.
    static func contentBudget(renderedTarget: Double, scenes: Int) -> Double {
        let gaps = Double(max(0, scenes - 1)) * intraActGap
        return max(0, clamp(renderedTarget) - fixedPadding - gaps)
    }

    /// Материал не обрезается ради верхней границы длительности.
    static func contentCeiling(scenes: Int) -> Double { .infinity }

    /// Контент, ниже которого рендер не доходит и до 4:00. Недобор материала —
    /// это свойство темы, а не настройка: доливать его выдумкой нельзя.
    static func contentFloor(scenes: Int) -> Double {
        contentBudget(renderedTarget: rendered.lowerBound, scenes: scenes)
    }

    /// Длина эссе выводится из материала, а не из просьбы: пул сцен модели
    /// плюс склейки, с минимумом четыре минуты и без верхнего предела.
    /// Без числа сцен эта оценка не видит пауз между сценами и потому занижена —
    /// рабочий путь монтажа обязан звать вариант `renderedTarget(poolSeconds:scenes:)`.
    static func renderedTarget(poolSeconds: Double) -> Double {
        clamp(poolSeconds + fixedPadding)
    }

    /// То же окно, но честно: склейки считаются по фактическому числу сцен пула.
    /// Именно отсюда берётся бюджет контента, и поэтому пул, влезающий в коридор,
    /// монтируется без добора и без обрезки.
    static func renderedTarget(poolSeconds: Double, scenes: Int) -> Double {
        clamp(estimatedRendered(poolSeconds: poolSeconds, scenes: scenes))
    }

    /// Оценка готового рендера по смонтированном контенте и ФАКТИЧЕСКОМ числе
    /// сцен: речь + постоянные склейки + пауза между каждой парой соседних сцен.
    /// Обратная задача — `contentBudget`; вместе они и есть единственная конвенция
    /// «targetDuration = секунды контента», без двойного счёта склеек.
    static func estimatedRendered(contentSeconds: Double, scenes: Int) -> Double {
        max(0, contentSeconds) + fixedPadding + Double(max(0, scenes - 1)) * intraActGap
    }

    /// Оценка рендера для пула модели до монтажа: голый материал плюс все склейки
    /// между его сценами. Пул — он же и есть контент, поэтому та же формула.
    static func estimatedRendered(poolSeconds: Double, scenes: Int) -> Double {
        estimatedRendered(contentSeconds: poolSeconds, scenes: scenes)
    }

    /// То же для собранной арки: сверяют именно эту величину, а не угаданный
    /// хронометраж будущего экспорта.
    static func estimatedRendered(of arc: LongformNarrativeArc) -> Double {
        LongformTimeline(arc: arc).duration
    }

    /// nil — оценка внутри коридора. Иначе — готовая строка для `degradationReason`
    /// и для дорендерного гейта: вне коридора это ошибка, а не предупреждение.
    static func corridorViolation(estimate: Double) -> String? {
        guard estimate.isFinite else { return "некорректная длительность эссе" }
        if estimate < rendered.lowerBound {
            return "материал темы собирается на \(format(estimate)) — меньше \(format(rendered.lowerBound)), чем требует коридор"
        }
        return nil
    }

    static func corridorViolation(of arc: LongformNarrativeArc) -> String? {
        corridorViolation(estimate: estimatedRendered(of: arc))
    }

    /// Тонкий пул — не катастрофа, а честная пометка: монтаж дотянет его целыми
    /// диалогами, но зритель обязан видеть, что тема была бедной на материал.
    static func poolShortfallNote(count: Int) -> String? {
        guard count < pool.lowerBound else { return nil }
        return "модель отдала \(count) сцен вместо \(pool.lowerBound)–\(pool.upperBound)"
    }

    /// Сохраняем длительность длинных проектов; проверяем минимум и конечность.
    static func clamp(_ seconds: Double) -> Double {
        seconds.isFinite ? max(seconds, rendered.lowerBound) : defaultRenderedTarget
    }

    /// «7:43» для честной строки в UI.
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
