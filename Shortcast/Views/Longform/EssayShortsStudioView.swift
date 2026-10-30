import AVKit
import SwiftUI

struct EssayShortsStudioView: View {
    let result: LongformBuildResult
    let onOpenPosting: () -> Void
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppSettings.self) private var settings
    @State private var editingShort: EssayShort?
    @State private var preparing = false
    @State private var status = ""
    @State private var error: String?
    private var release: EssayRelease? { workspace.currentEssayRelease }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("ДВА РАКУРСА ОДНОЙ ТЕМЫ").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                        Text("Коротко. Но со смыслом.").font(.system(size: 30, weight: .medium, design: .serif))
                        Text("Самостоятельный вход в тему и её противоречие. Материал — из финального эссе.")
                            .font(.system(size: 13)).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                    if release?.hasReadyShorts == true {
                        Button(action: onOpenPosting) { Label("К постингу", systemImage: "arrow.right") }
                            .buttonStyle(StudioPrimaryButtonStyle()).disabled(workspace.isWorkingOnEssayRelease)
                    }
                }
                if preparing {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Готовим два шортса").font(.headline)
                            Text(status).font(.callout).foregroundStyle(StudioTheme.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).studioPanel()
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let release, !release.shorts.isEmpty {
                    HStack(alignment: .top, spacing: 22) {
                        ForEach(Array(release.shorts.enumerated()), id: \.element.id) { index, short in
                            shortCard(short, index: index, release: release)
                        }
                    }
                } else {
                    HStack(spacing: 30) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(StudioTheme.raised).frame(width: 90, height: 140).rotationEffect(.degrees(-8)).offset(x: -14)
                            RoundedRectangle(cornerRadius: 16).fill(StudioTheme.accent.opacity(0.1)).frame(width: 90, height: 140)
                                .overlay(Image(systemName: "scissors").font(.system(size: 30)).foregroundStyle(StudioTheme.accent))
                        }.frame(width: 150, height: 170)
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Эссе готово. Найдём два новых входа в историю.").font(.system(size: 18, weight: .semibold))
                            Text("Каждый шортс получит свой монтаж, хук, субтитры и обложку. После подготовки их можно отредактировать здесь.")
                                .font(.callout).foregroundStyle(StudioTheme.muted).lineSpacing(4)
                            Button(action: prepare) { Label("Подготовить два шортса", systemImage: "sparkles") }
                                .buttonStyle(StudioPrimaryButtonStyle()).disabled(preparing)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).studioPanel(padding: 32)
                }
                if release?.hasReadyShorts != true, release?.shorts.isEmpty == false, !preparing {
                    Button("Продолжить подготовку", action: prepare).buttonStyle(StudioPrimaryButtonStyle())
                }
            }.padding(32).frame(maxWidth: 1180).frame(maxWidth: .infinity)
        }
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .sheet(item: $editingShort) { short in
            if let source = workspace.job?.url, let transcript = workspace.storedTranscript ?? workspace.currentProject?.transcript {
                EssayShortEditorView(short: short, result: result, transcript: transcript, sourceURL: source) { edited in
                    try await workspace.rebuildEssayShort(edited, settings: settings)
                }
            }
        }
    }

    private func shortCard(_ short: EssayShort, index: Int, release: EssayRelease) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(index == 0 ? "01 / ВХОД В ТЕМУ" : "02 / ПРОТИВОРЕЧИЕ")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(StudioTheme.accent)
                Spacer()
                Text("9:16 · \(Int(short.duration.rounded())) с").font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.muted)
            }
            HStack(alignment: .top, spacing: 18) {
                if let url = short.outputURL, FileManager.default.fileExists(atPath: url.path) {
                    StudioVideoPlayer(url: url).frame(width: 152, height: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(StudioTheme.background)
                        .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(StudioTheme.muted))
                        .frame(width: 152, height: 270)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(short.title).font(.system(size: 19, weight: .semibold))
                    Text(short.hook).font(.system(size: 14)).foregroundStyle(StudioTheme.accent)
                    Text(short.angle).font(.system(size: 12)).foregroundStyle(StudioTheme.muted).lineSpacing(4)
                    Text("\(short.segments.count) сцен · свои субтитры").font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { editingShort = short } label: {
                Label("Редактировать шортс", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large)
                .disabled(preparing || workspace.isWorkingOnEssayRelease || !EssayShortEditing.canEdit(short, in: release))
            if !EssayShortEditing.canEdit(short, in: release) {
                Text("Уже отправлялся на площадки. Статусы сохранены на шаге «Постинг».")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            DisclosureGroup("Вопрос и опорная реплика") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(short.question).bold(); Text("«\(short.payoffQuote)»")
                }.font(.caption).foregroundStyle(StudioTheme.muted).padding(.top, 6)
            }.font(.system(size: 12))
        }.frame(maxWidth: .infinity, alignment: .leading).studioPanel()
    }

    private func prepare() {
        guard !preparing else { return }
        preparing = true; error = nil
        Task { @MainActor in
            defer { preparing = false }
            do { try await workspace.prepareEssayRelease(modelManager: modelManager, settings: settings) { status = $0 } }
            catch { self.error = error.localizedDescription }
        }
    }
}
