import SwiftUI

/// The long-video pipeline progress screen. Shows the source video in a
/// cinematic, aspect-correct frame (no weird phone crop for horizontal video)
/// with a sweeping "scanner" and a filmstrip that lights up cell by cell — so it
/// reads as the AI watching the timeline and cutting the best moments.
struct FilmAnalysisProgressView: View {

    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        let tracker = workspace.progressTracker
        let isAnalyzing = tracker.currentStage == .analyzingStory
        let isTranscribing = tracker.currentStage == .transcribing

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeading(isAnalyzing: isAnalyzing)

                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            if let url = workspace.job?.url {
                                CinematicScanner(url: url)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                            } else {
                                previewPlaceholder
                                    .aspectRatio(16 / 9, contentMode: .fit)
                            }
                            movieCaption
                        }
                        .frame(maxWidth: .infinity)

                        progressPanel(
                            tracker: tracker,
                            isAnalyzing: isAnalyzing,
                            isTranscribing: isTranscribing
                        )
                        .frame(width: 350)
                    }
                    .padding(18)
                    .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(StudioTheme.line))

                    HStack(spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(StudioTheme.accent)
                        Text(isAnalyzing
                             ? "Director сравнивает диалоги и собирает доказательный план по актам. Это может занять несколько минут."
                             : "Сначала извлекаем реплики из фильма, затем Director соберёт тему и план сцен.")
                            .font(.callout)
                            .foregroundStyle(StudioTheme.muted)
                        Spacer(minLength: 12)
                        Button(role: .cancel) {
                            workspace.cancelPipeline()
                        } label: {
                            Label("Отменить", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 1320)
                .padding(.horizontal, 30)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .studioSurface()
    }

    private func pageHeading(isAnalyzing: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Label("СТУДИЯ · ЭССЕ", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .bold)).tracking(1.8)
                    .foregroundStyle(StudioTheme.accent)
                Text(isAnalyzing ? "Ищем историю внутри фильма" : "Готовим фильм к разбору")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Сцены, тема и аргумент будущего кино-эссе")
                    .font(.system(size: 14)).foregroundStyle(StudioTheme.muted)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(StudioTheme.accent).frame(width: 7, height: 7)
                Text(isAnalyzing ? "DIRECTOR РАБОТАЕТ" : "АНАЛИЗ ФИЛЬМА")
                    .font(.system(size: 10, weight: .bold)).tracking(1.2)
            }
            .foregroundStyle(StudioTheme.accent)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(StudioTheme.accent.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(StudioTheme.accent.opacity(0.18)))
        }
        .padding(.horizontal, 4)
    }

    private var movieCaption: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 42, height: 42)
                .background(StudioTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(movieTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(workspace.job?.fileName ?? "Исходный фильм")
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let movie = workspace.detectedMovie {
                if let imdb = movie.imdbRating, !imdb.isEmpty {
                    Label(imdb, systemImage: "star.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.accent)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var movieTitle: String {
        guard let movie = workspace.detectedMovie,
              !MovieMetadataService.isGarbageTitle(movie.title) else {
            return workspace.job?.effectiveTitle ?? "Новый фильм"
        }
        return movie.year.isEmpty ? movie.title : "\(movie.title) · \(movie.year)"
    }

    private var previewPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(StudioTheme.raised)
            VStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(StudioTheme.accent)
                Text("Подготавливаем изображение")
                    .font(.callout.weight(.medium)).foregroundStyle(StudioTheme.muted)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func progressPanel(
        tracker: PipelineProgressTracker,
        isAnalyzing: Bool,
        isTranscribing: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isAnalyzing ? "ШАГ 02 ИЗ 03 · DIRECTOR" : "ШАГ 01 ИЗ 03 · ДИАЛОГИ")
                        .font(.system(size: 10, weight: .bold)).tracking(1.2)
                        .foregroundStyle(StudioTheme.muted)
                    Text(isAnalyzing ? "План эссе" : "Транскрипция")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: isAnalyzing ? "sparkles" : "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(StudioTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(isAnalyzing ? "Собираем смысл" : tracker.statusMessage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 0)
                    if isTranscribing {
                        Text("\(Int(tracker.stageProgress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(StudioTheme.accent)
                    }
                }
                if isAnalyzing {
                    IndeterminateProgressBar()
                        .frame(height: 5)
                } else {
                    ProgressView(value: tracker.stageProgress, total: 1)
                        .progressViewStyle(.linear).tint(StudioTheme.accent)
                }
                Text(isAnalyzing
                     ? "Модель сопоставляет реплики с темой и распределяет сцены по актам."
                     : tracker.detailedMetrics)
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                progressStep(number: "01", title: "Источник и диалоги", state: isAnalyzing ? .complete : .active,
                             detail: isAnalyzing ? "Материал готов" : "Извлекаем реплики")
                stepConnector
                progressStep(number: "02", title: "Тема и сцены", state: isAnalyzing ? .active : .upcoming,
                             detail: isAnalyzing ? "Director строит план по актам" : "Следующий этап")
                stepConnector
                progressStep(number: "03", title: "Монтаж эссе", state: .upcoming,
                             detail: "После подтверждения плана")
            }

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(StudioTheme.accent)
                Text(tracker.formattedETA == "Вычисление..."
                     ? "Время зависит от скорости модели"
                     : "Осталось \(tracker.formattedETA)")
                    .foregroundStyle(StudioTheme.muted)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(StudioTheme.line))
    }

    private enum StepState { case complete, active, upcoming }

    private func progressStep(number: String, title: String, state: StepState, detail: String) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(state == .upcoming ? StudioTheme.panel : StudioTheme.accent.opacity(0.12))
                if state == .complete {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(StudioTheme.success)
                } else if state == .active {
                    Circle().fill(StudioTheme.accent).frame(width: 7, height: 7)
                } else {
                    Text(number).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(StudioTheme.muted)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state == .upcoming ? StudioTheme.muted : .white.opacity(0.92))
                Text(detail).font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
            }
            Spacer(minLength: 0)
            if state == .active {
                ProgressView().controlSize(.small).tint(StudioTheme.accent)
            }
        }
        .frame(minHeight: 48)
    }

    private var stepConnector: some View {
        HStack {
            Capsule().fill(StudioTheme.line).frame(width: 1, height: 13).padding(.leading, 11.5)
            Spacer()
        }
    }
}

