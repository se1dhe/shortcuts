import SwiftUI
import AppKit

enum StudioTheme {
    static let background = Color(hex: "101216")
    static let panel = Color(hex: "191C22")
    static let raised = Color(hex: "22262E")
    static let accent = Color(hex: "E8C582")
    static let muted = Color(hex: "9299A6")
    static let line = Color.white.opacity(0.08)
    static let success = Color(hex: "79C99E")
    static let warning = Color(hex: "E7AE68")
}

enum StudioStage: Int, CaseIterable, Identifiable {
    case film, essay, shorts, posting
    var id: Int { rawValue }
    @MainActor var title: String {
        switch self {
        case .film: L10n.tr("Фильм")
        case .essay: L10n.tr("Эссе")
        case .shorts: L10n.tr("Шортсы")
        case .posting: L10n.tr("Постинг")
        }
    }
    @MainActor var detail: String {
        switch self {
        case .film: L10n.tr("Источник и озвучка")
        case .essay: L10n.tr("Тема и монтаж")
        case .shorts: L10n.tr("Сильные моменты фильма")
        case .posting: L10n.tr("Выпуск на площадки")
        }
    }
    var symbol: String {
        switch self {
        case .film: "film"
        case .essay: "rectangle.stack"
        case .shorts: "scissors"
        case .posting: "paperplane"
        }
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(Color(hex: "221C11"))
            .background(StudioTheme.accent.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.6)
    }
}

extension View {
    func studioPanel(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StudioTheme.line))
    }

    func studioSurface() -> some View {
        self.background(StudioTheme.background)
            .preferredColorScheme(.dark)
            .tint(StudioTheme.accent)
    }
}

/// A stage clock, not an invented estimate: only confirmed work advances the rail.
struct StudioOperationProgress: View {
    let title: String
    let detail: String
    let stages: [String]
    let current: Int
    let started: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Label(L10n.tr("КАДР & СЕНС / В РАБОТЕ"), systemImage: "viewfinder")
                        .font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Spacer()
                    Text(Self.clock(context.date.timeIntervalSince(started)))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                }
                Text(title).font(.system(size: 34, weight: .medium, design: .serif))
                HStack(spacing: 6) {
                    ForEach(stages.indices, id: \.self) { index in
                        Capsule().fill(index <= current ? StudioTheme.accent : StudioTheme.raised)
                            .frame(height: 4)
                    }
                }
                ForEach(stages.indices, id: \.self) { index in
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(index == current ? StudioTheme.accent : StudioTheme.line, lineWidth: 1)
                                .frame(width: 30, height: 30)
                            if index < current {
                                Image(systemName: "checkmark").foregroundStyle(StudioTheme.success)
                            } else if index == current {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(String(format: "%02d", index + 1)).foregroundStyle(StudioTheme.muted)
                            }
                        }
                        Text(stages[index]).font(.system(size: 14, weight: index == current ? .semibold : .regular))
                            .foregroundStyle(index == current ? Color.primary : StudioTheme.muted)
                        Spacer()
                        if index == current { Text(L10n.tr("СЕЙЧАС")).font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent) }
                    }
                }
                Divider()
                Text(detail).font(.callout).foregroundStyle(StudioTheme.accent)
                    .frame(minHeight: 40, alignment: .topLeading)
                Text(L10n.tr("Готовый файл заменит предыдущую версию только после проверки. Время до завершения зависит от сложности монтажа."))
                    .font(.caption).foregroundStyle(StudioTheme.muted)
            }
            .padding(30).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(StudioTheme.accent.opacity(0.2)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: current)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}


/// Complete current-operation output, with user-controlled following and copying.
struct OperationLogPanel: View {
    @State private var entries: [OperationJournal.Entry] = []
    @State private var expanded = true
    @State private var followsTail = true
    private let journal: OperationJournal
    private let isActive: Bool
    init(journal: OperationJournal = .shared, isActive: Bool = true) {
        self.journal = journal
        self.isActive = isActive
        _entries = State(initialValue: journal.snapshot())
    }
    private var transcript: String {
        entries.map { "[\($0.time.formatted(date: .omitted, time: .standard))] [\($0.level.rawValue.uppercased())] \($0.message)" }
            .joined(separator: "\n")
    }
    private func color(_ level: OperationJournal.Level) -> Color {
        switch level {
        case .info: StudioTheme.muted
        case .warning: Color.yellow
        case .error: Color.red
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            expanded.toggle()
                        } label: {
                            Label(L10n.tr("Журнал действий · %1$@", String(describing: entries.count)), systemImage: expanded ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer()
                        Toggle(L10n.tr("Следить"), isOn: $followsTail).toggleStyle(.checkbox).font(.caption)
                        Button(L10n.tr("Копировать весь лог"), systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcript, forType: .string)
                        }.buttonStyle(.borderless).font(.caption)
                    }.foregroundStyle(StudioTheme.muted)
                    if expanded {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 7) {
                                    ForEach(entries) { event in
                                        HStack(alignment: .top, spacing: 14) {
                                            Text(event.time.formatted(date: .omitted, time: .standard))
                                                .foregroundStyle(StudioTheme.muted.opacity(0.6))
                                            Text(event.message).foregroundStyle(color(event.level))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }.id(event.id)
                                    }
                                }
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .tracking(0.3).textSelection(.enabled)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 190)
                            .background(Color(hex: "0C0E12"), in: RoundedRectangle(cornerRadius: 8))
                            .onChange(of: entries.last?.id) { _, id in
                                if followsTail, let id { proxy.scrollTo(id, anchor: .bottomLeading) }
                            }
                            .onChange(of: followsTail) { _, follow in
                                if follow, let id = entries.last?.id { proxy.scrollTo(id, anchor: .bottomLeading) }
                            }
                        }
                    }
                }.padding(14)
                    .background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.line))
                    .padding(.horizontal, 22).padding(.vertical, 12)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in expanded = active }
        .task {
            while !Task.isCancelled {
                let snapshot = journal.snapshot()
                if snapshot.last?.id != entries.last?.id { entries = snapshot }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}
