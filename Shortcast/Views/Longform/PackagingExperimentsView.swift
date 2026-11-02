import SwiftUI
import AppKit

struct PackagingExperimentsView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var selected: PackagingExperiment?
    @State private var editing: PackagingExperiment?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Варианты упаковки и результаты").font(.title2.bold())
                Spacer()
                Button(busy ? "Готовлю…" : "Создать три варианта") { run { try await workspace.generatePackagingExperiments(modelManager: modelManager) } }.disabled(busy)
                Button("Закрыть") { dismiss() }.disabled(busy)
            }
            Text("Название, обложка и тема хранятся отдельно. Замеры вносятся вручную из Studio; автоматический A/B-тест на YouTube здесь не запускается.").font(.callout).foregroundStyle(.secondary)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach((workspace.currentProject?.packagingExperiments ?? []).sorted { $0.createdAt > $1.createdAt }) { variant in
                        VStack(alignment: .leading, spacing: 12) {
                            if let url = variant.coverURL, let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().aspectRatio(16/9, contentMode: .fit)
                            } else {
                                Text(variant.coverText.uppercased()).font(.system(size: 28, weight: .bold, design: .serif)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading).padding(16).background(.black)
                            }
                            Text(variant.title).font(.headline)
                            Text("Создан: " + variant.createdAt.formatted()).font(.caption2).foregroundStyle(.secondary)
                            if variant.needsCoverRefresh {
                                Label("Обложку нужно обновить до текущего оформления", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.yellow)
                            }
                            if variant.sourceVariantID != nil {
                                Text("Новая версия; предыдущая сохранена в истории").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(variant.rationale).font(.caption).foregroundStyle(.secondary)
                            if let applied = variant.appliedAt { Text("Применён: " + applied.formatted()).font(.caption2).foregroundStyle(StudioTheme.accent) }
                            Text("Замеров: \(variant.observations.count)").font(.caption)
                            if let latest = variant.observations.last {
                                Text("CTR: \(latest.ctr.map { String(format: "%.2f%%", $0) } ?? "—") · Удержание: \(latest.retentionPercent.map { String(format: "%.1f%%", $0) } ?? "—")").font(.caption).monospacedDigit()
                                Text(latest.source).font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(variant.needsCoverRefresh ? "Обновить и применить" : "Применить") { run { try await workspace.applyPackagingExperiment(variant.id, modelManager: modelManager) } }.disabled(busy)
                                Button("Результаты…") { selected = variant }.disabled(busy)
                            }
                            HStack {
                                Button("Править текст…") { editing = variant }.disabled(busy)
                                Button("Новая обложка") { run { _ = try await workspace.refreshPackagingExperimentCover(variant.id, modelManager: modelManager) } }.disabled(busy)
                            }
                        }.padding(16).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            OperationLogPanel(isActive: busy)
        }.padding(24).frame(width: 1060, height: 760)
        .sheet(item: $selected) { variant in PackagingObservationEditor(variant: variant) }
        .sheet(item: $editing) { variant in PackagingTextEditor(variant: variant) }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}

private struct PackagingTextEditor: View {
    let variant: PackagingExperiment
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var coverText: String
    @State private var rationale: String
    @State private var error: String?
    @State private var saving = false

