import Foundation

/// Откуда взялась тема. Нужен потому, что pipeline умеет деградировать без
/// модели, а пользователь имеет право знать, кто написал то, что он смотрит.
/// `unknown` — темы, сохранённые до появления поля: им нельзя доверять,
/// они подлежат перегенерации.
enum ThematicSource: String, Codable, Sendable {
    case llm
    case manual
    case unknown

    var isTrustworthy: Bool { self == .llm || self == .manual }
}

/// Философский концепт / лейтмотив фильма для длинного видео (Shortcast Cinema Engine)
struct ThematicConcept: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String { word }
    
    /// Одно центральное слово крупными буквами: називний відмінок, іменник або
    /// інфінітив. Никакого списка допустимых слов: тему обязано найти модель.
    var word: String
    
    /// Короткий смысловой слоган, отражающий суть конфликта
    var tagline: String
    
    /// Философская предпосылка / тезис ролика
    var philosophicalPremise: String
    
    /// Заголовок для YouTube, который предложила модель
    var suggestedTitle: String
    
    /// Акцентный цвет субтитров реплик ("#F5D020" золотой или "#E50914" красный)
    var accentColorHex: String

    /// Флаг главного выбора нейросети (100% фокус эссе, выбранный моделью)
    var isPrimaryChoice: Bool

    /// Обоснование выбора от лица режиссера-ИИ на основе сценария
    var aiReasoning: String?

    /// Провенанс: действительно ли эту тему выдала модель
    var source: ThematicSource

    init(
        word: String,
        tagline: String,
        philosophicalPremise: String,
        suggestedTitle: String,
        accentColorHex: String = "#F5D020",
        isPrimaryChoice: Bool = false,
        aiReasoning: String? = nil,
        source: ThematicSource = .unknown
    ) {
        self.word = word
        self.tagline = tagline
        self.philosophicalPremise = philosophicalPremise
        self.suggestedTitle = suggestedTitle
        self.accentColorHex = accentColorHex
        self.isPrimaryChoice = isPrimaryChoice
        self.aiReasoning = aiReasoning
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case word, tagline, philosophicalPremise, suggestedTitle
        case accentColorHex, isPrimaryChoice, aiReasoning, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        tagline = try c.decode(String.self, forKey: .tagline)
        philosophicalPremise = try c.decode(String.self, forKey: .philosophicalPremise)
        suggestedTitle = try c.decode(String.self, forKey: .suggestedTitle)
        accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex) ?? "#F5D020"
        isPrimaryChoice = try c.decodeIfPresent(Bool.self, forKey: .isPrimaryChoice) ?? false
        aiReasoning = try c.decodeIfPresent(String.self, forKey: .aiReasoning)
        source = try c.decodeIfPresent(ThematicSource.self, forKey: .source) ?? .unknown
    }
}

/// Результат глубокого анализа сценария и драматургии фильма моделью Director (SOLID: Single Responsibility)
struct ThematicAnalysisResult: Codable, Sendable, Equatable {
    /// ОДНА главная тема, выбранная моделью как смысловое ядро фильма
    var primaryConcept: ThematicConcept

    /// Драматургический и психологический разбор сценария: почему модель выбрала именно эту тему
    var aiReasoning: String

    /// Конкретные моменты (сцены) для эссе, выбранные моделью
    var selectedMoments: [SelectedMoment]

    /// Альтернативные философские грани и темы, выявленные в диалогах
    var alternativeConcepts: [ThematicConcept]

    /// План эссе от Director: хук, CTA, тезис и фокус актов. nil — старый кэш анализа.
    var essayPlan: EssayPlan?

    /// Провенанс всего анализа. `.unknown` / не-`.llm` означает, что тему
    /// выбирала не модель, и такой анализ нельзя кэшировать как результат.
    var source: ThematicSource

    /// Насколько полон был ответ модели, из которого собран анализ. `.truncated`
    /// означает «гейт обязан отклонить»: раньше обрыв засчитывался успехом.
    var replyCompleteness: ReplyCompleteness

    /// Концепт, для которого действительно выполнялся Stage 2. Ответ модели может
    /// уточнить формулировку тезиса, поэтому исходный выбор сохраняется отдельно.
    var plannedConcept: ThematicConcept?

    /// Привязка к конкретным репликам и таймкодам источника. Старые архивы
    /// без неё читаются, но не выдаются за проверенный анализ текущего фильма.
    var sourceTranscriptFingerprint: String?
    var semanticProof: EssaySemanticProof? = nil

    /// Все концепты в едином списке, где главный выбор всегда идет первым
    var allConcepts: [ThematicConcept] {
        var list = [primaryConcept]
        for alt in alternativeConcepts where alt.word.caseInsensitiveCompare(primaryConcept.word) != .orderedSame {
            list.append(alt)
        }
        return list
    }

