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
        guard EssayDurationPolicy.pool.contains(moments.count) else {
            throw InvalidSelection(issues: ["нужно 14–22 сцены от модели, получено \(moments.count)"])
        }
        if analysis.essayPlan?.thesis?.trimmed.isEmpty != false {
            issues.append("нет тезиса эссе")
        }
        for role in LongformActType.canonicalAnalyticOrder {
            let count = moments.filter { $0.actRole == role }.count
            let minimum = role == .hook ? 1 : 3
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
                  moment.startTime >= 0, moment.endTime <= filmEnd,
                  EssayDurationPolicy.sceneLength.contains(moment.endTime - moment.startTime) else {
                issues.append("\(label): диапазон вне фильма или правила 18–40 с")
                continue
            }
            if !moment.dramaticWeight.isFinite || !(0...1).contains(moment.dramaticWeight) {
                issues.append("\(label): недопустимый вес")
            }
            if moment.actRole.map({ !LongformActType.canonicalAnalyticOrder.contains($0) }) ?? true {
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
        } else if estimate > EssayDurationPolicy.rendered.upperBound {
            issues.append("план длиннее 8 минут; модель должна распределить сцены в коридоре")
        }
        guard issues.isEmpty else { throw InvalidSelection(issues: issues) }
    }

    /// Последняя проверка ДО AVComposition: review/trim не имеют права незаметно
    /// подменить выбранные сцены или их смысловые роли.
    static func validateArc(
        _ arc: LongformNarrativeArc,
        selectedMoments: [SelectedMoment],
        coldOpenEnabled: Bool,
        allowApprovedTrim: Bool = false
    ) throws {
        var issues: [String] = []
        if arc.acts.map(\.type) != LongformActType.canonicalAnalyticOrder {
            issues.append("нарушен порядок смысловых актов")
        }
        var seen: [TimeSegment] = []
        for act in arc.acts {
            if act.segments.isEmpty { issues.append("пустой акт \(act.type.promptKey)") }
            for range in act.segments {
                if !selectedMoments.contains(where: { moment in
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
                if seen.contains(where: { $0.start < range.end && range.start < $0.end }) {
                    issues.append("в монтаже повторяется фрагмент фильма")
                }
                seen.append(range)
            }
        }
        let duration = LongformTimeline(arc: arc, coldOpenEnabled: coldOpenEnabled).duration
        if !duration.isFinite || !EssayDurationPolicy.rendered.contains(duration) {
            issues.append("подтверждённый монтаж не укладывается в 4:00–8:00")
        }
        guard issues.isEmpty else { throw InvalidSelection(issues: issues) }
    }

    private static func normalized(_ text: String) -> String {
        DirectorArtifactGate.dropApostrophes(text.lowercased())
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
