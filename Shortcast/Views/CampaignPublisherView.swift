import SwiftUI
import AppKit

/// Live checklist for a cross-platform campaign: essay → YouTube, each short →
/// TikTok/Instagram/Shorts, then an editable Telegram post tying it all together.
struct CampaignPublisherView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Bindable var publisher: CampaignPublisher

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            checklist
            Divider()
            telegramEditor
            Divider()
            footerButtons
        }
        .padding(20)
        .frame(width: 660, height: 700)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Кампейн-публикация", systemImage: "antenna.radiowaves.left.and.right")
                .font(.title2.weight(.semibold))
            Text("Эссе → YouTube, шортсы → TikTok / Instagram / Shorts, затем единый пост в Telegram со всеми ссылками.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var checklist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if publisher.steps.isEmpty {
                    Text("Нет материалов для публикации. Одобрите хотя бы один шорт или соберите эссе.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(publisher.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        statusIcon(step.status)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.callout.weight(.medium))
                            if let detail = step.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder
    private func statusIcon(_ status: CampaignPublisher.StepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var telegramEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Пост в Telegram")
                    .font(.headline)
                Spacer()
                Button("Обновить черновик") { publisher.refreshTelegramDraft() }
                    .disabled(publisher.isRunning)
            }

            TextField("Ссылка на эссе (YouTube)", text: $publisher.essayYouTubeURL, prompt: Text("https://youtube.com/watch?v=…"))
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $publisher.telegramDraft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .frame(minHeight: 120)

            if settings.telegramBotToken.trimmed.isEmpty || settings.telegramChannelId.trimmed.isEmpty {
                Label("Токен бота или канал не заданы — укажите их в Настройках (⌘,).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await publisher.runCampaign(settings: settings) }
            } label: {
                if publisher.isRunning {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Публикация…") }
                } else {
                    Label("Публиковать кампейн", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(publisher.isRunning)

            Button {
                Task { await publisher.publishTelegramOnly(settings: settings) }
            } label: {
                Label("Только Telegram-пост", systemImage: "text.bubble")
            }
            .buttonStyle(.bordered)
            .disabled(publisher.isRunning || publisher.telegramDraft.trimmed.isEmpty)

            Button {
                exportAllFiles()
            } label: {
                Label("Экспортировать все файлы", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(publisher.filesToExport().isEmpty)

            Spacer()

            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func exportAllFiles() {
        let urls = publisher.filesToExport().filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
