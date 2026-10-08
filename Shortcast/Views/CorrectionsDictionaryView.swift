import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor for the Whisper self-learning corrections dictionary: a searchable
/// table of `original → corrected` pairs with CSV import/export and clear-all.
struct CorrectionsDictionaryView: View {

    @Environment(\.dismiss) private var dismiss
    private let service = TranscriptionCorrectionsService.shared

    @State private var searchText = ""
    @State private var statusMessage: String?

    private struct Row: Identifiable {
        let id: String
        let original: String
        let corrected: String
    }

    private var rows: [Row] {
        let all = service.corrections.map { Row(id: $0.key, original: $0.key, corrected: $0.value) }
            .sorted { $0.original.localizedStandardCompare($1.original) == .orderedAscending }
        guard !searchText.trimmed.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter { $0.original.lowercased().contains(q) || $0.corrected.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Словарь исправлений транскрибации")
                .font(.title3.weight(.semibold))
            Text("Пары «ошибка Whisper → исправление», собранные из правок субтитров. Они передаются в Whisper как контекст при следующей транскрибации. Всего: \(service.corrections.count).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Поиск", text: $searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(16)
    }

    @ViewBuilder
    private var table: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "Пока пусто",
                systemImage: "text.badge.checkmark",
                description: Text("Исправляйте субтитры в редакторе — пары будут накапливаться здесь."))
        } else {
            Table(rows) {
                TableColumn("Оригинал") { row in
                    Text(row.original).lineLimit(2).textSelection(.enabled)
                }
                TableColumn("Исправление") { row in
                    Text(row.corrected).lineLimit(2).textSelection(.enabled)
                }
                TableColumn("") { row in
                    HStack {
                        Spacer()
                        Button {
                            service.removeCorrection(for: row.original)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .width(40)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Импорт CSV…") { importCSV() }
            Button("Экспорт CSV…") { exportCSV() }
                .disabled(service.corrections.isEmpty)
            Button("Очистить все", role: .destructive) {
                service.clearAll()
                statusMessage = "Словарь очищен."
            }
            .disabled(service.corrections.isEmpty)

            Spacer()

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Готово") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "shortcast-corrections.csv"
        panel.message = "Экспортировать словарь исправлений"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try service.exportCSV(to: url)
                statusMessage = "Экспортировано: \(url.lastPathComponent)"
            } catch {
                statusMessage = "Ошибка экспорта: \(error.localizedDescription)"
            }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Импортировать словарь исправлений из CSV"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try service.importCSV(from: url)
                statusMessage = "Импортировано из \(url.lastPathComponent)."
            } catch {
                statusMessage = "Ошибка импорта: \(error.localizedDescription)"
            }
        }
    }
}
