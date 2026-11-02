import Foundation

/// A short owns its edits; rebuilding it must not modify the essay or its sibling.
enum EssayShortEditing {
    static let minimumSceneDuration: Double = 3
    static func canEdit(_ short: EssayShort, in release: EssayRelease) -> Bool {
        !release.receipts.contains { $0.key.hasPrefix(short.id + ".") && $0.value.state != .failed }
    }

    // Model selections are grounded in EssayShortDirector.parse. Manual edits may
    // use the entire source film; the model's initial window is not a trim limit.
    static func validate(_ short: EssayShort, arc: LongformNarrativeArc, sourceDuration: Double) throws {
        guard !short.title.trimmed.isEmpty, !short.hook.trimmed.isEmpty,
              !short.angle.trimmed.isEmpty, !short.question.trimmed.isEmpty else {
            throw EssayReleaseError.invalid("Заполните название, хук, мысль и вопрос шортса.")
        }
        let manualSegments = short.manuallyAddedSegments ?? []
        guard manualSegments.allSatisfy({ manual in
            short.segments.contains { abs($0.start - manual.start) < 0.01 && abs($0.end - manual.end) < 0.01 }
        }) else {
            throw EssayReleaseError.invalid("Ручная отметка сцены не совпадает с её границами. Выберите фрагмент повторно.")
        }
        guard !short.segments.isEmpty, sourceDuration.isFinite, sourceDuration > 0,
              short.segments.allSatisfy({ range in
                  range.start.isFinite && range.end.isFinite && range.start >= 0 &&
                  range.end <= sourceDuration && range.duration >= minimumSceneDuration
              }) else {
            throw EssayReleaseError.invalid("Каждая сцена должна длиться от 3 секунд и находиться в пределах исходного фильма.")
        }
        guard (15...60).contains(short.duration) else {
            throw EssayReleaseError.invalid("Длительность шортса должна быть от 15 до 60 секунд.")
        }
        for edit in short.captionEdits ?? [] {
            guard !edit.replacement.trimmed.isEmpty else {
                throw EssayReleaseError.invalid("Текст субтитра не может быть пустым.")
            }
        }
    }
}
