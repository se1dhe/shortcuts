import Foundation

/// A short owns its edits; rebuilding it must not modify the essay or its sibling.
enum EssayShortEditing {
    static func canEdit(_ short: EssayShort, in release: EssayRelease) -> Bool {
        !release.receipts.contains { $0.key.hasPrefix(short.id + ".") && $0.value.state != .failed }
    }

    static func validate(_ short: EssayShort, arc: LongformNarrativeArc, sourceDuration: Double) throws {
        guard !short.title.trimmed.isEmpty, !short.hook.trimmed.isEmpty,
              !short.angle.trimmed.isEmpty, !short.question.trimmed.isEmpty else {
            throw EssayReleaseError.invalid("Заполните название, хук, мысль и вопрос шортса.")
        }
        guard !short.segments.isEmpty, sourceDuration.isFinite, sourceDuration > 0,
              short.segments.allSatisfy({ range in
                  range.start.isFinite && range.end.isFinite && range.start >= 0 &&
                  range.end <= sourceDuration && range.duration >= 3 &&
                  arc.acts.flatMap(\.segments).contains { $0.start <= range.start + 0.001 && $0.end >= range.end - 0.001 }
              }) else {
            throw EssayReleaseError.invalid("Каждая сцена должна длиться от 3 секунд и находиться внутри материала эссе и исходного фильма.")
        }
        guard (15...60).contains(short.duration) else {
            throw EssayReleaseError.invalid("Длительность шортса вместе с финальной карточкой должна быть от 15 до 60 секунд.")
        }
        for edit in short.captionEdits ?? [] {
            guard !edit.replacement.trimmed.isEmpty else {
                throw EssayReleaseError.invalid("Текст субтитра не может быть пустым.")
            }
        }
    }
}
