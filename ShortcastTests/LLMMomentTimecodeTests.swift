import Testing
import Foundation
@testable import Shortcast

/// Тесты, проверяющие, что Director LLM получает однозначные таймкоды
/// в абсолютных секундах и явные инструкции — исправление от деградации
/// (10 моментов ~1 с каждый в первые 132 с фильма длительностью 9700 с).
@Suite("LLM Moment Timecode Tests")
struct LLMMomentTimecodeTests {

    // MARK: - Вспомогательные

    /// Проверяет, что строка начинается с таймкода в формате `[число.число] `
    private func hasAbsoluteSecondTimestamp(_ line: String) -> Bool {
        guard line.hasPrefix("[") else { return false }
        // Ищем закрывающую скобку с точкой внутри (формат `[1234.5]`)
        guard let closeBracket = line.firstIndex(of: "]") else { return false }
        let inside = String(line[line.index(after: line.startIndex)..<closeBracket])
        // Должно содержать точку (дробные секунды)
        guard inside.contains(".") else { return false }
        // Не должно содержать двоеточие (это был бы MM:SS)
        guard !inside.contains(":") else { return false }
        // Часть до пробела после `]` — таймкод
        let afterBracket = line[line.index(after: closeBracket)...]
        return afterBracket.hasPrefix(" ")
    }

    // MARK: - Test 1: downsampleChronologically сохраняет формат таймкодов

    @Test("downsampleChronologically сохраняет таймкоды в формате абсолютных секунд")
    func downsamplePreservesTimestampFormat() {
        // Транскрипт в формате `[секунды.десятые] текст` — после downsampling
        // каждая выжившая строка должна сохранить свою оригинальную метку времени.
        let lines = (0..<200).map { i in
            let seconds = Double(i) * 50.0 // 0, 50, 100, ... 9950
            return String(format: "[%.1f] Реплика номер %d", seconds, i)
        }
        let sample = lines.joined(separator: "\n")

        // Бюджет достаточно мал, чтобы сжать, но не до двух строк
        let (result, stride) = MomentFinderService.downsampleChronologically(sample, to: 500)

        let resultLines = result.split(separator: "\n").map(String.init)
        #expect(resultLines.count >= 2)

        // Каждая строка должна содержать таймкод в формате абсолютных секунд
        for line in resultLines {
            #expect(hasAbsoluteSecondTimestamp(line),
                     "Строка не содержит таймкод в формате абсолютных секунд: \(line)")
        }

        // Первая и последняя строки оригинала всегда выживают
        #expect(resultLines.first == lines.first)
        #expect(resultLines.last == lines.last)

        // Stride > 1 означает, что сжатие произошло
        #expect(stride > 1)
    }

    @Test("downsampleChronologically не изменяет значения таймкодов")
    func downsampleDoesNotAlterTimestamps() {
        let sample = """
        [0.0] Начало фильма
        [754.5] Середина фильма
        [3300.0] Кульминация
        [9700.0] Финал
        """
        let (result, _) = MomentFinderService.downsampleChronologically(sample, to: 10_000)

        // При достаточном бюджете все строки выживают без изменений
        #expect(result == sample)
    }

    // MARK: - Test 2: Промпт содержит разъяснение формата таймкодов

    @Test("системный промпт объясняет, что таймкоды — секунды от начала фильма")
    func systemPromptClarifiesTimecodeFormat() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Тестовый фильм")

        // Системный промпт должен явно указывать, что таймкоды — секунды
        #expect(prompt.contains("секунди") || prompt.contains("СЕКУНДИ"),
                "Системный промпт не упоминает секунды")

        // Должно быть указание равномерно распределять моменты
        #expect(prompt.contains("РІВНОМІРНО") || prompt.contains("всьому фільму"),
                "Системный промпт не указывает равномерное распределение моментов")
    }

    @Test("stratifiedThematicSample выдаёт абсолютные секунды, а не MM:SS")
    func stratifiedSampleUsesAbsoluteSeconds() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 5.0, text: "Перша сцена."),
            TranscriptSegment(start: 754.5, end: 760.0, text: "Середина фільму."),
            TranscriptSegment(start: 9700.0, end: 9705.0, text: "Фінал."),
        ], language: "uk")

        let sample = LongformThematicService.stratifiedThematicSample(from: transcript)

        // Должен содержать `[754.5]`, а не `[12:34]`
        #expect(sample.contains("[754.5]"), "Ожидается [754.5] в: \(sample)")
        // Должен содержать `[9700.0]`, а не `[161:40]`
        #expect(sample.contains("[9700.0]"), "Ожидается [9700.0] в: \(sample)")
        // НЕ должен содержать MM:SS формат
        #expect(!sample.contains("[12:34]"), "Не должен содержать MM:SS формат")
        #expect(!sample.contains("[161:40]"), "Не должен содержать MM:SS формат")
    }

    @Test("таймкоды в абсолютных секундах покрывают весь диапазон длинного фильма")
    func timestampsCoverFullFilmRange() {
        // Моделируем транскрипт длинного фильма (~160 минут = 9600 секунд)
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0.0, end: 5.0, text: "Експозиція."),
            TranscriptSegment(start: 2400.0, end: 2405.0, text: "Перший акт."),
            TranscriptSegment(start: 4800.0, end: 4805.0, text: "Другий акт."),
            TranscriptSegment(start: 7200.0, end: 7205.0, text: "Третій акт."),
            TranscriptSegment(start: 9600.0, end: 9605.0, text: "Фінал."),
        ], language: "uk")

        let sample = LongformThematicService.stratifiedThematicSample(from: transcript)
        let lines = sample.split(separator: "\n").map(String.init)

        // Последняя строка должна содержать таймкод ~9600 секунд
        let lastLine = lines.last ?? ""
        #expect(lastLine.contains("[9600.0]"),
                "Последняя строка должна содержать [9600.0]: \(lastLine)")

        // Все строки должны иметь формат абсолютных секунд
        for line in lines {
            #expect(hasAbsoluteSecondTimestamp(line),
                     "Неверный формат таймкода: \(line)")
        }
    }
}