    init(variant: PackagingExperiment) {
        self.variant = variant
        _title = State(initialValue: variant.title)
        _coverText = State(initialValue: variant.coverText)
        _rationale = State(initialValue: variant.rationale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Редактура варианта").font(.title2.bold())
            Text("Правки сохраняются новым вариантом. Прежняя обложка, замеры и история применения сохранятся; для нового текста понадобится новая обложка.").font(.callout).foregroundStyle(.secondary)
            TextField("Название публикации", text: $title)
            TextField("Текст обложки: 1–3 слова", text: $coverText)
            TextField("Почему этот вариант подходит к эссе", text: $rationale, axis: .vertical)
            let suspicious = UkrainianTextReview.suspiciousWords(in: title + " " + coverText + " " + rationale)
            if !suspicious.isEmpty {
                Text("Проверьте написание: " + suspicious.joined(separator: ", ") + ". Словарь может не знать имён и авторских формулировок.").font(.caption).foregroundStyle(.yellow)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { dismiss() }.disabled(saving)
                Spacer()
                Button(saving ? "Сохраняю…" : "Сохранить новым вариантом") { save() }.disabled(saving)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 700)
    }

    private func save() {
        let title = ThematicConcept.cleanTitle(title)
        let cover = ThematicConcept.cleanTitle(coverText)
        guard !title.isEmpty, title.count <= 100, !cover.isEmpty, cover.count <= 24,
              cover.split(whereSeparator: \.isWhitespace).count <= 3, !rationale.trimmed.isEmpty else {
            error = "Название — до 100 символов; обложка — 1–3 слова до 24 символов. Добавьте обоснование."
            return
        }
        var updated = variant.newRevision()
        updated.title = title; updated.coverText = cover; updated.rationale = rationale.trimmed
        saving = true
        Task {
            defer { saving = false }
            do { try await workspace.savePackagingExperiment(updated); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct PackagingObservationEditor: View {
    let variant: PackagingExperiment
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var views = ""
    @State private var impressions = ""
    @State private var ctr = ""
    @State private var average = ""
    @State private var retention = ""
    @State private var source = "YouTube Studio"
    @State private var notes = ""
    @State private var periodStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var periodEnd = Date()
    @State private var claimStatus = PackagingExperiment.ClaimStatus.unknown
    @State private var monetizationStatus = PackagingExperiment.MonetizationStatus.unknown
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(variant.title).font(.headline)
            Text("Запишите фактические показатели за одинаковый период. Публичные просмотры не дают CTR или удержание.").font(.caption).foregroundStyle(.secondary)
            TextField("Источник данных, например YouTube Studio", text: $source)
            HStack {
                DatePicker("С", selection: $periodStart, displayedComponents: .date)
                DatePicker("По", selection: $periodEnd, displayedComponents: .date)
            }
            HStack { TextField("Просмотры", text: $views); TextField("Показы", text: $impressions); TextField("CTR, %", text: $ctr) }
            HStack { TextField("Средний просмотр, сек", text: $average); TextField("Удержание, %", text: $retention) }
            TextField("Источники трафика, переходы в Telegram, заметки", text: $notes, axis: .vertical)
            HStack {
                Picker("Претензии / блокировки", selection: $claimStatus) {
                    ForEach(PackagingExperiment.ClaimStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Монетизация", selection: $monetizationStatus) {
                    ForEach(PackagingExperiment.MonetizationStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Text("Отметьте фактический статус из Studio. Публикация и отсутствие претензий сами по себе не подтверждают монетизацию.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView { ForEach(variant.observations) { observation in
                VStack(alignment: .leading) {
                    Text(observation.date.formatted() + " · " + observation.source).font(.caption.bold())
                    if let start = observation.periodStart, let end = observation.periodEnd {
                        Text("Период: " + start.formatted(date: .abbreviated, time: .omitted) + " — " + end.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                    }
                    Text("Просмотры: \(observation.views.map(String.init) ?? "—") · CTR: \(observation.ctr.map { String(format: "%.2f%%", $0) } ?? "—") · Средний просмотр: \(observation.averageViewSeconds.map { String(format: "%.1f с", $0) } ?? "—")").font(.caption)
                    Text("Показы: \(observation.impressions.map(String.init) ?? "—") · Удержание: \(observation.retentionPercent.map { String(format: "%.1f%%", $0) } ?? "—")").font(.caption)
                    Text(observation.notes).font(.caption).foregroundStyle(.secondary)
                    Text("Претензии: " + (observation.claimStatus ?? .unknown).label + " · Монетизация: " + (observation.monetizationStatus ?? .unknown).label).font(.caption)
                }.padding(.vertical, 6)
            } }.frame(maxHeight: 180)
            HStack { Button("Отмена") { dismiss() }.disabled(saving); Spacer(); Button(saving ? "Сохраняю…" : "Сохранить замер") { save() }.disabled(saving).buttonStyle(StudioPrimaryButtonStyle()) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 700)
    }
    private func save() {
        guard !saving else { return }
        do {
            func integer(_ text: String) throws -> Int? {
                if text.trimmed.isEmpty { return nil }; guard let n = Int(text.trimmed), n >= 0 else { throw EssayReleaseError.invalid("Количество должно быть целым неотрицательным числом.") }; return n
            }
            func number(_ text: String, percent: Bool) throws -> Double? {
                if text.trimmed.isEmpty { return nil }; guard let n = Double(text.trimmed.replacingOccurrences(of: ",", with: ".")), n.isFinite, n >= 0, !percent || n <= 100 else { throw EssayReleaseError.invalid("Проверьте числовые показатели; проценты должны быть от 0 до 100.") }; return n
            }
            guard !source.trimmed.isEmpty else { throw EssayReleaseError.invalid("Укажите источник замера.") }
            let periodStart = Calendar.current.startOfDay(for: periodStart)
            let periodEnd = Calendar.current.startOfDay(for: periodEnd)
            guard periodStart <= periodEnd, periodEnd <= Date() else { throw EssayReleaseError.invalid("Проверьте период: начало должно быть раньше конца, даты не могут быть в будущем.") }
            let observation = try PackagingExperiment.Observation(views: integer(views), impressions: integer(impressions), ctr: number(ctr, percent: true), averageViewSeconds: number(average, percent: false), retentionPercent: number(retention, percent: true), source: source.trimmed, notes: notes, periodStart: periodStart, periodEnd: periodEnd, claimStatus: claimStatus, monetizationStatus: monetizationStatus)
            guard observation.views != nil || observation.impressions != nil || observation.ctr != nil || observation.averageViewSeconds != nil || observation.retentionPercent != nil || claimStatus != .unknown || monetizationStatus != .unknown else {
                throw EssayReleaseError.invalid("Введите хотя бы один фактический показатель или проверенный статус платформы.")
            }
            var updated = variant; updated.observations.append(observation)
            saving = true
            Task {
                defer { saving = false }
                do { try await workspace.savePackagingExperiment(updated); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
