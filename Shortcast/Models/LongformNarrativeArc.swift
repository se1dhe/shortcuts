import Foundation

/// Тип акта в 4-актной драматургической структуре длинного ролика
enum LongformActType: String, Codable, CaseIterable, Sendable {
    case hook = "Хук и Тезис"
    case downfall = "Падение и Испытание"
    case struggle = "Борьба и Упорство"
    case catharsis = "Катарсис и Прорыв"

    var targetDurationRatio: Double {
        switch self {
        case .hook: return 0.12       // ~40-50s
        case .downfall: return 0.33   // ~120-140s
        case .struggle: return 0.35   // ~130-150s
        case .catharsis: return 0.20  // ~70-90s
        }
    }
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

/// 4-актная сквозная арка для длинного видео (хронометраж 420–600 сек / 7–10 мин)
struct LongformNarrativeArc: Codable, Identifiable, Equatable, Sendable {

    /// Честная бухгалтерия хронометража: что просили, сколько допускал материал фильма, сколько собрали.
    /// Пороги отбора под этот потолок не ослабляются — тонкий материал только документируется.
    struct DurationReport: Codable, Equatable, Sendable {
        /// Длительность исходного фильма, с
        let filmDuration: Double
        /// Запрошенный пайплайном хронометраж ролика, с
        let ask: Double
        /// Эффективный целевой хронометраж, выведенный из длины фильма, с
        let effectiveTarget: Double
        /// Арифметический потолок из пригодного материала при неизменных gates, но не больше
        /// бюджета акта: собранный хронометраж может его превысить на целый прогон, потому что
        /// крой никогда не режется посередине мысли.
        let admissibleCeiling: Double
        /// Фактически собранный хронометраж, с
        let achieved: Double
        /// Доля собранного от эффективной цели
        let fillRatio: Double
        /// Число связных запусков речи в каждом из четырёх актов
        let runsPerAct: [Int]
        /// Хронометраж каждого акта, с
        let perActDurations: [Double]
        /// true — ни один запуск акта IV не начинается в зарезервированном финале фильма
        let tailUnused: Bool
        /// true — пороги отбора не ослаблялись ради достижения цели
        let gatesUnchanged: Bool
    }

    var id: String
    var movieTitle: String
    var concept: ThematicConcept
    var acts: [LongformAct]
    var summary: String
    var mood: String

    /// Отчёт по хронометражу. Опционален: старые архивы арок декодируются без него.
    var durationReport: DurationReport? = nil

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
        mood: String = "dramatic",
        durationReport: DurationReport? = nil
    ) {
        self.id = id
        self.movieTitle = movieTitle
        self.concept = concept
        self.acts = acts
        self.summary = summary
        self.mood = mood
        self.durationReport = durationReport
    }
}
