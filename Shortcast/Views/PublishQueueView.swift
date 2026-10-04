import SwiftUI

/// Dedicated dashboard for automated multi-platform publishing to Instagram Reels, YouTube Shorts, and TikTok.
struct PublishQueueView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    
    @State private var selectedPlatforms: Set<SocialPlatform> = Set(SocialPlatform.allCases)
    @State private var publishImmediately = true
    @State private var scheduleStartDate = Date().addingTimeInterval(3600)
    @State private var scheduleIntervalDays = 1
    @State private var isPublishing = false
    @State private var activePublishReport: UploadPostClient.PublishReport?
    @State private var lastPublishError: String?
    @State private var showResultSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    platformSelectorCard
                    scheduleOptionsCard
                    clipsToPublishSection
                }
                .padding(24)
            }
            
            Divider()
            footer
        }
        .sheet(isPresented: $showResultSheet) {
            PublishResultView(report: activePublishReport, error: lastPublishError)
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Выгрузка и автоматическая публикация")
                    .font(.title2.weight(.bold))
                Text("Пакетная отправка в Instagram Reels, YouTube Shorts и TikTok в один клик")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            
            if !settings.isConfigured {
                SettingsLink {
                    Label("Настроить аккаунты", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    
    // MARK: - Platform Selector
    
    private var platformSelectorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Целевые социальные сети", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Spacer()
                Button("Выбрать все") {
                    selectedPlatforms = Set(SocialPlatform.allCases)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            
            HStack(spacing: 14) {
                ForEach(SocialPlatform.allCases) { platform in
                    let isSelected = selectedPlatforms.contains(platform)
                    Button {
                        if isSelected {
                            if selectedPlatforms.count > 1 {
                                selectedPlatforms.remove(platform)
                            }
                        } else {
                            selectedPlatforms.insert(platform)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: platform.symbolName)
                                .font(.title3)
                                .foregroundStyle(Color(hex: platform.tintHex))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platform.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(platformSubtitle(for: platform))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(isSelected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    
    private func platformSubtitle(for platform: SocialPlatform) -> String {
        switch platform {
        case .youtube: "9:16 Shorts, теги, авто-название"
        case .instagram: "Reels, сторителлинг, 25-30 хештегов"
        case .tiktok: "Динамичный хук, трендовые теги"
        case .telegram: "Карточка фильма, постер, рейтинги и синопсис"
        }
    }
    
    // MARK: - Schedule Options
    
    private var scheduleOptionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Расписание и режим отправки", systemImage: "clock")
                .font(.headline)
            
            HStack(spacing: 20) {
                Picker("Режим публикации", selection: $publishImmediately) {
                    Text("Опубликовать прямо сейчас").tag(true)
                    Text("Запланировать по дням").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                
                Spacer()
                
                if !publishImmediately {
                    HStack(spacing: 12) {
                        DatePicker("Старт:", selection: $scheduleStartDate, in: Date()...)
                            .labelsHidden()
                        
                        Stepper("Интервал: \(scheduleIntervalDays) дн.", value: $scheduleIntervalDays, in: 1...14)
                    }
                }
            }
            
            if selectedPlatforms.contains(.tiktok) {
                Toggle(isOn: Binding(
                    get: { settings.tiktokAsDraft },
                    set: { settings.tiktokAsDraft = $0 }
                )) {
                    Label("Загружать TikTok как черновик (Inbox Draft) для проверки перед публикацией", systemImage: "tray.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Clips Section
    
    private var readyClips: [ShortClip] {
        workspace.clips.filter { $0.isApproved && $0.isReadyToPublish }
    }
    
    private var clipsToPublishSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Одобренные шортсы к отправке (\(readyClips.count))", systemImage: "film.stack")
                    .font(.headline)
                Spacer()
            }
            
            if readyClips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Нет готовых одобренных шортсов")
                        .font(.callout.weight(.medium))
                    Text("Создайте шортсы из фильма или отметьте галочкой 'Одобрить' в Студии")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    ForEach(readyClips) { clip in
                        HStack(spacing: 12) {
                            Text("\(Int(clip.candidate.duration.rounded()))с")
                                .font(.caption.monospacedDigit().bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                if !clip.detectedMovieTitle.isEmpty {
                                    Text("🎬 \(clip.detectedMovieTitle)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 6) {
                                ForEach(Array(selectedPlatforms)) { platform in
                                    Image(systemName: platform.symbolName)
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: platform.tintHex))
                                }
                            }
                            
                            if clip.isPublishing {
                                ProgressView().controlSize(.small)
                            } else if clip.publishReport != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if let err = clip.publishError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .help(err)
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            if activePublishReport != nil {
                Label("Опубликовано успешно", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else if let err = lastPublishError {
                Label(err, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button {
                startBatchPublish()
            } label: {
                if isPublishing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Публикация…")
                    }
                    .frame(minWidth: 240)
                } else {
                    Label(
                        publishImmediately
                            ? "Опубликовать \(readyClips.count) шортс\(readyClips.count == 1 ? "" : "ов") во все сети"
                            : "Запланировать \(readyClips.count) шортс\(readyClips.count == 1 ? "" : "ов")",
                        systemImage: publishImmediately ? "paperplane.fill" : "calendar.badge.clock"
                    )
                    .frame(minWidth: 240)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPublishing || readyClips.isEmpty || selectedPlatforms.isEmpty || !settings.isConfigured)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
    
    // MARK: - Execution
    
    private func startBatchPublish() {
        guard !readyClips.isEmpty else { return }
        isPublishing = true
        lastPublishError = nil
        activePublishReport = nil
        
        Task {
            let platforms = selectedPlatforms
            if publishImmediately {
                for clip in readyClips {
                    await clip.publish(settings: settings, selectedPlatforms: platforms)
                    if let err = clip.publishError {
                        lastPublishError = err
                    } else if let rep = clip.publishReport {
                        activePublishReport = rep
                    }
                }
            } else {
                var scheduleDate = scheduleStartDate
                for clip in readyClips {
                    await clip.publish(settings: settings, selectedPlatforms: platforms, scheduledDate: scheduleDate)
                    scheduleDate = Calendar.current.date(byAdding: .day, value: scheduleIntervalDays, to: scheduleDate) ?? scheduleDate
                    if let rep = clip.publishReport {
                        activePublishReport = rep
                    }
                }
            }
            isPublishing = false
            showResultSheet = (activePublishReport != nil || lastPublishError != nil)
        }
    }
}
