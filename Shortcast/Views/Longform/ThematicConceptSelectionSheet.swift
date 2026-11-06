import SwiftUI

/// Экран выбора или ввода философского лейтмотива фильма в стиле канала @prrodan (SOLID)
struct ThematicConceptSelectionSheet: View {

    let initialMovieTitle: String
    let concepts: [ThematicConcept]
    let aiReasoning: String?
    let source: ThematicSource
    /// План эссе от Director: варианты хука и CTA.
    let initialEssayPlan: EssayPlan?
    /// Идёт ли сейчас настоящий анализ Director — состояние модели, а не таймера.
    let isRegenerating: Bool
    let planningError: String?
    let cancelTitle: String
    let onSelect: (ThematicConcept, String, LongformAudioSettings, EssayPlan) -> Void
    let onCancel: () -> Void
    let onRegenerate: ((EssayFormat) -> Void)?

    @State private var editedMovieTitle: String
    @State private var selectedConceptId: String? = nil
    @State private var essayFormat: EssayFormat = .analytical
    @State private var customWord: String = ""
    @State private var customTitle: String = ""
    @State private var showCustomInput: Bool = false

    // Хук выбирает модель после проверки темы и сцен.

    // Аудиомастеринг и звукорежиссура Shortcast Cinema (автоматически сохраняются в UserDefaults)
    @AppStorage("shortcast.longform.dialogueFocusEnabled") private var dialogueFocusEnabled: Bool = true
    @AppStorage("shortcast.longform.originalMusicDucking") private var originalMusicDucking: Double = 0.82
    @AppStorage("shortcast.longform.coldOpenEnabled") private var coldOpenEnabled: Bool = true
    @AppStorage("shortcast.longform.ambientMusicEnabled") private var ambientMusicEnabled: Bool = true
    @AppStorage("shortcast.longform.duckingEnabled") private var duckingEnabled: Bool = true
    @AppStorage("shortcast.longform.selectedMusicPath") private var selectedMusicPath = ""
    @State private var musicLibrary = MusicFolderLibrary.shared
    @AppStorage("shortcast.longform.ambientVolume") private var ambientVolume: Double = 0.18
    @State private var previewController = AudioPreviewController()

    // Optional effects; existing user preferences remain stored in UserDefaults.
    @AppStorage("shortcast.longform.antiCopyrightEnabled") private var antiCopyrightEnabled: Bool = false
    @AppStorage("shortcast.longform.antiCopyrightPreset") private var antiCopyrightPreset: AntiCopyrightPreset = .cinemaShield

    init(
        movieTitle: String,
        concepts: [ThematicConcept],
        aiReasoning: String? = nil,
        source: ThematicSource = .unknown,
        isRegenerating: Bool = false,
        essayPlan: EssayPlan? = nil,
        planningError: String? = nil,
        cancelTitle: String = L10n.tr("Отмена"),
        onSelect: @escaping (ThematicConcept, String, LongformAudioSettings, EssayPlan) -> Void,
        onCancel: @escaping () -> Void,
        onRegenerate: ((EssayFormat) -> Void)? = nil
    ) {
        self.initialMovieTitle = movieTitle
        self._editedMovieTitle = State(initialValue: movieTitle)
        let primary = concepts.first(where: { $0.isPrimaryChoice }) ?? concepts.first
        let usable = primary?.hasUsableIdentity == false ? [] : concepts.filter(\.hasUsableIdentity)
        self.concepts = usable
        self._essayFormat = State(initialValue: concepts.first?.format ?? .analytical)
        self.aiReasoning = aiReasoning
        self.source = source
        self.initialEssayPlan = essayPlan
        self.planningError = planningError
        self.cancelTitle = cancelTitle
        self.isRegenerating = isRegenerating
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onRegenerate = onRegenerate

        let primaryId = usable.first(where: { $0.isPrimaryChoice })?.id ?? usable.first?.id
        self._selectedConceptId = State(initialValue: primaryId)


    }

