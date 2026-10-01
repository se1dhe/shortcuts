import SwiftUI

struct ProcessedVideoHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var copiedRecordID: UUID?

    private var records: [ProcessedVideoRecord] {
        settings.processedVideoHistory.sorted { $0.dateProcessed > $1.dateProcessed }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Processed videos")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !settings.processedVideoHistory.isEmpty {
                    Button("Clear all", role: .destructive) {
                        settings.processedVideoHistory = []
                    }
                    .controlSize(.small)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            if records.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No processed videos yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Download a YouTube Short and it will appear here with its generated captions.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(records) { record in
                            recordCard(record)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 540, height: 600)
    }

    private func recordCard(_ record: ProcessedVideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(record.dateProcessed, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    copyRecord(record)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedRecordID == record.id ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(copiedRecordID == record.id ? .green : .primary)
                        Text(copiedRecordID == record.id
                             ? String(localized: "Copied")
                             : String(localized: "Copy all"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy hook, description and hashtags")

                Button {
                    NSWorkspace.shared.open(record.youtubeURL)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open on YouTube")

                Button {
                    var updated = settings.processedVideoHistory
                    updated.removeAll { $0.id == record.id }
                    settings.processedVideoHistory = updated
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete from history")
            }

            if !record.hook.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hook")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(record.hook)
                        .font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                }
            }

            if !record.description.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Description")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(record.description)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            if !record.hashtags.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hashtags")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(record.hashtags)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(.background.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func copyRecord(_ record: ProcessedVideoRecord) {
        let full = [record.hook, record.description, record.hashtags]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copiedRecordID = record.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) {
                copiedRecordID = nil
            }
        }
    }
}
