import SwiftUI

/// Экран выбора или ввода философского лейтмотива фильма в стиле канала @prrodan (SOLID)
struct ThematicConceptSelectionSheet: View {

    let initialMovieTitle: String
    let concepts: [ThematicConcept]
    let aiReasoning: String?
    let onSelect: (ThematicConcept, String, LongformAudioSettings) -> Void
    let onCancel: () -> Void
    let onRegenerate: (() -> Void)?

    @State private var editedMovieTitle: String
    @State private var selectedConceptId: String? = nil
    @State private var customWord: String = ""
    @State private var customTitle: String = ""
    @State private var showCustomInput: Bool = false
    @State private var isRegenerating: Bool = false

    // Аудиомастеринг и звукорежиссура Shortcast Cinema
    @State private var dialogueFocusEnabled: Bool = true
    @State private var originalMusicDucking: Double = 0.82
    @State private var coldOpenEnabled: Bool = true
    @State private var ambientMusicEnabled: Bool = true
    @State private var duckingEnabled: Bool = true
    @State private var selectedPresetIndex: Int = 0
    @State private var customAudioURL: URL? = nil
    @State private var ambientVolume: Double = 0.18
    @State private var previewController = AudioPreviewController()

    // Антикопирайт и защита от YouTube Content ID
    @State private var antiCopyrightEnabled: Bool = true
    @State private var antiCopyrightPreset: AntiCopyrightPreset = .cinemaShield

    private let musicPresets: [(name: String, fileName: String)] = [
        ("prrodan: Foggy Night (Главная тема)", "Prrodan_Foggy_Night.m4a"),
        ("prrodan: Тёмная атмосфера (Dark Atmosphere)", "Prrodan_Dark_Atmosphere.m4a"),
        ("prrodan: Внутренняя стойкость (Resilience)", "Prrodan_Cinematic_Resilience.m4a"),
        ("prrodan: Экзистенциальное эхо (Existential Echo)", "Prrodan_Existential_Echo.m4a"),
        ("prrodan: Опасный разум (Dangerous Mind)", "Prrodan_Dangerous_Mind.m4a"),
        ("prrodan: Несломленный дух (Unbroken Spirit)", "Prrodan_Unbroken_Spirit.m4a"),
        ("Тёмный кинематографичный монолог (Monologue)", "Sigma_Monologue_Dark.m4a"),
        ("Напряжение и саспенс (Suspense)", "Tension_Dark_Suspense.m4a"),
        ("Драматическая тема (Emotional)", "Dramatic_Emotional_Theme.m4a")
    ]

    init(
        movieTitle: String,
        concepts: [ThematicConcept],
        aiReasoning: String? = nil,
        onSelect: @escaping (ThematicConcept, String, LongformAudioSettings) -> Void,
        onCancel: @escaping () -> Void,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.initialMovieTitle = movieTitle
        self._editedMovieTitle = State(initialValue: movieTitle)
        self.concepts = concepts
        self.aiReasoning = aiReasoning
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onRegenerate = onRegenerate

        let primaryId = concepts.first(where: { $0.isPrimaryChoice })?.id ?? concepts.first?.id
        self._selectedConceptId = State(initialValue: primaryId)
    }

    private var primaryConcept: ThematicConcept? {
        concepts.first(where: { $0.isPrimaryChoice }) ?? concepts.first
    }

    private var alternativeConcepts: [ThematicConcept] {
        guard let p = primaryConcept else { return [] }
        return concepts.filter { $0.id != p.id }
    }

