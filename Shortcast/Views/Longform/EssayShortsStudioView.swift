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
    @State private var preparationFrames: [NSImage] = []
    @State private var preparationStartedAt = Date()
    @State private var preparationEvents: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isPreparing: Bool { preparing || workspace.isWorkingOnEssayRelease }
    private var release: EssayRelease? { workspace.currentEssayRelease }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(L10n.tr("СИЛЬНЫЕ МОМЕНТЫ ФИЛЬМА")).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                        Text(L10n.tr("Коротко. Но со смыслом.")).font(.system(size: 30, weight: .medium, design: .serif))
                        Text(L10n.tr("Две самостоятельные сцены и музыкальный эдит сильных кадров из всего фильма."))
                            .font(.system(size: 13)).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer()
                    if release?.hasReadyShorts == true {
                        Button(action: onOpenPosting) { Label(L10n.tr("К постингу"), systemImage: "arrow.right") }
                            .buttonStyle(StudioPrimaryButtonStyle()).disabled(workspace.isWorkingOnEssayRelease)
                    }
                }
                if let release, !release.usesWholeFilmSelection, !isPreparing {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("Эти шортсы подготовлены по прежнему подбору из эссе."))
                            .font(.callout).foregroundStyle(StudioTheme.muted)
                        if !release.hasProtectedDeliveries {
                            Button(L10n.tr("Подобрать сильные моменты всего фильма"), action: prepare)
                                .buttonStyle(StudioPrimaryButtonStyle())
                        }
                    }
                }
                if let release, release.usesWholeFilmSelection,
                   release.shorts.contains(where: { !$0.isMontage && $0.visualEvidence == nil }), !isPreparing {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("Сохранённые шортсы выбраны по диалогам. Визуальные пробы при их подборе не проверялись."))
                            .font(.callout).foregroundStyle(StudioTheme.muted)
                        if !release.hasProtectedDeliveries {
                            Button(L10n.tr("Переподобрать с проверкой кадров")) { prepare(forceReplan: true) }
                                .buttonStyle(StudioPrimaryButtonStyle())
                                .disabled(workspace.job == nil)
                        }
                    }
                }
                if let release, !release.hasMontage, release.hasWholeFilmStoryPlans,
                   !release.hasProtectedDeliveries, !isPreparing {
                    Button(L10n.tr("Добавить третий шортс — музыкальный эдит"), action: prepare)
                        .buttonStyle(StudioPrimaryButtonStyle()).disabled(workspace.job == nil)
                }
                if isPreparing { preparationWorkspace }
                if let error { Label(L10n.tr(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if !isPreparing, let release, !release.shorts.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), alignment: .top)], alignment: .leading, spacing: 22) {
                        ForEach(Array(release.shorts.enumerated()), id: \.element.id) { index, short in
                            shortCard(short, index: index, release: release)
                        }
                    }
                } else if !isPreparing {
                    HStack(spacing: 30) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(StudioTheme.raised).frame(width: 90, height: 140).rotationEffect(.degrees(-8)).offset(x: -14)
                            RoundedRectangle(cornerRadius: 16).fill(StudioTheme.accent.opacity(0.1)).frame(width: 90, height: 140)
                                .overlay(Image(systemName: "scissors").font(.system(size: 30)).foregroundStyle(StudioTheme.accent))
                        }.frame(width: 150, height: 170)
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.tr("Найдём два самых сильных момента фильма.")).font(.system(size: 18, weight: .semibold))
                            Text(L10n.tr("Каждый шортс получит свой монтаж и обложку: короткая карточка фильма в начале, затем чистое видео. Субтитры можно включить отдельно в редакторе."))
                                .font(.callout).foregroundStyle(StudioTheme.muted).lineSpacing(4)
                            Button(action: prepare) { Label(L10n.tr("Подготовить два шортса и музыкальный эдит"), systemImage: "sparkles") }
                                .buttonStyle(StudioPrimaryButtonStyle()).disabled(preparing)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).studioPanel(padding: 32)
                }
                if release?.hasReadyShorts != true, release?.shorts.isEmpty == false, !preparing {
                    Button(L10n.tr("Продолжить подготовку"), action: prepare).buttonStyle(StudioPrimaryButtonStyle())
                }
            }.padding(32).frame(maxWidth: 1180).frame(maxWidth: .infinity)
        }
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .task(id: isPreparing) {
            guard isPreparing, preparationFrames.isEmpty else { return }
            let source = workspace.job?.url ?? result.outputURL
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            for index in 0..<8 {
                guard !Task.isCancelled else { return }
                let duration = workspace.job?.durationSeconds ?? result.duration
                let time = duration * (0.07 + Double(index) * 0.115)
                if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)), !Task.isCancelled {
                    preparationFrames.append(NSImage(cgImage: frame.image, size: .zero))
                }
            }
        }
        .sheet(item: $editingShort) { short in
            if let source = workspace.job?.url, let transcript = workspace.storedTranscript ?? workspace.currentProject?.transcript {
                EssayShortEditorView(short: short, result: result, transcript: transcript, sourceURL: source) { edited in
                    try await workspace.rebuildEssayShort(edited, settings: settings)
                }
            }
        }
    }

    private var preparationStep: Int {
        switch workspace.essayShortPreparationPhase {
        case .idle, .loadingModel, .planning: return 0
        case .rendering(let index): return index
        case .ready: return 4
        }
    }

    private var preparationHeadline: String {
        switch workspace.essayShortPreparationPhase {
        case .idle, .loadingModel: return L10n.tr("Открываем монтажную.")
        case .planning: return L10n.tr("Весь фильм.\nСильнейшие моменты.")
        case .rendering(1): return L10n.tr("Первый сюжет\nобретает форму.")
        case .rendering(3): return L10n.tr("Сильные кадры.\nРитм музыки.")
        case .rendering: return L10n.tr("Собираем\nвторой ракурс.")
        case .ready: return L10n.tr("Два сюжета и эдит. Готово.")
        }
    }

    private var preparationWorkspace: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                HStack(spacing: 8) {
                    Circle().fill(StudioTheme.accent).frame(width: 6, height: 6)
                    Text(L10n.tr("МОНТАЖНАЯ В РАБОТЕ")).font(.system(size: 10, weight: .bold)).tracking(1.8)
                }.foregroundStyle(StudioTheme.accent)
                Spacer()
                Text(workspace.essayShortPreparationStartedAt ?? preparationStartedAt, style: .timer)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.muted)
                    .accessibilityLabel(L10n.tr("Время подготовки"))
            }
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(preparationHeadline).font(.system(size: 34, weight: .medium, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.isEmpty ? L10n.tr("Ищем сцены во всём фильме.") : status)
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.muted)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Image(systemName: "film.stack")
                        Text(result.arc.movieTitle).fontWeight(.bold)
                        Text(L10n.tr("· весь фильм"))
                    }.font(.caption).foregroundStyle(StudioTheme.accent)
                    if !preparationEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(preparationEvents.suffix(3).enumerated()), id: \.offset) { index, event in
                                Label(event, systemImage: index == preparationEvents.suffix(3).count - 1 ? "arrow.turn.down.right" : "checkmark")
                                    .font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.top, 6)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(preparationStartedAt)
                    HStack(spacing: 16) {
                        preparationPoster(index: 0, elapsed: elapsed)
                        preparationPoster(index: 1, elapsed: elapsed)
                        preparationPoster(index: 2, elapsed: elapsed)
                    }
                }.accessibilityElement(children: .combine)
            }
            Divider().overlay(StudioTheme.line)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array([L10n.tr("Подбор"), L10n.tr("Шортс 01"), L10n.tr("Шортс 02"), L10n.tr("Эдит 03"), L10n.tr("Выпуск готов")].enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(index <= preparationStep ? StudioTheme.accent.opacity(0.15) : StudioTheme.raised)
                            if index < preparationStep {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            } else if index == preparationStep {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                            } else { Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)) }
                        }.frame(width: 30, height: 30).foregroundStyle(index <= preparationStep ? StudioTheme.accent : StudioTheme.muted)
                        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(index <= preparationStep ? .primary : .secondary)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity)
                }
            }
            Text(L10n.tr("Кадры из фильма · выбранные сцены появятся после подбора"))
                .font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
        }.studioPanel(padding: 28)
    }

    private func preparationPoster(index: Int, elapsed: Double) -> some View {
        let frameIndex = preparationFrames.isEmpty ? 0 : (Int(max(0, elapsed) / 4) + index * 3) % preparationFrames.count
        let short = release?.shorts.indices.contains(index) == true ? release?.shorts[index] : nil
        let ready = short?.outputURL != nil
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                StudioTheme.background
                if preparationFrames.indices.contains(frameIndex) {
                    ZStack {
                        Image(nsImage: preparationFrames[frameIndex]).resizable().scaledToFill()
                            .frame(width: 152, height: 270).blur(radius: 14).opacity(0.35).clipped()
                        Image(nsImage: preparationFrames[frameIndex]).resizable().scaledToFit()
                            .frame(width: 152, height: 152).offset(y: -12)
                    }.id(frameIndex).transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.15), .clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                if !reduceMotion {
                    Rectangle().fill(LinearGradient(colors: [.clear, StudioTheme.accent.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1).offset(y: CGFloat((elapsed.truncatingRemainder(dividingBy: 3) / 3) * 250 - 125))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(format: "%02d", index + 1)).font(.system(size: 12, weight: .bold, design: .monospaced))
                        Spacer()
                        Text("9:16").font(.system(size: 9, design: .monospaced))
                    }.foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(index == 2 ? L10n.tr("ЭДИТ 03") : (index == 0 ? L10n.tr("СЦЕНА 01") : L10n.tr("СЦЕНА 02")))
                        .font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(StudioTheme.accent)
                    Text(short?.hook ?? result.arc.movieTitle)
                        .font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(.white)
                        .lineLimit(4)
                }.padding(13)
            }.frame(width: 152, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(StudioTheme.accent.opacity(preparationStep == index + 1 ? 0.7 : 0.25)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: frameIndex)
            Label(ready ? L10n.tr("Сохранён") : (short == nil ? L10n.tr("Выбор истории") : L10n.tr("Монтаж и субтитры")),
                  systemImage: ready ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 10)).foregroundStyle(ready ? StudioTheme.success : StudioTheme.muted)
        }
    }

    private func shortCard(_ short: EssayShort, index: Int, release: EssayRelease) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(short.isMontage ? L10n.tr("03 / МУЗЫКАЛЬНЫЙ ЭДИТ") : (index == 0 ? L10n.tr("01 / МОМЕНТ ФИЛЬМА") : L10n.tr("02 / МОМЕНТ ФИЛЬМА")))
                    .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(StudioTheme.accent)
                Spacer()
                Text(L10n.tr("9:16 · %1$@ с", String(describing: Int(short.duration.rounded())))).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.muted)
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
                    Text(L10n.tr("%1$@ сцен · %2$@", String(describing: short.segments.count), String(describing: short.showsSubtitles ? L10n.tr("субтитры включены") : L10n.tr("без субтитров")))).font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { editingShort = short } label: {
                Label(L10n.tr("Редактировать шортс"), systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large)
                .disabled(preparing || workspace.isWorkingOnEssayRelease || !EssayShortEditing.canEdit(short, in: release))
            if !EssayShortEditing.canEdit(short, in: release) {
                Text(L10n.tr("Уже отправлялся на площадки. Статусы сохранены на шаге «Постинг»."))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            DisclosureGroup(L10n.tr("Почему выбрана эта сцена")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(short.why)
                    Text(short.question).bold()
                    if !short.payoffQuote.isEmpty { Text("«\(short.payoffQuote)»") }
                    if let montage = short.montagePlan {
                        Text(L10n.tr("Визуально проверено планов: %1$@ · музыкальных склеек: %2$@", String(montage.shots.count), String(montage.cutTimes?.count ?? 0)))
                    }
                    if let visual = short.visualEvidence {
                        let retained = visual.retainedSampleCount(in: short.segments)
                        Text(L10n.tr("Визуальные пробы исходной сцены: %1$@/5 · уверенность %2$@%", String(describing: visual.score), String(describing: Int(visual.confidence * 100))))
                        Text(visual.observation)
                        Text(L10n.tr("Три кадра: ") + visual.sampledTimes.map { String(format: L10n.tr("%.1f с"), $0) }.joined(separator: ", "))
                        if retained < visual.sampledTimes.count {
                            Label(L10n.tr("В текущем монтаже осталось проб: %1$@ из %2$@. Оценка относится к исходной сцене; изменённые границы повторно не проверялись.", String(describing: retained), String(describing: visual.sampledTimes.count)),
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            Text(L10n.tr("Все пробы входят в текущий монтаж. Добавленный за пределами исходной сцены материал ими не проверен."))
                        }
                        Text(L10n.tr("Это оценка отдельных кадров, а не полного движения и звука сцены."))
                    } else {
                        Text(L10n.tr("Визуальные пробы не проверялись: выбор основан на диалогах."))
                    }
                }.font(.caption).foregroundStyle(StudioTheme.muted).padding(.top, 6)
            }.font(.system(size: 12))
        }.frame(maxWidth: .infinity, alignment: .leading).studioPanel()
    }

    private func prepare() {
        prepare(forceReplan: false)
    }

    private func prepare(forceReplan: Bool) {
        guard !isPreparing else { return }
        OperationJournal.shared.begin(L10n.tr("Подготовка двух шортсов"))
        preparationStartedAt = Date()
        preparationEvents = []
        preparing = true; error = nil
        Task { @MainActor in
            defer { preparing = false }
            let report: @MainActor (String) -> Void = { message in
                OperationJournal.shared.append(message)
                status = message
                if preparationEvents.last != message { preparationEvents.append(message) }
            }
            do {
                if forceReplan {
                    try await workspace.generateEssayRelease(modelManager: modelManager, settings: settings, progress: report)
                } else {
                    try await workspace.prepareEssayRelease(modelManager: modelManager, settings: settings, progress: report)
                }
            }
            catch { self.error = error.localizedDescription; OperationJournal.shared.append(error.localizedDescription, level: .error) }
        }
    }
}
