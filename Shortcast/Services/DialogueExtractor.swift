import Foundation

/// Извлекает реплики из транскрипта для каждого выбранного момента.
/// Для каждого SelectedMoment находит все TranscriptSegment в диапазоне [startTime, endTime],
/// фильтрует по качеству и возвращает текст реплик.
struct DialogueExtractor {
    
    /// Извлекает реплики из транскрипта для заданного временного диапазона.
    /// - Parameters:
    ///   - transcript: Полный транскрипт фильма
    ///   - startTime: Начало диапазона (секунды)
    ///   - endTime: Конец диапазона (секунды)
    ///   - minSegmentDuration: Минимальная длительность сегмента (фильтр микро-фрагментов)
    /// - Returns: Массив строк с репликами
    static func extractDialogue(
        from transcript: Transcript,
        startTime: Double,
        endTime: Double,
        minSegmentDuration: Double = 0.35
    ) -> [String] {
        // Находим все сегменты транскрипта, попадающие в диапазон
        let overlappingSegments = transcript.segments.filter { segment in
            // Сегмент пересекается с диапазоном если:
            // - конец сегмента после начала диапазона
            // - начало сегмента до конца диапазона
            segment.end > startTime && segment.start < endTime
        }
        
        // Фильтруем микро-фрагменты и извлекаем текст
        let dialogue = overlappingSegments
            .filter { ($0.end - $0.start) >= minSegmentDuration }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        return dialogue
    }
    
    /// Извлекает реплики для всех клипов-кандидатов.
    /// - Parameters:
    ///   - clips: Массив клипов-кандидатов
    ///   - transcript: Полный транскрипт
    /// - Returns: Обновлённый массив клипов с заполненным полем dialogue
    static func extractDialogueForAll(
        clips: [ClipCandidate],
        transcript: Transcript
    ) -> [ClipCandidate] {
        return clips.map { clip in
            var updatedClip = clip
            updatedClip.dialogue = extractDialogue(
                from: transcript,
                startTime: clip.start,
                endTime: clip.end
            )
            return updatedClip
        }
    }
}
