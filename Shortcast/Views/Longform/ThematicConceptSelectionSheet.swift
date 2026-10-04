import SwiftUI

/// Экран выбора или ввода философского лейтмотива фильма в стиле канала @prrodan
struct ThematicConceptSelectionSheet: View {

    let initialMovieTitle: String
    let concepts: [ThematicConcept]
    let onSelect: (ThematicConcept, String, URL?, Float, Bool) -> Void
    let onCancel: () -> Void

    @State private var editedMovieTitle: String
    @State private var selectedConceptId: String? = nil
    @State private var customWord: String = ""
    @State private var customTitle: String = ""
    @State private var showCustomInput: Bool = false

    // Музыкальное сопровождение (Ambient / Cinematic Dark)
    @State private var ambientMusicEnabled: Bool = true
    @State private var duckingEnabled: Bool = true
    @State private var selectedPresetIndex: Int = 0
    @State private var customAudioURL: URL? = nil
    @State private var ambientVolume: Double = 0.18
    @State private var previewController = AudioPreviewController()

    private let musicPresets: [(name: String, fileName: String)] = [
        ("Тёмный эмбиент (Dark Monologue)", "Sigma_Monologue_Dark.m4a"),
        ("Напряжение и саспенс (Suspense)", "Tension_Dark_Suspense.m4a"),
        ("Драматическая тема (Emotional)", "Dramatic_Emotional_Theme.m4a"),
        ("Эпичный экшн-пульс (Pulse)", "Epic_Action_Pulse.m4a")
    ]

    init(
        movieTitle: String,
        concepts: [ThematicConcept],
        onSelect: @escaping (ThematicConcept, String, URL?, Float, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialMovieTitle = movieTitle
        self._editedMovieTitle = State(initialValue: movieTitle)
        self.concepts = concepts
        self.onSelect = onSelect
        self.onCancel = onCancel
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
        return concepts.first(where: { $0.id == selectedConceptId }) ?? concepts.first
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
                HStack(spacing: 10) {
                    Image(systemName: "film.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                    Text("Выберите центральную идею фильма")
                        .font(.title2.weight(.bold))
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

                Text("Название фильма выше будет использовано во вступительной заставке, описании и тегах YouTube. Выберите философский лейтмотив:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }
            .padding(.top, 14)

            // Сетка карточек концептов
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(concepts) { concept in
                        let isSelected = (selectedConceptId == concept.id || (selectedConceptId == nil && concept.id == concepts.first?.id)) && !showCustomInput
                        let isGenerated = LongformHistoryService.shared.isConceptGenerated(movieTitle: editedMovieTitle, conceptWord: concept.word)
                        
                        Button {
                            showCustomInput = false
                            selectedConceptId = concept.id
                        } label: {
                            HStack(alignment: .center, spacing: 18) {
                                // Крупное якорное слово темы (Shortcast Cinema)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(concept.word.uppercased())
                                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                                            .foregroundStyle(isSelected ? .white : .primary)

                                        if isGenerated {
                                            Text("УЖЕ СМОНТИРОВАНО ✓")
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
                                .frame(width: 280, alignment: .leading)

                                Divider()
                                    .frame(height: 44)

                                // Смысловой посыл и слоган
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
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? Color.yellow.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isSelected ? Color.yellow : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Кастомный ввод
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            showCustomInput.toggle()
                        } label: {
                            HStack {
                                Image(systemName: showCustomInput ? "chevron.down" : "plus.circle.fill")
                                    .foregroundStyle(.yellow)
                                Text("Ввести своё философское слово/тему")
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
            .frame(maxHeight: 280)

            Divider()

            // Блок фоновой музыки (Ambient Soundtrack)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("Фоновая музыка (Cinematic Dark Ambient)", isOn: $ambientMusicEnabled)
                        .font(.subheadline.weight(.semibold))
                        .toggleStyle(.switch)

                    Spacer()

                    if ambientMusicEnabled {
                        Toggle("Приглушать под речью (Sidechain Ducking)", isOn: $duckingEnabled)
                            .font(.caption.weight(.medium))
                            .toggleStyle(.checkbox)
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
                        .frame(maxWidth: 300)
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
                        .help(previewController.isPlaying ? "Приостановить предпрослушивание саундтрека" : "Предпрослушать выбранный саундтрек")

                        Spacer()

                        // Регулятор громкости саундтрека
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.1.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $ambientVolume, in: 0.05...0.40)
                                .frame(width: 85)
                            Text("\(Int(ambientVolume * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))

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
                        onSelect(chosen, finalTitle, resolvedMusicURL, Float(ambientVolume), duckingEnabled)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "film.fill")
                        Text("Смонтировать длинный ролик (5–8 мин)")
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
        .frame(minWidth: 740, minHeight: 600)
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
