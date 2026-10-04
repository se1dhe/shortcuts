import AVKit
import AppKit
import SwiftUI

/// Экран готового длинного ролика (16:9 YouTube Shortcast Cinema)
struct LongformResultsView: View {

    let result: LongformBuildResult
    let movieTitle: String
    let onChooseAnotherTheme: () -> Void
    let onStartNewMovie: () -> Void

    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppSettings.self) private var settings

    @State private var player: AVPlayer? = nil
    @State private var copiedTitle = false
    @State private var copiedDescription = false
    @State private var copiedTags = false
    @State private var copiedComment = false

    @State private var showYouTubePublishSheet = false
    @State private var isPostingToTelegram = false
    @State private var telegramPostSuccess = false
    @State private var telegramError: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Левая колонка: 16:9 Видеоплеер
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(result.arc.concept.word.uppercased())
                                .font(.caption.weight(.black))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(hex: result.arc.concept.accentColorHex).opacity(0.2)))
                                .foregroundStyle(Color(hex: result.arc.concept.accentColorHex))

                            Text("«\(movieTitle)»")
                                .font(.headline)
                        }

                        Text(result.metadata.title)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        Label(formatDuration(result.duration), systemImage: "clock")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                        } label: {
                            Label("Показать в Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // 16:9 Контейнер плеера
                ZStack {
                    Color.black

                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16/9, contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .padding(.horizontal, 20)

                // 4-актная временная шкала
                HStack(spacing: 8) {
                    ForEach(result.arc.acts) { act in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(act.type.rawValue)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.primary)
                            Text(formatDuration(act.duration))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(minWidth: 640)

            Divider()

            // Правая колонка: Упаковка, публикация и экспорт
            VStack(alignment: .leading, spacing: 14) {
                Text("Упаковка и Публикация")
                    .font(.headline)

                // Блок быстрых действий (YouTube / Shorts / Telegram)
                VStack(spacing: 8) {
                    Button {
                        showYouTubePublishSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.subheadline)
                            Text("Опубликовать на YouTube")
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button {
                        workspace.generateShortsFromCurrentMovie(modelManager: modelManager, settings: settings)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles.tv")
                                .font(.subheadline)
                            Text("Сгенерировать Shorts по фильму")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)

                    Button {
                        Task { await publishToTelegram() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            if isPostingToTelegram {
                                ProgressView().controlSize(.small)
                                Text("Отправка...")
                            } else if telegramPostSuccess {
                                Image(systemName: "checkmark")
                                Text("Опубликовано в Telegram ✓")
                            } else {
                                Text("Пост в Telegram (\(settings.telegramChannelId.isEmpty ? "@telonyx_club" : settings.telegramChannelId))")
                            }
                        }
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(telegramPostSuccess ? .green : .secondary)
                    .disabled(isPostingToTelegram)

                    if let err = telegramError {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Заголовок
                        metadataCard(
                            title: "Заголовок видео",
                            content: result.metadata.title,
                            copied: copiedTitle
                        ) {
                            copyToClipboard(result.metadata.title)
                            copiedTitle = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTitle = false }
                        }

                        // 2. Описание
                        metadataCard(
                            title: "Описание (манифест + Fair Use)",
                            content: result.metadata.description,
                            copied: copiedDescription,
                            lineLimit: 5
                        ) {
                            copyToClipboard(result.metadata.description)
                            copiedDescription = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDescription = false }
                        }

                        // 3. Теги
                        metadataCard(
                            title: "Теги",
                            content: result.metadata.tags.joined(separator: ", "),
                            copied: copiedTags,
                            lineLimit: 3
                        ) {
                            copyToClipboard(result.metadata.tags.joined(separator: ", "))
                            copiedTags = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTags = false }
                        }

                        // 4. Закрепленный комментарий
                        metadataCard(
                            title: "Закрепленный комментарий",
                            content: result.metadata.pinnedComment,
                            copied: copiedComment,
                            lineLimit: 2
                        ) {
                            copyToClipboard(result.metadata.pinnedComment)
                            copiedComment = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedComment = false }
                        }
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        onChooseAnotherTheme()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Выбрать другую тему")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .help("Выбрать или ввести другую тему без повторного анализа фильма")

                    Button(role: .destructive) {
                        onStartNewMovie()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Новый фильм")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Сбросить текущий фильм и добавить другой")

                    Spacer()

                    Button {
                        exportFile()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Экспорт…")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
            .frame(width: 400)
        }
        .sheet(isPresented: $showYouTubePublishSheet) {
            LongformYouTubePublishSheet(result: result, movieTitle: movieTitle)
        }
        .onAppear {
            player = AVPlayer(url: result.outputURL)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func publishToTelegram() async {
        isPostingToTelegram = true
        telegramError = nil
        defer { isPostingToTelegram = false }

        let botToken = settings.telegramBotToken.isEmpty ? "7797825319:AAH661tUvG9B-d6Kj6Tj-dY4q2gZ6FzE8_0" : settings.telegramBotToken
        let channelId = settings.telegramChannelId.isEmpty ? "@telonyx_club" : settings.telegramChannelId

        do {
            _ = try await TelegramPublishingService.shared.publishLongformPost(
                result: result,
                movieTitle: movieTitle,
                movie: workspace.detectedMovie,
                botToken: botToken,
                channelId: channelId
            )
            telegramPostSuccess = true
        } catch {
            telegramError = error.localizedDescription
        }
    }

    private func metadataCard(
        title: String,
        content: String,
        copied: Bool,
        lineLimit: Int? = nil,
        onCopy: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onCopy()
                } label: {
                    Label(copied ? "Скопировано!" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? .green : .yellow)
            }

            Text(content)
                .font(.callout)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.nameFieldStringValue = result.outputURL.lastPathComponent
        if savePanel.runModal() == .OK, let target = savePanel.url {
            try? FileManager.default.copyItem(at: result.outputURL, to: target)
        }
    }
}
