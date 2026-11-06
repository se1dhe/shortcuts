import SwiftUI
import AppKit
import AVKit

struct YouTubeShortsView: View {
    @Bindable var library: ShortsLibrary
    @State private var film = "Все фильмы"
    @State private var category = "сильные диалоги"
    @State private var filter = "Все"
    @State private var confirmPublish = false
    @State private var preview: DiscoveredShort?
    private let categories = ["сильные диалоги", "эдиты", "культовые сцены"]
    private var visible: [DiscoveredShort] {
        library.cards.filter { filter == "Все" || (filter == "Готовые" ? $0.status == .ready : $0.status == .published) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Шортсы").font(.system(size: 28, weight: .bold))
                    Text("Зарубежное кино · русский звук · диалоги и эдиты").foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button("Подключить TikTok", systemImage: "person.crop.circle") {
                    Task { await library.connectTikTok() }
                }.disabled(library.busy)
            }
            publicationGuide
            HStack {
                Picker("Фильм", selection: $film) {
                    Text("Все фильмы").tag("Все фильмы")
                    ForEach(ShortsDiscoveryService.films, id: \.self) { Text($0).tag($0) }
                }.frame(width: 260)
                Picker("Подборка", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.frame(width: 240)
                Button("Найти ещё", systemImage: "sparkle.magnifyingglass") {
                    Task { await library.discover(film: film, category: category) }
                }.buttonStyle(.borderedProminent).disabled(library.busy || !library.storageAvailable)
                Spacer()
                Picker("Показать", selection: $filter) {
                    ForEach(["Все", "Готовые", "Опубликованные"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 160)
            }
            HStack(spacing: 12) {
                if library.busy { ProgressView().controlSize(.small) }
                Text(library.message.isEmpty ? "Посмотрите источник и подтвердите: русский звук, зарубежный фильм. Затем обработайте и выберите готовые ролики." : library.message)
                    .font(.callout).textSelection(.enabled)
                Spacer()
            }.padding(12).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                if visible.isEmpty {
                    ContentUnavailableView("Найдём сильные сцены", systemImage: "play.rectangle.on.rectangle", description: Text("Выберите фильм и нажмите «Найти ещё». Здесь появятся карточки YouTube Shorts."))
                        .frame(maxWidth: .infinity).padding(.top, 70)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 380))], alignment: .leading, spacing: 18) {
                    ForEach(visible) { card in shortCard(card) }
                }
            }
            HStack {
                Text("Выбрано готовых: \(library.selectedReady.count)").foregroundStyle(StudioTheme.muted)
                Spacer()
                Button("Опубликовать в @telonyx_cinema", systemImage: "paperplane.fill") { confirmPublish = true }
                    .buttonStyle(StudioPrimaryButtonStyle())
                    .disabled(library.busy || library.selectedReady.isEmpty || !library.storageAvailable || !library.hasTargetTikTok)
            }
        }.padding(28)
        .task {
            if library.tikTokAuth == nil { await library.refreshTikTok() }
            if library.cards.isEmpty && library.storageAvailable { await library.discover(film: film, category: category) }
        }
        .confirmationDialog("Опубликовать \(library.selectedReady.count) роликов в TikTok @telonyx_cinema?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("Опубликовать публично") { Task { await library.publishSelected() } }
        } message: {
            Text("Приложение откроет Chrome, загрузит выбранные MP4, заполнит подписи и само нажмёт «Опубликовать». Ролики станут публичными. Если TikTok попросит проверку, завершите её в Chrome.")
        }
        .sheet(item: $preview) { card in
            ShortsPreviewView(card: card)
        }
    }

    private var publicationGuide: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(library.accountMessage, systemImage: library.hasTargetTikTok ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(library.hasTargetTikTok ? StudioTheme.success : StudioTheme.warning)
                Spacer()
                Button("Проверить аккаунт") { Task { await library.refreshTikTok() } }.disabled(library.busy)
            }
            Text("1. Подключите @telonyx_cinema → 2. Обработайте ролики и отметьте «Выбрать для TikTok» → 3. Нажмите «Опубликовать» внизу.")
                .font(.caption).foregroundStyle(StudioTheme.muted)
            DisclosureGroup("Как работает публикация") {
                Text("Для входа откроется отдельное окно Chrome. Войдите в нужный аккаунт и закройте это окно — вход сохранится. После подтверждения публикации приложение само загрузит выбранные файлы, заполнит подписи, дождётся проверок TikTok и нажмёт «Опубликовать». Во время загрузки оставьте Chrome открытым. В карточке появится ссылка на опубликованный ролик. Если результата нет, сначала проверьте профиль, чтобы не отправить дубль.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }.font(.caption)
        }.studioPanel(padding: 12)
    }

    private func shortCard(_ card: DiscoveredShort) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: card.thumbnailURL) { image in image.resizable().scaledToFill() } placeholder: {
                    Rectangle().fill(StudioTheme.raised).overlay { Image(systemName: "film") }
                }.frame(height: 190).clipped()
                Text("\(card.duration > 0 ? "\(Int(card.duration)) сек" : "Shorts") · \(card.views.formatted()) просмотров")
                    .font(.caption.bold()).padding(7).background(.black.opacity(0.75)).padding(8)
            }.clipShape(RoundedRectangle(cornerRadius: 10))
            Text(card.title).font(.headline).lineLimit(3).frame(height: 52, alignment: .topLeading)
            Text("\(card.film) · \(card.channel)").font(.caption).foregroundStyle(StudioTheme.muted).lineLimit(1)
            Text(card.status.title).font(.caption.bold()).foregroundStyle(card.status == .published ? StudioTheme.success : StudioTheme.accent)
            Link("Смотреть источник на YouTube ↗", destination: card.sourceURL)
            if card.status == .discovered {
                Button("Убрать из подборки", systemImage: "xmark") { library.dismiss(card.id) }.font(.caption)
                Toggle("Проверено: русский звук, зарубежный фильм", isOn: field(card, \.reviewed)).font(.caption)
                if card.duration > 0 { HStack {
                    Text("Отрезок, сек").font(.caption)
                    TextField("С", value: field(card, \.start), format: .number).frame(width: 60)
                    Text("—")
                    TextField("До", value: field(card, \.end), format: .number).frame(width: 60)
                }.textFieldStyle(.roundedBorder) }
                Button("Обработать + водяной знак", systemImage: "wand.and.stars") { Task { await library.process(card.id) } }
                    .disabled(!card.reviewed || library.busy || !library.storageAvailable)
            }
            if let path = card.outputPath, FileManager.default.fileExists(atPath: path) {
                HStack {
                    Button("Результат", systemImage: "play.fill") { preview = card }
                    Button("Файл", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
            TextField("Подпись TikTok", text: field(card, \.caption), axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            if card.status == .ready {
                Button(card.hasCurrentWatermark ? "Обработать заново" : "Обновить водяной знак", systemImage: "keyboard") {
                    Task { await library.process(card.id) }
                }.font(.caption).disabled(library.busy)
                if !card.hasCurrentWatermark {
                    Text("Обновите оформление: печатная машинка, JetBrains Mono, снизу, 50% прозрачности.").font(.caption).foregroundStyle(StudioTheme.warning)
                }
                DisclosureGroup("Загрузить в TikTok вручную") {
                    Text("Откройте TikTok Studio в своём браузере, выберите @telonyx_cinema, загрузите MP4 и вставьте подпись.").font(.caption)
                    Button("Скопировать подпись") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.caption, forType: .string)
                    }
                    Link("Открыть TikTok Studio ↗", destination: URL(string: "https://www.tiktok.com/tiktokstudio/upload")!)
                }.font(.caption)
            }
            if card.canPublish {
                Toggle("Выбрать для TikTok", isOn: Binding(get: { library.selected.contains(card.id) }, set: { value in
                    if value { library.selected.insert(card.id) } else { library.selected.remove(card.id) }
                }))
            }
            if let address = card.publishedURL, let url = URL(string: address) { Link("Открыть в TikTok ↗", destination: url) }
            if let issue = card.issue { Text(issue).font(.caption).foregroundStyle(StudioTheme.warning).textSelection(.enabled) }
            if card.status == .needsReview {
                Button("Проверил TikTok — ролик не опубликован") {
                    library.update(card.id) { $0.status = .ready; $0.issue = nil }
                }.font(.caption)
            }
        }.studioPanel(padding: 14).disabled(library.busy)
    }

    private func field<T>(_ card: DiscoveredShort, _ key: WritableKeyPath<DiscoveredShort, T>) -> Binding<T> {
        Binding(get: { library.cards.first(where: { $0.id == card.id })?[keyPath: key] ?? card[keyPath: key] },
                set: { value in library.update(card.id) { $0[keyPath: key] = value } })
    }
}

private struct ShortsPreviewView: View {
    let card: DiscoveredShort
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        VStack {
            HStack { Text(card.title).lineLimit(1); Spacer(); Button("Закрыть") { dismiss() } }
            VideoPlayer(player: player)
        }.padding().frame(width: 450, height: 740)
            .onAppear { if let path = card.outputPath { player = AVPlayer(url: URL(fileURLWithPath: path)); player?.play() } }
            .onDisappear { player?.pause(); player = nil }
    }
}
