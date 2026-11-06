import Foundation

/// Проверяет материальное основание режиссёрского плана. Совпадение цитаты
/// доказывает таймкод, но не заменяет редакционную оценку смысла сцены.
enum EssaySceneEvidence {
    struct InvalidSelection: LocalizedError, Sendable {
        let issues: [String]
        var errorDescription: String? {
            "План сцен не подтверждён транскриптом: " + issues.prefix(6).joined(separator: "; ")
        }
    }

    static func validate(_ analysis: ThematicAnalysisResult, transcript: Transcript) throws {
        let segments = TranscriptQualityGate(segments: transcript.segments)
            .filtered(transcript.segments).sorted { $0.start < $1.start }
        let filmEnd = transcript.segments.map(\.end).filter(\.isFinite).max() ?? 0
        let moments = analysis.selectedMoments
        var issues: [String] = []
        guard analysis.primaryConcept.format.sceneCount.contains(moments.count) else {
            throw InvalidSelection(issues: ["нужно 14–22 сцены от модели, получено \(moments.count)"])
        }
        if analysis.essayPlan?.thesis?.trimmed.isEmpty != false {
            issues.append("нет тезиса эссе")
        }
        for role in analysis.primaryConcept.format.roles {
            let count = moments.filter { $0.actRole == role }.count
            let minimum = analysis.primaryConcept.format.minimumScenes(role)
            if count < minimum {
                issues.append("для акта \(role.promptKey) нужно \(minimum) сцен, получено \(count)")
            }
            if role != .hook, analysis.essayPlan?.focus(for: role) == nil {
                issues.append("нет доказуемого тезиса акта \(role.promptKey)")
            }
        }
        if moments.filter({ $0.actRole == .hook }).count != 1 {
            issues.append("хук должен быть одной сценой")
        }

        var ranges: [SelectedMoment] = []
        for (index, moment) in moments.enumerated() {
            let label = "сцена \(index + 1)"
            guard moment.startTime.isFinite, moment.endTime.isFinite,
                  moment.startTime >= 0, moment.endTime <= filmEnd else {
                issues.append("\(label): диапазон вне фильма")
                continue
            }
            let duration = moment.endTime - moment.startTime
            guard EssayDurationPolicy.sceneLength.contains(duration) else {
                issues.append("\(label): длительность \(String(format: "%.3f", duration)) с вне правила 18–40 с (\(String(format: "%.3f", moment.startTime))–\(String(format: "%.3f", moment.endTime)) с)")
                continue
            }
            if !moment.dramaticWeight.isFinite || !(0...1).contains(moment.dramaticWeight) {
                issues.append("\(label): недопустимый вес")
            }
            if moment.actRole.map({ !analysis.primaryConcept.format.roles.contains($0) }) ?? true {
                issues.append("\(label): нет аналитической роли")
            }
            if moment.supports?.trimmed.isEmpty != false {
                issues.append("\(label): не объяснено, что сцена доказывает")
            }
            if ranges.contains(where: {
                $0.startTime < moment.endTime && moment.startTime < $0.endTime
            }) {
                issues.append("\(label): повтор или пересечение с другой сценой")
            }
            ranges.append(moment)

            let quote = normalized(moment.evidenceQuote ?? "")
            guard quote.split(separator: " ").count >= 2, quote.count >= 12 else {
                issues.append("\(label): нет дословной цитаты-основания")
                continue
            }
            let dialogue = segments.filter {
                $0.end > moment.startTime && $0.start < moment.endTime
            }.map(\.text).joined(separator: " ")
            if !(" " + normalized(dialogue) + " ").contains(" " + quote + " ") {
                issues.append("\(label): цитата не звучит в указанном диапазоне")
            }
        }
        let contentSeconds = ranges.reduce(0) { $0 + $1.endTime - $1.startTime }
        // Для нижнего порога считаем только действительно присутствующие акты
        // и их внутренние паузы; постоянные паузы не должны маскировать недобор.
        let actCount = Set(moments.compactMap(\.actRole)).count
        let estimate = contentSeconds + 4 + Double(max(0, actCount - 1)) * 0.8
            + Double(max(0, ranges.count - actCount)) * LongformTimeline.intraActGap
        if estimate < EssayDurationPolicy.rendered.lowerBound {
            issues.append("план короче 4 минут; модель должна выбрать больше подходящего материала")
        }
        guard issues.isEmpty else { throw InvalidSelection(issues: issues) }
    }

    /// Последняя проверка ДО AVComposition: review/trim не имеют права незаметно
    /// подменить выбранные сцены или их смысловые роли.
    static func validateArc(
        _ arc: LongformNarrativeArc,
        selectedMoments: [SelectedMoment],
        coldOpenEnabled: Bool,
        allowApprovedTrim: Bool = false,
        allowUserApprovedScenes: Bool = false
    ) throws {
        var issues: [String] = []
        if arc.acts.map(\.type) != arc.concept.format.roles {
            issues.append("нарушен порядок смысловых актов")
        }
        var seen: [TimeSegment] = []
        for act in arc.acts {
            if act.segments.isEmpty { issues.append("пустой акт \(act.type.promptKey)") }
            for range in act.segments {
                if !range.start.isFinite || !range.end.isFinite || range.start < 0 || range.duration < 0.1 {
                    issues.append("некорректные границы фрагмента в акте \(act.type.promptKey)")
                }
                if !allowUserApprovedScenes && !selectedMoments.contains(where: { moment in
                    let sameRange = abs(moment.startTime - range.start) < 0.001
                        && abs(moment.endTime - range.end) < 0.001
                    let approvedTrim = allowApprovedTrim && range.duration >= EssayDurationPolicy.sceneLength.lowerBound
                        && range.start >= moment.startTime && range.end <= moment.endTime
                    let manualAddition = arc.sceneEdits?.contains(where: { edit in
                        edit.role == act.type && edit.revised == range
                            && edit.reason == LongformSceneEdit.manualAdditionReason
                            && EssayDurationPolicy.sceneLength.contains(range.duration)
                    }) ?? false
                    let approvedEdit = arc.sceneEdits?.contains(where: { edit in
                        edit.role == act.type && edit.original.start == moment.startTime
                            && edit.original.end == moment.endTime && edit.revised == range
                            && !edit.reason.trimmed.isEmpty
                            && LongformEditorialSupport.allowed(range, around: edit.original)
                    }) ?? false
                    return (moment.actRole == act.type && (sameRange || approvedTrim || approvedEdit))
                        || manualAddition
                }) {
                    issues.append("в монтаж попала неподтверждённая сцена или изменена её роль")
                }
                if !allowUserApprovedScenes && seen.contains(where: { $0.start < range.end && range.start < $0.end }) {
                    issues.append("в монтаже повторяется фрагмент фильма")
                }
                seen.append(range)
            }
        }
        let timeline = LongformTimeline(arc: arc, coldOpenEnabled: coldOpenEnabled)
        let duration = timeline.duration
        let editorialDuration = duration - timeline.supportExtraDuration
        if !duration.isFinite || duration <= 0.1
            || (!allowUserApprovedScenes && !EssayDurationPolicy.rendered.contains(editorialDuration)) {
            issues.append(allowUserApprovedScenes
                ? "длительность монтажа некорректна"
                : "подтверждённый монтаж короче 4 минут")
        }
        guard issues.isEmpty else { throw InvalidSelection(issues: issues) }
    }

    private static func normalized(_ text: String) -> String {
        DirectorArtifactGate.dropApostrophes(text.lowercased())
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