// MARK: - Cinematic scanner

private struct CinematicScanner: View {
    let url: URL
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)

                PhoneVideoPlayer(url: url, gravity: .resizeAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                // Subtle cinematic vignette.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.black.opacity(0.35), .clear, .black.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom))

                // Sweeping scanner line.
                LinearGradient(
                    colors: [.clear, StudioTheme.accent.opacity(0.9), .clear],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: 90)
                    .blur(radius: 6)
                    .offset(x: sweep ? (w / 2 - 45) : -(w / 2 - 45))
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: sweep)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                CornerBrackets()
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .padding(12)

                // "Live" badge.
                VStack {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                            .opacity(sweep ? 1 : 0.3)
                        Text("АНАЛИЗ ФИЛЬМА")
                            .font(.system(size: 10, weight: .heavy)).kerning(1.5)
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    Spacer()
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(StudioTheme.accent.opacity(sweep ? 0.9 : 0.25), lineWidth: 2)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: sweep))
        }
        .onAppear { sweep = true }
    }
}

/// Four L-shaped corner marks, like a camera's framing guides.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height) * 0.07
        let corners = [
            (rect.minX, rect.minY, 1.0, 1.0),
            (rect.maxX, rect.minY, -1.0, 1.0),
            (rect.minX, rect.maxY, 1.0, -1.0),
            (rect.maxX, rect.maxY, -1.0, -1.0),
        ]
        for (x, y, sx, sy) in corners {
            p.move(to: CGPoint(x: x + len * sx, y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + len * sy))
        }
        return p
    }
}

// MARK: - Indeterminate model progress

/// Story analysis has no measurable fraction yet; show motion without inventing a percentage.
private struct IndeterminateProgressBar: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geometry in
                let width = geometry.size.width * 0.34
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [StudioTheme.accent.opacity(0.35), StudioTheme.accent, StudioTheme.accent.opacity(0.35)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: width)
                        .offset(x: (geometry.size.width - width) * phase)
                }
                .clipShape(Capsule())
            }
        }
    }
}
