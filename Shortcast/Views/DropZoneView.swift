import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let isDropTargeted: Bool
    let onChooseFile: (URL, VideoSourceMetadata?) -> Void
    @Environment(WorkspaceModel.self) private var workspace
    @State private var projects: [FilmProject] = []
    @State private var unsupported = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .center, spacing: 54) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("ОДИН ФИЛЬМ. ЦЕЛЫЙ ВЫПУСК.")
                            .font(.system(size: 10, weight: .bold)).tracking(2.4).foregroundStyle(StudioTheme.accent)
                        Text("У каждого фильма\nесть что сказать.")
                            .font(.system(size: 44, weight: .medium, design: .serif)).lineSpacing(2)
                        Text("Найдите свою тему. Соберите эссе, создайте два шортса и подготовьте публикации — в одном проекте.")
                            .font(.system(size: 15)).lineSpacing(6).foregroundStyle(StudioTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            formatBadge("16:9", label: "эссе")
                            formatBadge("9:16", label: "шортсы")
                            formatBadge("UA", label: "озвучка")
                        }.padding(.top, 4)
                    }.frame(maxWidth: 470, alignment: .leading)
                    dropArea
                }
                if let error = workspace.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).studioPanel(padding: 16)
                }
                HStack(spacing: 22) {
                    feature("text.alignleft", title: "Тема и драматургия", text: "Анализ диалогов и пять актов эссе")
                    feature("slider.horizontal.3", title: "Ваш монтаж", text: "Сцены, хуки и субтитры можно изменить")
                    feature("paperplane", title: "Один выпуск", text: "YouTube, TikTok и Telegram")
                }
                if !projects.isEmpty { recentProjects }
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive")
                    Text("Фильм и обработка остаются на Mac. Публикация запускается отдельно.")
                }.font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
            }.frame(maxWidth: 1120).padding(40).frame(maxWidth: .infinity)
        }
        .alert("Выберите видеофайл", isPresented: $unsupported) {
            Button("Понятно", role: .cancel) {}
        } message: { Text("Поддерживаются MP4, MOV, M4V, MKV, WebM и AVI.") }
        .task { projects = Array(((try? await workspace.filmProjectService.listRecentProjects()) ?? []).prefix(3)) }
    }

    private var dropArea: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(StudioTheme.accent.opacity(0.05))
                    .frame(width: 100, height: 76).rotationEffect(.degrees(-10)).offset(x: -10, y: -5)
                RoundedRectangle(cornerRadius: 18).fill(StudioTheme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.accent.opacity(0.25)))
                    .frame(width: 100, height: 76)
                Image(systemName: "film").font(.system(size: 30, weight: .light)).foregroundStyle(StudioTheme.accent)
            }.frame(height: 96)
            VStack(spacing: 8) {
                Text(isDropTargeted ? "Отпустите фильм здесь" : "Перетащите фильм сюда")
                    .font(.system(size: 18, weight: .semibold))
                Text("Оригинал фильма и выбранная аудиодорожка")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
            }
            Button(action: chooseVideoFile) {
                Label("Выбрать фильм", systemImage: "plus")
            }.buttonStyle(StudioPrimaryButtonStyle())
            Text("MP4 · MOV · MKV · WEBM").font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.5).foregroundStyle(StudioTheme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 18)
        .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(
            StudioTheme.accent.opacity(isDropTargeted ? 0.9 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
        .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
    }

    private func formatBadge(_ value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(value).foregroundStyle(StudioTheme.accent).fontWeight(.semibold)
            Text(label).foregroundStyle(StudioTheme.muted)
        }.font(.system(size: 11)).padding(.horizontal, 11).padding(.vertical, 7)
            .background(StudioTheme.raised, in: Capsule())
    }

    private func feature(_ icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(StudioTheme.accent)
                .frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).studioPanel(padding: 18)
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Продолжить работу").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("НЕДАВНИЕ ПРОЕКТЫ").font(.system(size: 9, weight: .medium)).tracking(1.6).foregroundStyle(StudioTheme.muted)
            }
            HStack(spacing: 14) {
                ForEach(projects) { project in
                    let exists = FileManager.default.fileExists(atPath: project.sourceMovieURL.path)
                    Button {
                        if exists { onChooseFile(project.sourceMovieURL, nil) } else { chooseVideoFile() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "film.stack").foregroundStyle(StudioTheme.accent).font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(project.tmdbMetadata?.title ?? MovieMetadataService.parseCandidate(project.movieTitle).title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(exists ? project.updatedAt.formatted(date: .abbreviated, time: .omitted) : "Укажите исходный файл")
                                    .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                        }.frame(maxWidth: .infinity).studioPanel(padding: 16)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите исходный фильм"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased(), type = UTType(filenameExtension: url.pathExtension)
            guard ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext) || type?.conforms(to: .movie) == true else {
                unsupported = true; return
            }
            onChooseFile(url, nil)
        }
    }
}