    init(
        primaryConcept: ThematicConcept,
        aiReasoning: String,
        selectedMoments: [SelectedMoment] = [],
        alternativeConcepts: [ThematicConcept] = [],
        essayPlan: EssayPlan? = nil,
        source: ThematicSource = .unknown,
        replyCompleteness: ReplyCompleteness = .complete,
        plannedConcept: ThematicConcept? = nil,
        sourceTranscriptFingerprint: String? = nil
    ) {
        var primary = primaryConcept
        primary.isPrimaryChoice = true
        if primary.aiReasoning == nil {
            primary.aiReasoning = aiReasoning
        }
        if primary.source == .unknown {
            primary.source = source
        }
        self.primaryConcept = primary
        self.aiReasoning = aiReasoning
        self.selectedMoments = selectedMoments
        self.alternativeConcepts = alternativeConcepts
        self.essayPlan = essayPlan
        self.source = source
        self.replyCompleteness = replyCompleteness
        self.plannedConcept = plannedConcept
        self.sourceTranscriptFingerprint = sourceTranscriptFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case primaryConcept, aiReasoning, selectedMoments, alternativeConcepts, essayPlan, source
        case replyCompleteness, plannedConcept, sourceTranscriptFingerprint, semanticProof
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryConcept = try c.decode(ThematicConcept.self, forKey: .primaryConcept)
        aiReasoning = try c.decode(String.self, forKey: .aiReasoning)
        selectedMoments = try c.decodeIfPresent([SelectedMoment].self, forKey: .selectedMoments) ?? []
        alternativeConcepts = try c.decodeIfPresent([ThematicConcept].self, forKey: .alternativeConcepts) ?? []
        essayPlan = try c.decodeIfPresent(EssayPlan.self, forKey: .essayPlan)
        source = try c.decodeIfPresent(ThematicSource.self, forKey: .source) ?? .unknown
        // Старые проэкты не имели этого поля: считать их обрезанными задним числом
        // значило бы сломать уже подтверждённые эссе, а не честность нового прогона.
        replyCompleteness = try c.decodeIfPresent(ReplyCompleteness.self, forKey: .replyCompleteness) ?? .complete
        plannedConcept = try c.decodeIfPresent(ThematicConcept.self, forKey: .plannedConcept)
        sourceTranscriptFingerprint = try c.decodeIfPresent(String.self, forKey: .sourceTranscriptFingerprint)
        semanticProof = try c.decodeIfPresent(EssaySemanticProof.self, forKey: .semanticProof)
    }
}

/// Конкретный момент (сцена) для эссе, выбранный LLM на основе анализа транскрипта
struct SelectedMoment: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(startTime)-\(endTime)" }
    
    /// Начало сцены в секундах от начала фильма
    let startTime: Double
    
    /// Конец сцены в секундах от начала фильма
    let endTime: Double
    
    /// Объяснение, почему эта сцена важна для раскрытия темы
    let reason: String
    
    /// Драматургический вес сцены (0.0-1.0)
    let dramaticWeight: Double

    /// Роль сцены в аналитической 5-актной арке, если её назначила модель
    let actRole: LongformActType?

    /// Тезис акта, который доказывает эта сцена
    let supports: String?

    /// Сильнейшая сцена акта: не режется бюджетом, пока есть другие кандидаты
    let featured: Bool?

    /// Якорь структуры эссе (строка, которая оплачивает обещание хука). Модель его
    /// не предлагала и не оценивала — его поставил монтаж по реплике транскрипта,
    /// поэтому бюджет не имеет права вырезать его целиком: это обещание зрителю.
    let structuralAnchor: Bool?

    /// Дословная реплика-основание из указанного диапазона, а не пересказ reason.
    /// nil у старых архивов: перед новым монтажом такой анализ перепроверяется.
    let evidenceQuote: String?
    
    /// Семантическая уверенность в корректности таймкода (после валидации)
    /// nil — не валидировался, high/medium/low — результат SemanticTimecodeValidator
    var semanticConfidence: SemanticConfidence? = nil
    
    enum SemanticConfidence: String, Codable, Sendable {
        case high, medium, low
    }
    
    init(
        startTime: Double,
        endTime: Double,
        reason: String,
        dramaticWeight: Double,
        actRole: LongformActType? = nil,
        supports: String? = nil,
        featured: Bool? = nil,
        structuralAnchor: Bool? = nil,
        evidenceQuote: String? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
        self.dramaticWeight = dramaticWeight
        self.actRole = actRole
        self.supports = supports
        self.featured = featured
        self.structuralAnchor = structuralAnchor
        self.evidenceQuote = evidenceQuote
    }
}

/// План эссе, который Director предлагает вместе с темой: тезис, выбранный хук и CTA,
/// фокус каждого аналитического акта и выбранный хронометраж.
struct EssayPlan: Codable, Equatable, Sendable {

