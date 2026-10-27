import Foundation

/// Тип акта длинного ролика: аналитическая 5-актная структура и legacy-типы эвристики
enum LongformActType: String, Codable, CaseIterable, Sendable {
    case hook = "Хук и Тезис"
    case downfall = "Падение и Испытание"
    case struggle = "Борьба и Упорство"
    case catharsis = "Катарсис и Прорыв"
    // Аналитическая структура LLM-пути. Объявлены после legacy, чтобы
    // allCases.prefix(4) оставался каноническим порядком старой 4-актной арки.
    case form = "Анализ формы"
    case psychology = "Психология героя"
    case philosophy = "Философский подтекст"

    static let canonicalAnalyticOrder: [LongformActType] = [
        .hook, .form, .psychology, .philosophy, .catharsis
    ]

    /// Название акта для зрителя и промпта: структура эссе из `essays_20_films.md`.
    /// `rawValue` остаётся русским только ради совместимости архивов.
    var displayName: String {
        switch self {
        case .hook: return "Хук і теза"
        case .form: return "Аналіз форми"
        case .psychology: return "Психологія героя"
        case .philosophy: return "Прихований філософський підтекст"
        case .catharsis: return "Катарсис і висновок"
        case .downfall: return "Падіння і випробування"
        case .struggle: return "Боротьба і завзятість"
        }
    }

    /// Ключ акта в JSON-протоколе Director
    var promptKey: String {
        switch self {
        case .hook: return "hook"
        case .downfall: return "downfall"
        case .struggle: return "struggle"
        case .catharsis: return "catharsis"
        case .form: return "form"
        case .psychology: return "psychology"
        case .philosophy: return "philosophy"
        }
    }

    init?(promptKey: String) {
        let clean = promptKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let type = LongformActType.allCases.first(where: { $0.promptKey == clean }) else { return nil }
        self = type
    }

    var targetDurationRatio: Double {
        switch self {
        case .hook: return 0.12
        case .downfall: return 0.33
        case .struggle: return 0.35
        case .catharsis: return 0.20
        case .form: return 0.24
        case .psychology: return 0.26
        case .philosophy: return 0.24
        }
    }

    /// Доли аналитической 5-актной арки: только для LLM-пути, legacy-бюджеты не затрагивает.
    var analyticDurationRatio: Double {
        switch self {
        case .hook: return 0.12
        case .form: return 0.24
        case .psychology: return 0.26
        case .philosophy: return 0.24
        case .catharsis: return 0.14
        case .downfall: return 0.33
        case .struggle: return 0.35
        }
    }
}

/// Откуда взялось название акта. Честная метка: «вывела модель» ставится только тогда,
/// когда модель реально ответила и прошла гейты, иначе — реальная реплика Whisper или шаблон.
enum ActTitleSource: String, Codable, Equatable, Sendable {
    /// Название вывел LLM-проход по диалогам самого акта (quotedLine прошёл гейт подстроки)
    case llm
    /// Детерминированный запасной путь: самая сильная реальная реплика Whisper внутри сегментов акта
    case transcriptLine
    /// Самый нижний ярус: у акта нет ни одной реплики (синтетическая арка) — взята формула темы
    case template
    /// Поле отсутствует в архиве: источник названия не зафиксирован и выдумывать его нельзя
    case unknown

    /// Только эти два яруса можно показывать как «название опирается на материал фильма»
    var isTrustworthy: Bool { self == .llm || self == .transcriptLine }

    var displayCaption: String {
        switch self {
        case .llm: return "вывела модель по диалогу"
        case .transcriptLine: return "по реплике акта"
        case .template: return "шаблон"
        case .unknown: return "источник не зафиксирован"
        }
    }
}

/// Провенанс названия акта: чем подтверждён, каким словом из транскрипта и какой моделью
struct ActTitleProvenance: Codable, Equatable, Sendable {
    var source: ActTitleSource
    /// Дословная реплика-основание (для `.llm` — quotedLine, для `.transcriptLine` — сама строка)
    var evidence: String?
    /// Идентификатор модели, если название выводила модель
    var modelID: String?
}

/// Отдельный акт длинного видео
struct LongformAct: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(type.rawValue)_\(title)" }
    var type: LongformActType
    var title: String
    var dramaticBeat: String
    var segments: [TimeSegment]

    /// Провенанс названия. Опционален: старые архивы арок декодируются без него,
    /// и отсутствие поля означает `.unknown`, а не «его выбрала модель».
    var titleProvenance: ActTitleProvenance? = nil

    /// Название акта в глазах UI: nil из архива — это `.unknown`, а не `.llm`
    var effectiveTitleSource: ActTitleSource { titleProvenance?.source ?? .unknown }

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

    /// Выбранный хук эссе: карточка 0–6 с и первая строка описания. nil — старый архив/план без хука.
    var hookText: String? = nil
    /// Заключительный призыв к действию: финальная карточка и закреплённый комментарий.
    var ctaText: String? = nil
    /// Главный тезис эссе из плана Director.
    var thesis: String? = nil

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
        durationReport: DurationReport? = nil,
        hookText: String? = nil,
        ctaText: String? = nil,
        thesis: String? = nil
    ) {
        self.id = id
        self.movieTitle = movieTitle
        self.concept = concept
        self.acts = acts
        self.summary = summary
        self.mood = mood
        self.durationReport = durationReport
        self.hookText = hookText
        self.ctaText = ctaText
        self.thesis = thesis
    }
}