    /// Шапка отвечает на вопрос «кто автор той темы, что уйдёт в эссе», а не
    /// «откуда взялся разбор»: выбрали карточку или вписали своё слово — бейдж
    /// обязан показывать этого автора, иначе «ВЫБОР ИИ» стоит над нашей кнопкой.
    private var effectiveProvenance: ThematicSource {
        conceptForConfirmation?.source ?? source
    }

    private var provenance: (header: String, badge: String, badgeIcon: String, reasoning: String, reasoningIcon: String, warning: String?) {
        switch effectiveProvenance {
        case .llm:
            return (
                L10n.tr("Нейросеть проанализировала диалоги и выбрала фундаментальную тему для кино-эссе:"),
                L10n.tr("ВЫБОР ИИ • ГЛАВНАЯ ТЕМА ЭССЕ"),
                "sparkles",
                L10n.tr("Почему модель выбрала именно эту тему:"),
                "brain.head.profile",
                nil
            )
        case .manual:
            return (
                L10n.tr("Тему выбрали вы, а не модель — это фиксированный лейтмотив для кино-эссе:"),
                L10n.tr("ВЫБРАНО ВАМИ • ГЛАВНАЯ ТЕМА ЭССЕ"),
                "hand.tap.fill",
                L10n.tr("Почему вы выбрали эту тему:"),
                "hand.tap.fill",
                nil
            )
        case .unknown:
            let base = L10n.tr("Провенанс темы не записан: она могла прийти из проекта, сохранённого до учёта источников, поэтому мы не утверждаем, что её выбрала модель.")
            return (
                L10n.tr("Источник этой темы не записан, поэтому сказать, кто её выбрал, невозможно. Ниже тема, на которой стоит собрать кино-эссе:"),
                L10n.tr("ИСТОЧНИК НЕ ЗАПИСАН • ГЛАВНАЯ ТЕМА ЭССЕ"),
                "questionmark.circle",
                L10n.tr("Обоснование темы (кто её выбрал — не записано):"),
                "questionmark.circle",
                onRegenerate == nil
                    ? base
                    : L10n.tr("%1$@ Нажмите «Пересчитать темы с AI», чтобы тему действительно выбрала нейросеть.", String(describing: base))
            )
        }
    }

    private var primaryConcept: ThematicConcept? {
        concepts.first(where: { $0.isPrimaryChoice }) ?? concepts.first
    }

    /// Что сказать, когда тем ещё нет: экран не выдумывает лейтмотив за модель.
    private var emptyConceptsNote: String {
        if isRegenerating {
            return L10n.tr("Director ещё анализирует сценарий — тем пока нет.")
        }
        if onRegenerate != nil {
            return L10n.tr("Тем от нейросети пока нет: нажмите «Пересчитать темы с AI», чтобы тему выбрала модель.")
        }
        return L10n.tr("Тем от нейросети пока нет — экран не выдумывает тему за модель.")
    }

    private var alternativeConcepts: [ThematicConcept] {
        guard let p = primaryConcept else { return [] }
        return concepts.filter { $0.id != p.id }
    }