    struct TextVariant: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: String { text }
        var text: String
        var source: ThematicSource

        /// Провенанс не выдумывается: вариант считается написанным моделью
        /// только когда его записал парсер из сырого ответа.
        init(text: String, source: ThematicSource = .unknown) {
            self.text = text
            self.source = source
        }

        private enum CodingKeys: String, CodingKey { case text, source }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            source = try c.decodeIfPresent(ThematicSource.self, forKey: .source) ?? .unknown
        }
    }

    var thesis: String?
    var hookVariants: [TextVariant]
    var selectedHook: TextVariant?
    var hookReason: String? = nil
    var ctaVariants: [TextVariant]
    var selectedCTA: TextVariant?
    /// Legacy: до 2026-10-28 хронометраж запрашивался у пользователя. Теперь его
    /// не выбирают: длина рождается из пула сцен внутри коридора 4:00–8:00. Поле
    /// остаётся только чтобы честно прочесть старый проект и отклэмпить его.
    var targetDuration: Double?
    /// promptKey акта -> что именно доказывает акт в этом фильме
    var actFocus: [String: String]

    init(
        thesis: String? = nil,
        hookVariants: [TextVariant] = [],
        selectedHook: TextVariant? = nil,
        ctaVariants: [TextVariant] = [],
        selectedCTA: TextVariant? = nil,
        targetDuration: Double? = nil,
        actFocus: [String: String] = [:]
    ) {
        self.thesis = thesis
        self.hookVariants = hookVariants
        self.selectedHook = selectedHook
        self.ctaVariants = ctaVariants
        self.selectedCTA = selectedCTA
        self.targetDuration = targetDuration
        self.actFocus = actFocus
    }

    private enum CodingKeys: String, CodingKey {
        case thesis, hookVariants, selectedHook, hookReason, ctaVariants, selectedCTA, targetDuration, actFocus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thesis = try c.decodeIfPresent(String.self, forKey: .thesis)
        hookVariants = try c.decodeIfPresent([TextVariant].self, forKey: .hookVariants) ?? []
        selectedHook = try c.decodeIfPresent(TextVariant.self, forKey: .selectedHook)
        hookReason = try c.decodeIfPresent(String.self, forKey: .hookReason)
        ctaVariants = try c.decodeIfPresent([TextVariant].self, forKey: .ctaVariants) ?? []
        selectedCTA = try c.decodeIfPresent(TextVariant.self, forKey: .selectedCTA)
        targetDuration = try c.decodeIfPresent(Double.self, forKey: .targetDuration)
        actFocus = try c.decodeIfPresent([String: String].self, forKey: .actFocus) ?? [:]
    }

    /// Вариант хука, который пойдёт на экран, вместе с его авторством.
    /// Молчаливый `hookVariants.first` больше не притворяется выбором модели:
    /// если провенанс не записан, показать именно этот вариант решает человек,
    /// и вызывающая сторона обязана это передать в гейт.
    var chosenHookVariant: TextVariant? {
        if let selected = selectedHook, Self.nonEmpty(selected.text) != nil { return selected }
        return nil
    }

    var chosenCTAVariant: TextVariant? {
        if let selected = selectedCTA, Self.nonEmpty(selected.text) != nil { return selected }
        return ctaVariants.first { Self.nonEmpty($0.text) != nil }
    }

    /// Старый запрошенный хронометраж — просьба, а не факт: он укладывается в
    /// коридор политики длительности и не больше.
    var effectiveTargetDuration: Double {
        EssayDurationPolicy.clamp(targetDuration ?? EssayDurationPolicy.defaultRenderedTarget)
    }

    func focus(for type: LongformActType) -> String? {
        Self.nonEmpty(actFocus[type.promptKey])
    }

    /// Фиксирует выбор пользователя: свой хук становится ручным вариантом плана.
    /// Хронометраж не фиксируется вовсе — он вытекает из темы.
    func confirming(hookText: String?, ctaText: String?) -> EssayPlan {
        var copy = self
        if let hookText = Self.nonEmpty(hookText) {
            if let index = copy.hookVariants.firstIndex(where: { $0.text == hookText }) {
                copy.selectedHook = copy.hookVariants[index]
            } else {
                let manual = TextVariant(text: hookText, source: .manual)
                copy.hookVariants.append(manual)
                copy.selectedHook = manual
            }
        }
        if let ctaText = Self.nonEmpty(ctaText) {
            if let index = copy.ctaVariants.firstIndex(where: { $0.text == ctaText }) {
                copy.selectedCTA = copy.ctaVariants[index]
            } else {
                let manual = TextVariant(text: ctaText, source: .manual)
                copy.ctaVariants.append(manual)
                copy.selectedCTA = manual
            }
        } else {
            copy.selectedCTA = copy.selectedCTA ?? copy.ctaVariants.first
        }
        copy.targetDuration = nil
        return copy
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
