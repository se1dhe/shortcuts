import Foundation

/// Тип акта в 4-актной драматургической структуре длинного ролика
enum LongformActType: String, Codable, CaseIterable, Sendable {
    case hook = "Хук и Тезис"
    case downfall = "Падение и Испытание"
    case struggle = "Борьба и Упорство"
    case catharsis = "Катарсис и Прорыв"

    var targetDurationRatio: Double {
        switch self {
        case .hook: return 0.13       // ~70-90s
        case .downfall: return 0.33   // ~170-200s
        case .struggle: return 0.35   // ~180-210s
        case .catharsis: return 0.19  // ~90-120s
        }
    }
}

/// Драматургическое название и задача акта, сгенерированные LLM под конкретный
/// фильм и тему. Заменяет прежние захардкоженные bucket-ы `adaptiveActDescriptors`.
struct LongformActDescriptor: Codable, Sendable, Equatable, Hashable {
    var type: LongformActType
    var title: String
    var beat: String
}

/// Отдельный акт длинного видео
struct LongformAct: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(type.rawValue)_\(title)" }
    var type: LongformActType
    var title: String
    var dramaticBeat: String
    var segments: [TimeSegment]

    var duration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Время начала первого сегмента акта в исходном видео
    var startTime: Double {
        segments.first?.start ?? 0.0
    }
}

/// 4-актная сквозная арка для длинного видео (хронометраж 480–720 сек / 8–12 мин)
struct LongformNarrativeArc: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var movieTitle: String
    var concept: ThematicConcept
    var acts: [LongformAct]
    var summary: String
    var mood: String

    var segments: [TimeSegment] {
        acts.flatMap(\.segments)
    }

    var totalDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    init(
        id: String = UUID().uuidString,
        movieTitle: String,
        concept: ThematicConcept,
        acts: [LongformAct],
        summary: String,
        mood: String = "dramatic"
    ) {
        self.id = id
        self.movieTitle = movieTitle
        self.concept = concept
        self.acts = acts
        self.summary = summary
        self.mood = mood
    }
}
