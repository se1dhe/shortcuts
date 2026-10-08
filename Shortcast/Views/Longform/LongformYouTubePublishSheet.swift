import SwiftUI

/// Модальный экран автовыгрузки готового длинного эссе на YouTube через локальный браузер Chrome.
/// Single Responsibility Principle (SRP): отвечает только за интерфейс выгрузки 16:9 роликов в YouTube Studio.
struct LongformYouTubePublishSheet: View {

    let result: LongformBuildResult
    let movieTitle: String
    let movie: MovieIdentity?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var authStatus: BrowserAuthStatus = BrowserAuthStatus()
    @State private var isCheckingAuth: Bool = false
    @State private var isLoggingIn: Bool = false
    @State private var isUploading: Bool = false

    @State private var editedTitle: String
    @State private var editedDescription: String
    @State private var isPublic: Bool = true
    @State private var autoPostToTelegram: Bool = true

    @State private var logs: [String] = []
    @State private var uploadProgressMessage: String = "Готов к публикации"
    @State private var uploadSuccess: Bool = false
    @State private var telegramPostMessage: String? = nil
    @State private var errorMessage: String? = nil

    init(result: LongformBuildResult, movieTitle: String, movie: MovieIdentity? = nil) {
        self.result = result
        self.movieTitle = movieTitle
        self.movie = movie
        self._editedTitle = State(initialValue: result.metadata.title)
        self._editedDescription = State(initialValue: result.metadata.description)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Заголовок
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Автовыгрузка в YouTube Studio")
                        .font(.headline)
                    Text("Публикация через локальный Google Chrome без ограничений API")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Статус авторизации в Chrome
                    HStack(spacing: 12) {
                        Image(systemName: authStatus.youtube ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(authStatus.youtube ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(authStatus.youtube ? "YouTube аккаунт подключен" : "YouTube аккаунт не обнаружен в Chrome")
                                .font(.subheadline.weight(.semibold))
                            Text(authStatus.youtube ? "Используется активная сессия вашего Google Chrome." : "Нажмите кнопку ниже, чтобы войти в YouTube в браузере.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isCheckingAuth || isLoggingIn {
                            ProgressView().controlSize(.small)
                        } else if !authStatus.youtube {
                            Button("Войти в Google…") {
                                Task { await openLogin() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Проверить") {
                                Task { await checkAuth() }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    // Поля метаданных
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Настройки публикации")
                            .font(.subheadline.weight(.bold))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Заголовок видео")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Заголовок для YouTube", text: $editedTitle)
                                .textFieldStyle(.roundedBorder)
                        }

                        if let thumbURL = result.thumbnailURL, let nsImage = NSImage(contentsOf: thumbURL) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Обложка для YouTube Studio (1920×1080)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Label("Готова к загрузке", systemImage: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(16/9, contentMode: .fit)
                                    .frame(maxHeight: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Описание (с таймкодами и цитатами)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $editedDescription)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(height: 120)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        }

                        HStack {
                            Toggle("Сделать видео общедоступным (Public)", isOn: $isPublic)
                                .font(.subheadline)
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Автопостинг анонса и видео/ссылки в Telegram (\(settings.telegramChannelId.isEmpty ? "канал не задан" : settings.telegramChannelId))", isOn: $autoPostToTelegram)
                                .font(.subheadline)

                            if let tgStatus = telegramPostMessage {
                                HStack(spacing: 6) {
                                    Image(systemName: "paperplane.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                    Text(tgStatus)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 20)
                            }
                        }
                    }

                    // Консоль логов выгрузки
                    if !logs.isEmpty || isUploading {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Лог автоматизации Playwright:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(uploadProgressMessage)
                                    .font(.caption)
                                    .foregroundStyle(uploadSuccess ? .green : (errorMessage != nil ? .red : .yellow))
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(8)
                            }
                            .frame(height: 110)
                            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    if let error = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if uploadSuccess {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Видео успешно загружено на YouTube Studio!")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(10)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20)
            }

            Divider()

            // Футер с кнопкой запуска
            HStack {
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await startUpload() }
                } label: {
                    HStack(spacing: 8) {
                        if isUploading {
                            ProgressView().controlSize(.small)
                            Text("Выгрузка в YouTube…")
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Опубликовать на YouTube")
                        }
                    }
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isUploading || editedTitle.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 580, minHeight: 520)
        .task {
            await checkAuth()
        }
    }

    private func checkAuth() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }
        do {
            authStatus = try await BrowserAutomationService.shared.checkAuthStatus()
        } catch {
            logs.append("Не удалось проверить статус авторизации: \(error.localizedDescription)")
        }
    }

    private func openLogin() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            authStatus = try await BrowserAutomationService.shared.openLoginSession()
        } catch {
            errorMessage = "Не удалось открыть сессию браузера: \(error.localizedDescription)"
        }
    }

    private func startUpload() async {
        isUploading = true
        errorMessage = nil
        uploadSuccess = false
        uploadProgressMessage = "Подготовка файла..."
        logs.removeAll()

        let job = BrowserUploadJob(
            videoURL: result.outputURL,
            thumbnailURL: result.thumbnailURL,
            platforms: [.youtube],
            title: editedTitle,
            caption: editedDescription,
            hashtags: result.metadata.tags,
            isPublic: isPublic,
            headless: true
        )

        do {
            let stream = BrowserAutomationService.shared.publish(job: job)
            for try await event in stream {
                switch event {
                case .progress(_, let msg):
                    uploadProgressMessage = msg
                    logs.append(msg)
                case .success(let platform, let msg, let postURL):
                    uploadProgressMessage = "Загружено на \(platform)"
                    logs.append("Успешно: \(postURL ?? msg)")
                    uploadSuccess = true

                    if autoPostToTelegram {
                        logs.append("Запуск автопостинга в Telegram-канал...")
                        await publishToTelegram(youtubeURL: postURL)
                    }
                case .failure(let platform, let err):
                    uploadProgressMessage = "Ошибка: \(platform ?? "YouTube")"
                    logs.append("Ошибка: \(err)")
                    errorMessage = err
                case .captchaDetected(let platform, let msg):
                    uploadProgressMessage = "Требуется решение капчи на \(platform)"
                    logs.append("Внимание: \(msg)")
                case .finished:
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            logs.append("Ошибка процесса: \(error.localizedDescription)")
        }

        isUploading = false
    }

    private func publishToTelegram(youtubeURL: String?) async {
        let botToken = settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = settings.telegramChannelId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !botToken.isEmpty, !channelId.isEmpty else {
            let errText = "Токен Telegram или ID канала не заданы в Настройках — публикация пропущена."
            logs.append("⚠️ \(errText)")
            telegramPostMessage = errText
            return
        }

        do {
            let msgId = try await TelegramPublishingService.shared.publishLongformPost(
                result: result,
                movieTitle: movieTitle,
                movie: movie,
                youtubeURL: youtubeURL,
                botToken: botToken,
                channelId: channelId
            )
            let successText = "Анонс и видео/ссылка успешно опубликованы в Telegram (\(channelId), пост #\(msgId))"
            logs.append("✈️ \(successText)")
            telegramPostMessage = successText
        } catch {
            let errText = "Не удалось опубликовать в Telegram: \(error.localizedDescription)"
            logs.append("⚠️ \(errText)")
            telegramPostMessage = errText
        }
    }
}
