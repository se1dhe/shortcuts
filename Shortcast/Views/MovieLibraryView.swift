import SwiftUI

/// The Library tab: a scanned list of local movies from the chosen folder, each
/// showing its normalization status. Clicking a ready item feeds it straight into
/// the shorts/essay pipeline.
struct MovieLibraryView: View {

    @Environment(MovieLibraryService.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager

    @State private var processingURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: settings.movieLibraryURL) {
            library.refresh(settings: settings)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Библиотека фильмов", systemImage: "film.stack")
                    .font(.title2.weight(.semibold))
                Text(library.libraryURL?.path(percentEncoded: false) ?? "Папка не выбрана — укажите её в Настройках → Movie Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                library.refresh(settings: settings)
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(library.libraryURL == nil || library.isScanning)

            Button {
                library.normalizeAll(settings: settings)
            } label: {
                Label("Нормализовать все", systemImage: "wand.and.stars")
            }
            .disabled(pendingCount == 0)

            SettingsLink { Text("Настройки") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var pendingCount: Int {
        library.movies.filter { $0.status == .pending }.count
    }

    @ViewBuilder
    private var content: some View {
        if library.libraryURL == nil {
            ContentUnavailableView(
                "Папка не выбрана",
                systemImage: "folder.badge.questionmark",
                description: Text("Выберите папку с фильмами в Настройках → Movie Library, чтобы видеть и нормализовать MKV-коллекцию."))
        } else if library.movies.isEmpty {
            ContentUnavailableView(
                "Фильмы не найдены",
                systemImage: "film.slash",
                description: Text("В выбранной папке нет видеофайлов (mkv, mp4, mov, avi, webm)."))
        } else {
            List(library.movies) { item in
                row(for: item)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func row(for item: MovieLibraryItem) -> some View {
        HStack(spacing: 12) {
            statusIcon(for: item.status)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .pending = item.status {
                Button("Нормализовать") {
                    library.normalize(item, settings: settings)
                }
                .buttonStyle(.bordered)
            } else if item.processableURL != nil {
                if processingURL == item.url {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        process(item)
                    } label: {
                        Label("В работу", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func process(_ item: MovieLibraryItem) {
        guard let url = item.processableURL else { return }
        processingURL = item.url
        let accessing = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                processingURL = nil
            }
            await workspace.prepareAndProcess(
                url: url,
                sourceMetadata: nil,
                modelManager: modelManager,
                settings: settings)
        }
    }

    private func statusText(for item: MovieLibraryItem) -> String {
        switch item.status {
        case .pending:
            return item.needsNormalization ? "Нуждается в нормализации (MKV/WebM/AVI)" : "Готов"
        case .normalizing:
            return "Нормализация…"
        case .ready(let url):
            return url == item.url ? "Готов к обработке" : "Нормализован: \(url.lastPathComponent)"
        case .failed(let message):
            return "Ошибка: \(message)"
        }
    }

    @ViewBuilder
    private func statusIcon(for status: NormalizationStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .normalizing:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}