    var activeSelection: ThematicConcept? {
        if showCustomInput && !customWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let word = customWord.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = customTitle.isEmpty ? "Ты никогда не поймёшь это, пока не потеряешь всё." : customTitle
            return ThematicConcept(
                word: word,
                tagline: "Сквозное эссе вокруг идеи «\(word)».",
                philosophicalPremise: "Исследование цены успеха и внутренней силы через тему «\(word)».",
                suggestedTitle: title,
                accentColorHex: "#F5D020"
            )
        }
        return concepts.first(where: { $0.id == selectedConceptId }) ?? primaryConcept ?? concepts.first
    }

    private var resolvedMusicURL: URL? {
        guard ambientMusicEnabled else { return nil }
        if let customAudioURL {
            return customAudioURL
        }
        let fileName = musicPresets[selectedPresetIndex].fileName
        return resolveMusicFile(fileName: fileName)
    }

    private func resolveMusicFile(fileName: String) -> URL? {
        if let url = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "Music") {
            return url
        }
        if let url = Bundle.main.url(forResource: fileName, withExtension: nil) {
            return url
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        if let resMusicURL = Bundle.main.resourceURL?.appendingPathComponent("Music/\(fileName)"),
           FileManager.default.fileExists(atPath: resMusicURL.path) {
            return resMusicURL
        }
        let fallback = BackgroundMusicService.shared.defaultMusicDirectory().appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        let localPath = URL(fileURLWithPath: "Shortcast/Resources/Music/\(fileName)")
        if FileManager.default.fileExists(atPath: localPath.path) {
            return localPath
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            // Заголовок и блок названия фильма
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "film.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                    Text("Центральная тема кино-эссе (Shortcast Cinema)")
                        .font(.title2.weight(.bold))

                    if let onRegenerate {
                        Button {
                            isRegenerating = true
                            onRegenerate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                isRegenerating = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if isRegenerating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isRegenerating ? "Анализ сценария..." : "Пересчитать темы с AI")
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.yellow)
                        .disabled(isRegenerating)
                        .help("Повторно запустить глубокий анализ сценария через нейросеть Director")
                    }
                }

                // Поле подтверждения / редактирования названия фильма
                HStack(spacing: 12) {
                    Label("Фильм:", systemImage: "sparkles.tv")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    TextField("Название фильма (например, Револьвер)", text: $editedMovieTitle)
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

                Text("Нейросеть проанализировала диалоги и выбрала фундаментальную тему для 5–8 минутного ролика:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }
            .padding(.top, 14)

            // Сетка карточек концептов
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    // HERO CARD: Главный выбор нейросети (100% фокус эссе)
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
                                        Image(systemName: "sparkles")
                                            .font(.caption2)
                                        Text("ВЫБОР ИИ • ГЛАВНАЯ ТЕМА ЭССЕ")
                                            .font(.system(size: 10, weight: .black, design: .rounded))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.yellow.opacity(0.20))
                                    .foregroundStyle(.yellow)
                                    .clipShape(Capsule())

                                    if isGenerated {
                                        Text("УЖЕ СМОНТИРОВАНО ✓")
                                            .font(.system(size: 9, weight: .black))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundStyle(.green)
                                            .clipShape(Capsule())
                                    }

                                    Spacer()

                                    Text("РЕКОМЕНДОВАНО ДЛЯ YOUTUBE")
                                        .font(.system(size: 10, weight: .heavy))
                                        .foregroundStyle(Color.yellow.opacity(0.85))
                                }

                                // Основная строка концепта
                                HStack(alignment: .center, spacing: 18) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(primary.word.uppercased())
                                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                                            .foregroundStyle(isSelected ? .white : .primary)

                                        Text(primary.suggestedTitle)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color(hex: primary.accentColorHex))
                                    }
                                    .frame(width: 290, alignment: .leading)

                                    Divider()
                                        .frame(height: 48)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(primary.tagline)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.primary)

                                        Text(primary.philosophicalPremise)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title)
                                        .foregroundStyle(isSelected ? .yellow : .secondary.opacity(0.4))
                                }

                                // Драматургический разбор сценария от ИИ
                                if let reasoning = reasoningText, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "brain.head.profile")
                                            .font(.subheadline)
                                            .foregroundStyle(.yellow)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("Почему модель выбрала именно эту тему:")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.yellow)
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
                                            .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
                                    )
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(isSelected ? Color.yellow.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(isSelected ? Color.yellow : Color.yellow.opacity(0.4), lineWidth: isSelected ? 2.5 : 1.2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Секция альтернативных тем
                    if !alternativeConcepts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Альтернативные грани и темы фильма:")
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
                                                    Text("СМОНТИРОВАНО ✓")
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
                                                .foregroundStyle(Color(hex: concept.accentColorHex))
                                        }
                                        .frame(width: 290, alignment: .leading)

                                        Divider()
                                            .frame(height: 40)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(concept.tagline)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)

                                            Text(concept.philosophicalPremise)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }

                                        Spacer()

                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundStyle(isSelected ? .yellow : .secondary.opacity(0.4))
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(isSelected ? Color.yellow.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(isSelected ? Color.yellow : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
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
                                    .foregroundStyle(.yellow)
                                Text("Ввести своё философское слово/тему вручную")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        if showCustomInput {
                            VStack(spacing: 10) {
                                TextField("Главное слово (например: Честь, Гордость, Гнев)", text: $customWord)
                                    .textFieldStyle(.roundedBorder)

                                TextField("Заголовок YouTube от 2-го лица (например: Ты поймёшь это...)", text: $customTitle)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 285)

            Divider()

            // Блок аудиомастеринга и звукорежиссуры Shortcast Cinema
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.headline)
                            .foregroundStyle(.yellow)
                        Text("Звукорежиссура и аудиомастеринг")
                            .font(.headline)
                    }

                    Spacer()

                    // Чекбокс кинематографического Cold Open
                    Toggle(isOn: $coldOpenEnabled) {
                        HStack(spacing: 4) {
                            Image(systemName: "film.stack")
                            Text("Cold Open (2.5с интро)")
                        }
                        .font(.caption.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    .help("Плавное кинематографическое вступление в затемнении перед первым кадром фильма")
                }

                // 1. Секция диалогов фильма: Dialogue Focus (Center Channel Extraction)
                HStack(spacing: 14) {
                    Toggle(isOn: $dialogueFocusEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Фокус на диалогах (Dialogue Focus)")
                                    .font(.subheadline.weight(.semibold))
                                Text("5.1 / СТЕРЕО")
                                    .font(.system(size: 9, weight: .black))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.yellow.opacity(0.2))
                                    .foregroundStyle(.yellow)
                                    .clipShape(Capsule())
                            }
                            Text("Приглушать оригинальную музыку фильма, сохраняя чёткие голоса актеров дубляжа")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Spacer()

                    if dialogueFocusEnabled {
                        HStack(spacing: 8) {
                            Text("Подавление музыки:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $originalMusicDucking, in: 0.40...1.00, step: 0.05)
                                .frame(width: 85)
                            Text("-\(Int(round(originalMusicDucking * 100)))%")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.yellow)
                                .frame(width: 50, alignment: .trailing)
                        }
                        .help("Уровень приглушения фоновой музыки и шумов оригинального фильма (по умолчанию -82%)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))

                // 2. Секция фоновой музыки: Cinematic Dark Ambient
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Фоновая музыка (Cinematic Dark Ambient)", isOn: $ambientMusicEnabled)
                            .font(.subheadline.weight(.semibold))
                            .toggleStyle(.switch)

                        Spacer()

                        if ambientMusicEnabled {
                            Toggle("Приглушать под речью (Sidechain Ducking)", isOn: $duckingEnabled)
                                .font(.caption.weight(.medium))
                                .toggleStyle(.checkbox)
                                .help("Автоматически снижать громкость саундтрека во время реплик персонажей")
                        }
                    }

                    if ambientMusicEnabled {
                        HStack(spacing: 12) {
                            Picker("Саундтрек:", selection: $selectedPresetIndex) {
                                ForEach(0..<musicPresets.count, id: \.self) { idx in
                                    Text(musicPresets[idx].name).tag(idx)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320)
                            .disabled(customAudioURL != nil)

                            Button {
                                let openPanel = NSOpenPanel()
                                openPanel.canChooseFiles = true
                                openPanel.canChooseDirectories = false
                                openPanel.allowsMultipleSelection = false
                                openPanel.allowedContentTypes = [.audio, .mp3, .wav]
                                openPanel.message = "Выберите аудиодорожку (mp3, wav, m4a)"
                                if openPanel.runModal() == .OK, let url = openPanel.url {
                                    customAudioURL = url
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: customAudioURL != nil ? "checkmark.circle.fill" : "music.note.list")
                                    Text(customAudioURL != nil ? customAudioURL!.lastPathComponent : "Свой файл…")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(customAudioURL != nil ? .yellow : .secondary)

                            if customAudioURL != nil {
                                Button {
                                    customAudioURL = nil
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            // Кнопка предпрослушивания саундтрека
                            Button {
                                previewController.toggle(url: resolvedMusicURL, volume: Float(ambientVolume))
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: previewController.isPlaying ? "pause.fill" : "play.fill")
                                    Text(previewController.isPlaying ? "Пауза" : "Слушать")
                                }
                                .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .tint(previewController.isPlaying ? .yellow : .secondary)
                            .disabled(resolvedMusicURL == nil)

                            Spacer()

                            // Регулятор громкости саундтрека
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.1.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $ambientVolume, in: 0.05...0.40)
                                    .frame(width: 80)
                                Text("\(Int(ambientVolume * 100))%")
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

                // 3. Защита от YouTube Content ID (YouTube Shield)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("Защита YouTube Shield (Anti-Copyright)", isOn: $antiCopyrightEnabled)
                            .font(.subheadline.weight(.semibold))
                            .toggleStyle(.switch)

                        Spacer()

                        if antiCopyrightEnabled {
                            Picker("Пресет:", selection: $antiCopyrightPreset) {
                                ForEach(AntiCopyrightPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 340)
                        }
                    }

                    if antiCopyrightEnabled {
                        Text("3.5% микро-зум, 35мм кинозерно, акустический сдвиг питча (+12¢) и очистка метаданных для защиты от Content ID и страйков.")
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

            Divider()

            // Кнопки управления
            HStack(spacing: 16) {
                Button("Отмена", role: .cancel) {
                    previewController.stop()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    previewController.stop()
                    if let chosen = activeSelection {
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
                        onSelect(chosen, finalTitle, audioSettings)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                        Text("Смонтировать кино-эссе (7–10 мин)")
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .keyboardShortcut(.defaultAction)
                .disabled(activeSelection == nil)
            }
            .padding(.bottom, 8)
        }
        .padding(22)
        .frame(minWidth: 780, minHeight: 640)
        .onChange(of: selectedPresetIndex) { _, _ in
            if previewController.isPlaying, let url = resolvedMusicURL {
                previewController.play(url: url, volume: Float(ambientVolume))
            }
        }
        .onChange(of: customAudioURL) { _, _ in
            if previewController.isPlaying, let url = resolvedMusicURL {
                previewController.play(url: url, volume: Float(ambientVolume))
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