    var activeSelection: ThematicConcept? {
        if showCustomInput && !customWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let word = customWord.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ручная тема получает только слова пользователя. Слоган, тезис и
            // заголовок от себя экран не дописывает: пустая строка здесь значит
            // «текста нет», а не «мы сейчас что-нибудь подставим». Пустой
            // `suggestedTitle` честно собирается в `buildPrrodanTitle` из слова и
            // названия фильма, а пустые `tagline`/`philosophicalPremise`
            // потребитель обязан показать пустыми, а не выдуманными.
            return ThematicConcept(
                word: word,
                tagline: "",
                philosophicalPremise: "",
                suggestedTitle: customTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                accentColorHex: "#F5D020",
                source: .manual
            )
        }
        return concepts.first(where: { $0.id == selectedConceptId }) ?? primaryConcept ?? concepts.first
    }

    private var applicableEssayPlan: EssayPlan? {
        guard !showCustomInput, !userPickedAlternativeCard else { return nil }
        return initialEssayPlan
    }

    private var userPickedAlternativeCard: Bool {
        guard let selectedConceptId, let primaryId = primaryConcept?.id else { return false }
        guard concepts.contains(where: { $0.id == selectedConceptId }) else { return false }
        return selectedConceptId != primaryId
    }

    /// Тема, которая уходит в onSelect. Осознанный выбор пользователя надёжнее
    /// незаписанного источника, но не перезаписывает доказанную генерацию модели.
    private var conceptForConfirmation: ThematicConcept? {
        guard var concept = activeSelection else { return nil }
        if userPickedAlternativeCard, concept.source != .llm {
            concept.source = .manual
        }
        return concept
    }

    private var resolvedMusicURL: URL? {
        guard ambientMusicEnabled,
              let track = musicLibrary.tracks.first(where: { $0.url.path == selectedMusicPath }),
              FileManager.default.isReadableFile(atPath: track.url.path) else { return nil }
        return track.url
    }

    private func reconcileMusicSelection() {
        if !musicLibrary.tracks.contains(where: { $0.url.path == selectedMusicPath }) {
            selectedMusicPath = ""
            previewController.stop()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Заголовок и блок названия фильма
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "film.fill")
                        .font(.title2)
                        .foregroundStyle(StudioTheme.accent)
                    Text(L10n.tr("Центральная тема кино-эссе (Shortcast Cinema)"))
                        .font(.title2.weight(.bold))

                    if let onRegenerate {
                        Button {
                            onRegenerate(essayFormat)
                        } label: {
                            HStack(spacing: 5) {
                                if isRegenerating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isRegenerating ? L10n.tr("Анализ сценария...") : L10n.tr("Пересчитать темы с AI"))
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(StudioTheme.accent)
                        .disabled(isRegenerating)
                        .help(L10n.tr("Повторно запустить глубокий анализ сценария через нейросеть Director"))
                    }
                }

                // Поле подтверждения / редактирования названия фильма
                HStack(spacing: 12) {
                    Label(L10n.tr("Фильм:"), systemImage: "sparkles.tv")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    TextField(L10n.tr("Название фильма (например, Револьвер)"), text: $editedMovieTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .frame(maxWidth: 540)

                Text(provenance.header)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)

                if let warning = provenance.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 620)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let planningError {
                Label(planningError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
            // Сетка карточек концептов
                VStack(spacing: 14) {
                    if concepts.isEmpty {
                        // Темы нет — и придумывать её за модель мы не будем.
                        Label(
                            emptyConceptsNote,
                            systemImage: isRegenerating ? "hourglass" : "questionmark.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                    }

                    // HERO CARD: главная тема эссе (100% фокус ролика, бейдж зависит от provenance)
                    if let primary = primaryConcept {
                        let isSelected = (selectedConceptId == primary.id || selectedConceptId == nil) && !showCustomInput
                        let isGenerated = LongformHistoryService.shared.isConceptGenerated(movieTitle: editedMovieTitle, conceptWord: primary.word)
                        let reasoningText = primary.aiReasoning ?? aiReasoning

                        Button {
                            showCustomInput = false
                            selectedConceptId = primary.id
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                // Верхний бейдж Hero-карточки
                                HStack(spacing: 8) {
                                    HStack(spacing: 5) {
                                        Image(systemName: provenance.badgeIcon)
                                            .font(.caption2)
                                        Text(provenance.badge)
                                            .font(.system(size: 10, weight: .black, design: .rounded))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(StudioTheme.accent.opacity(0.20))
                                    .foregroundStyle(StudioTheme.accent)
                                    .clipShape(Capsule())

                                    if isGenerated {
                                        Text(L10n.tr("УЖЕ СМОНТИРОВАНО ✓"))
                                            .font(.system(size: 9, weight: .black))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundStyle(.green)
                                            .clipShape(Capsule())
                                    }

                                    Spacer()

                                    Text(L10n.tr("РЕКОМЕНДОВАНО ДЛЯ YOUTUBE"))
                                        .font(.system(size: 10, weight: .heavy))
                                        .foregroundStyle(StudioTheme.accent.opacity(0.85))
                                }

                                // Основная строка концепта
                                HStack(alignment: .center, spacing: 18) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(primary.word.uppercased())
                                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                                            .foregroundStyle(isSelected ? .white : .primary)

                                        Text(primary.suggestedTitle)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(StudioTheme.accent)
                                    }
                                    .frame(width: 290, alignment: .leading)

                                    Divider()
                                        .frame(height: 48)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(primary.tagline)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.primary)

                                        // Пустой тезис не рисуем: пустая строка под
                                        // слоганом читается как баг вёрстки, а не как
                                        // «модель его не написала».
                                        if !primary.philosophicalPremise.isEmpty {
                                            Text(primary.philosophicalPremise)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title)
                                        .foregroundStyle(isSelected ? StudioTheme.accent : .secondary.opacity(0.4))
                                }

                                // Драматургический разбор выбранной темы
                                if let reasoning = reasoningText, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: provenance.reasoningIcon)
                                            .font(.subheadline)
                                            .foregroundStyle(StudioTheme.accent)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(provenance.reasoning)
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(StudioTheme.accent)
                                            Text(reasoning)
                                                .font(.caption)
                                                .foregroundStyle(.primary.opacity(0.95))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.black.opacity(0.35))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(StudioTheme.accent.opacity(0.35), lineWidth: 1)
                                    )
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isSelected ? StudioTheme.accent.opacity(0.14) : StudioTheme.raised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(isSelected ? StudioTheme.accent : StudioTheme.accent.opacity(0.4), lineWidth: isSelected ? 2.5 : 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Секция альтернативных тем
                    if !alternativeConcepts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.tr("Альтернативные грани и темы фильма:"))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.top, 4)

                            ForEach(alternativeConcepts) { concept in
                                let isSelected = (selectedConceptId == concept.id) && !showCustomInput
                                let isGenerated = LongformHistoryService.shared.isConceptGenerated(movieTitle: editedMovieTitle, conceptWord: concept.word)

                                Button {
                                    showCustomInput = false
                                    selectedConceptId = concept.id
                                } label: {
                                    HStack(alignment: .center, spacing: 18) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 8) {
                                                Text(concept.word.uppercased())
                                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                                    .foregroundStyle(isSelected ? .white : .primary)

                                                if isGenerated {
                                                    Text(L10n.tr("СМОНТИРОВАНО ✓"))
                                                        .font(.system(size: 9, weight: .black))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.green.opacity(0.2))
                                                        .foregroundStyle(.green)
                                                        .clipShape(Capsule())
                                                }
                                            }

                                            Text(concept.suggestedTitle)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(StudioTheme.accent)
                                        }
                                        .frame(width: 290, alignment: .leading)

                                        Divider()
                                            .frame(height: 40)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(concept.tagline)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)

                                            if !concept.philosophicalPremise.isEmpty {
                                                Text(concept.philosophicalPremise)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }

                                        Spacer()

                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundStyle(isSelected ? StudioTheme.accent : .secondary.opacity(0.4))
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(isSelected ? StudioTheme.accent.opacity(0.12) : StudioTheme.raised)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(isSelected ? StudioTheme.accent : StudioTheme.line, lineWidth: isSelected ? 2 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Кастомный ввод
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            showCustomInput.toggle()
                        } label: {
                            HStack {
                                Image(systemName: showCustomInput ? "chevron.down" : "plus.circle.fill")
                                    .foregroundStyle(StudioTheme.accent)
                                Text(L10n.tr("Ввести своё философское слово/тему вручную"))
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        if showCustomInput {
                            VStack(spacing: 10) {
                                TextField(L10n.tr("Главное слово (например: Честь, Гордость, Гнев)"), text: $customWord)
                                    .textFieldStyle(.roundedBorder)

                                TextField(L10n.tr("Заголовок YouTube для этого эссе"), text: $customTitle)
                                    .textFieldStyle(.roundedBorder)

                                // Честно говорим, чего у ручной темы нет и почему.
                                Text(L10n.tr("Слогана и философского тезиса у этой темы не будет: их пишет только модель, а экран за модель ничего не сочиняет. Заголовок возьмём из вашего поля; если оно пустое, публикация получит название из слова темы и имени фильма. Тема помечена как выбранная вами, а не моделью."))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 6)

            // Один явный выбор модели, а не меню и не нулевой пункт массива.
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.tr("Хук, выбранный моделью"), systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                if let hook = applicableEssayPlan?.selectedHook, hook.source == .llm {
                    Text(hook.text).font(.body).textSelection(.enabled)
                    if let reason = applicableEssayPlan?.hookReason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.tr("Модель определит один подходящий хук при анализе выбранной темы."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))

            // Хронометраж эссе не выбирается: он растёт из выбранной темы
            Text(L10n.tr("Хронометраж не выбирается: он рождается из темы — от 4 минут, без верхнего ограничения."))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            // Блок аудиомастеринга и звукорежиссуры Shortcast Cinema
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.headline)
                            .foregroundStyle(StudioTheme.accent)
                        Text(L10n.tr("Звукорежиссура и аудиомастеринг"))
                            .font(.headline)
                    }

                    Spacer()

                    // Чекбокс кинематографического Cold Open
                    Toggle(isOn: $coldOpenEnabled) {
                        HStack(spacing: 4) {
                            Image(systemName: "film.stack")
                            Text(L10n.tr("Cold Open (2.5с интро)"))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    .help(L10n.tr("Плавное кинематографическое вступление в затемнении перед первым кадром фильма"))
                }

                // 1. Секция диалогов фильма: Dialogue Focus (Center Channel Extraction)
                HStack(spacing: 14) {
                    Toggle(isOn: $dialogueFocusEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(L10n.tr("Фокус на диалогах (Dialogue Focus)"))
                                    .font(.subheadline.weight(.semibold))
                                Text(L10n.tr("5.1 / СТЕРЕО"))
                                    .font(.system(size: 9, weight: .black))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(StudioTheme.accent.opacity(0.2))
                                    .foregroundStyle(StudioTheme.accent)
                                    .clipShape(Capsule())
                            }
                            Text(L10n.tr("Приглушать оригинальную музыку фильма, сохраняя чёткие голоса актеров дубляжа"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Spacer()

                    if dialogueFocusEnabled {
                        HStack(spacing: 8) {
                            Text(L10n.tr("Подавление музыки:"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $originalMusicDucking, in: 0.40...1.00, step: 0.05)
                                .frame(width: 85)
                            Text("-\(Int(round(originalMusicDucking * 100)))%")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(StudioTheme.accent)
                                .frame(width: 50, alignment: .trailing)
                        }
                        .help(L10n.tr("Уровень приглушения фоновой музыки и шумов оригинального фильма (по умолчанию -82%)"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))

                // 2. Секция фоновой музыки: Cinematic Dark Ambient
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(L10n.tr("Фоновая музыка"), isOn: $ambientMusicEnabled)
                            .font(.subheadline.weight(.semibold))
                            .toggleStyle(.switch)

                        Spacer()

                        if ambientMusicEnabled {
                            Toggle(L10n.tr("Приглушать под речью (Sidechain Ducking)"), isOn: $duckingEnabled)
                                .font(.caption.weight(.medium))
                                .toggleStyle(.checkbox)
                                .help(L10n.tr("Автоматически снижать громкость саундтрека во время реплик персонажей"))
                        }
                    }

                    if ambientMusicEnabled {
                        if let directory = musicLibrary.directory {
                            Text(L10n.tr("%1$@ · треков: %2$@", String(describing: directory.path), String(describing: musicLibrary.tracks.count)))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if let error = musicLibrary.error {
                            Text(L10n.tr(error)).font(.caption).foregroundStyle(StudioTheme.warning)
                        }
                        HStack(spacing: 12) {
                            Picker(L10n.tr("Саундтрек:"), selection: Binding(
                                get: { selectedMusicPath },
                                set: { path in
                                    selectedMusicPath = FileManager.default.isReadableFile(atPath: path) ? path : ""
                                })) {
                                Text(L10n.tr("Без трека")).tag("")
                                ForEach(musicLibrary.tracks) { track in
                                    Text(track.name).tag(track.url.path)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320)

                            Button(L10n.tr("Папка с музыкой…"), systemImage: "folder") {
                                musicLibrary.chooseFolder()
                                reconcileMusicSelection()
                            }
                            .buttonStyle(.bordered)
                            .help(musicLibrary.directory?.path ?? L10n.tr("Подключить папку с музыкой"))

                            // Кнопка предпрослушивания саундтрека
                            Button {
                                previewController.toggle(url: resolvedMusicURL, volume: Float(ambientVolume))
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: previewController.isPlaying ? "pause.fill" : "play.fill")
                                    Text(previewController.isPlaying ? L10n.tr("Пауза") : L10n.tr("Слушать"))
                                }
                                .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(previewController.isPlaying ? StudioTheme.accent : .secondary)
                            .disabled(resolvedMusicURL == nil)

                            Spacer()

                            // Регулятор громкости саундтрека
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.1.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $ambientVolume, in: 0.01...0.60)
                                    .frame(width: 80)
                                Text("\(Int(round(ambientVolume * 100)))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))

                // 3. Optional image and audio effects
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L10n.tr("Обработка изображения и звука"), isOn: $antiCopyrightEnabled)
                            .font(.subheadline.weight(.semibold))
                            .toggleStyle(.switch)

                        Spacer()

                        if antiCopyrightEnabled {
                            Picker(L10n.tr("Пресет:"), selection: $antiCopyrightPreset) {
                                ForEach(AntiCopyrightPreset.allCases) { preset in
                                    Text(L10n.tr(preset.displayName)).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 340)
                        }
                    }

                    if antiCopyrightEnabled {
                        Text(L10n.tr("Микро-зум, кинозерно и обработка звука. Эти эффекты не гарантируют отсутствие Content ID, претензий или ограничений монетизации."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))

                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }

            Divider()

            // Кнопки управления
            HStack(spacing: 16) {
                Button(cancelTitle, role: .cancel) {
                    previewController.stop()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    previewController.stop()
                    if var chosen = conceptForConfirmation {
                        chosen.essayFormat = essayFormat
                        let finalTitle = editedMovieTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? initialMovieTitle
                            : editedMovieTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let audioSettings = LongformAudioSettings(
                            backgroundMusicURL: ambientMusicEnabled ? resolvedMusicURL : nil,
                            musicVolume: Float(ambientVolume),
                            duckingEnabled: duckingEnabled,
                            dialogueFocusEnabled: dialogueFocusEnabled,
                            originalMusicDucking: Float(originalMusicDucking),
                            coldOpenEnabled: coldOpenEnabled,
                            antiCopyrightEnabled: antiCopyrightEnabled,
                            antiCopyrightPreset: antiCopyrightPreset
                        )
                        let plan = applicableEssayPlan ?? EssayPlan()
                        onSelect(chosen, finalTitle, audioSettings, plan)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                        Text(L10n.tr("Смонтировать кино-эссе"))
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(activeSelection == nil || isRegenerating)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 780, minHeight: 640)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .onChange(of: concepts) { previous, updated in
            if selectedConceptId == nil || !updated.contains(where: { $0.id == selectedConceptId }) {
                self.selectedConceptId = primaryConcept?.id
            }
            if previous.isEmpty || previous.first?.format != updated.first?.format,
               let format = updated.first?.format {
                essayFormat = format
            }
        }
        .task {
                musicLibrary.refresh()
                reconcileMusicSelection()
                await musicLibrary.monitor()
            }
        .onChange(of: musicLibrary.tracks) { _, _ in reconcileMusicSelection() }
        .onChange(of: selectedMusicPath) { _, _ in
            if previewController.isPlaying {
                if let url = resolvedMusicURL {
                    previewController.play(url: url, volume: Float(ambientVolume))
                } else {
                    previewController.stop()
                }
            }
        }
        .onChange(of: ambientVolume) { _, newVolume in
            previewController.updateVolume(Float(newVolume))
        }
        .onChange(of: ambientMusicEnabled) { _, isEnabled in
            if !isEnabled {
                previewController.stop()
            }
        }
        .onDisappear {
            previewController.stop()
        }
    }
}
