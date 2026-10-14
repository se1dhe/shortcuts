import SwiftUI
import AppKit

/// Вкладка «Публикация»: выбор платформ, экспорт MP4 с AI-эффектами и публикация в соцсети.
/// Single Responsibility Principle (SRP): отвечает исключительно за экспорт файла и отправку в соцсети.
struct ShortClipPublishEditorView: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    @State private var publishPlatforms: Set<SocialPlatform> = Set(SocialPlatform.allCases)
    @State private var showBrowserPublish = false
    @State private var isDownloading = false

    private var publishResultPresented: Binding<Bool> {
        Binding(
            get: { clip.publishReport != nil || clip.publishError != nil },
            set: { if !$0 { clip.dismissPublishResult() } }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Секция 1: Статус клипа и утверждение
                approvalSection

                // Секция 2: Выбор платформ для публикации
                platformSelectionSection

                // Секция 3: Действия экспорта и публикации
                actionsSection

                // Секция 4: История и отчеты о публикации
                if let report = clip.publishReport {
                    reportSection(report: report)
                }

                if let err = clip.publishError {
                    errorSection(error: err)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: publishResultPresented) {
            PublishResultView(report: clip.publishReport, error: clip.publishError)
        }
        .sheet(isPresented: $showBrowserPublish) {
            BrowserPublishSheet(clip: clip)
        }
    }

    // MARK: - Approval Section

    private var approvalSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.isApproved ? "Шортс утвержден к публикации" : "Шортс не утвержден")
                    .font(.headline)
                    .foregroundStyle(clip.isApproved ? .primary : .secondary)

                Text(clip.isApproved ? "Будет включен в пакетную публикацию «Опубликовать все»." : "Исключен из пакетного экспорта и публикации.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Утвердить", isOn: $clip.isApproved)
                .toggleStyle(.switch)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(clip.isApproved ? Color.green.opacity(0.1) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(clip.isApproved ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Platform Selection Section

    private var platformSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Целевые соцсети для публикации", systemImage: "network")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(SocialPlatform.allCases) { platform in
                    let isSelected = publishPlatforms.contains(platform)
                    HStack(spacing: 12) {
                        Image(systemName: platform.symbolName)
                            .font(.title3)
                            .foregroundStyle(platform.tint)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(platform.displayName)
                                .font(.body.weight(.semibold))

                            if let variant = clip.variants.first(where: { $0.platform == platform }) {
                                Text(variant.hook.isEmpty ? "Заголовок не задан" : variant.hook)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Button {
                            if isSelected {
                                publishPlatforms.remove(platform)
                            } else {
                                publishPlatforms.insert(platform)
                            }
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Действия", systemImage: "arrow.up.circle.fill")
                .font(.headline)

            HStack(spacing: 12) {
                // 1. Скачать MP4
                Button {
                    downloadClip()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                        Text("Скачать готовый MP4")
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(clip.isExporting || isDownloading)

                // 2. Опубликовать через браузер
                Button {
                    showBrowserPublish = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "safari")
                        Text("Опубликовать через браузер")
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Spacer()

                // 3. Прямая публикация по API
                Button {
                    Task {
                        await clip.publish(
                            settings: settings,
                            selectedPlatforms: publishPlatforms
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        if clip.isPublishing {
                            ProgressView().controlSize(.small)
                            Text("Публикация…")
                        } else {
                            Image(systemName: "paperplane.fill")
                            Text("Опубликовать в \(publishPlatforms.count) сети")
                        }
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(clip.isPublishing || publishPlatforms.isEmpty)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - Report & Error Sections

    private func reportSection(report: UploadPostClient.PublishReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Отчет о публикации", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            ForEach(SocialPlatform.allCases) { platform in
                if let outcome = report.outcomes[platform] {
                    HStack {
                        Text(platform.displayName)
                            .font(.body.weight(.semibold))
                        Spacer()
                        switch outcome {
                        case .success:
                            Text("Успешно").foregroundStyle(.green).font(.caption.bold())
                        case .submitted:
                            Text("Отправлено").foregroundStyle(.orange).font(.caption.bold())
                        case .failure(let reason):
                            Text(reason).foregroundStyle(.red).font(.caption)
                        }
                    }
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.green.opacity(0.3)))
    }

    private func errorSection(error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ошибка публикации", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.3)))
    }

    private func downloadClip() {
        ClipExportHelper.downloadClip(clip, settings: settings)
    }
}
