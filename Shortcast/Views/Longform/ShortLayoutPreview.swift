import SwiftUI
import AVFoundation
import AppKit

struct ShortLayoutPreview: View {
    let sourceURL: URL
    let short: EssayShort
    let result: LongformBuildResult
    @Environment(\.dismiss) private var dismiss
    @State private var opening: NSImage?
    @State private var clean: NSImage?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text(L10n.tr("Оформление шортса")).font(.title2.bold()); Spacer(); Button(L10n.tr("Закрыть")) { dismiss() } }
            HStack(spacing: 24) {
                sample(opening, title: L10n.tr("Первые 2 секунды"))
                sample(clean, title: L10n.tr("Основная часть"))
            }
            Text(short.showsSubtitles ? L10n.tr("Субтитры включены и появятся во время реплик.") : L10n.tr("Субтитры выключены. В основной части остаётся только логотип.")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(L10n.tr(error)).foregroundStyle(.red) }
        }.padding(24).frame(width: 680, height: 710)
        .task {
            do {
                let source = AVURLAsset(url: sourceURL)
                let candidate = try await ShortBrandArtwork.coverCandidate(source: source, ranges: short.segments)
                let card = try ShortBrandArtwork.openingCard(result: result)
                @MainActor func render(cardVisible: Bool) throws -> NSImage {
                    let image = try ShortBrandArtwork.draw { context in
                        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1080, height: 1920))
                        let band = CGRect(x: 0, y: 560, width: 1080, height: 1000)
                        let scale = max(band.width / CGFloat(candidate.image.width), band.height / CGFloat(candidate.image.height))
                        let width = CGFloat(candidate.image.width) * scale, height = CGFloat(candidate.image.height) * scale
                        let face = candidate.faceBox?.midX ?? 0.5
                        let x = min(0, max(1080 - width, 540 - face * width))
                        context.saveGState(); context.clip(to: band)
                        context.draw(candidate.image, in: CGRect(x: x, y: band.minY - (height - band.height) / 2, width: width, height: height))
                        context.restoreGState()
                        ChannelLogo.composite(in: context, rect: CGRect(x: 28, y: 590, width: 112, height: 112), opacity: CGFloat(ChannelLogoStyle.essay.opacity))
                        if cardVisible { context.draw(card, in: CGRect(x: 0, y: 0, width: 1080, height: 1920)) }
                    }
                    return NSImage(cgImage: image, size: CGSize(width: 1080, height: 1920))
                }
                opening = try render(cardVisible: true); clean = try render(cardVisible: false)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func sample(_ image: NSImage?, title: String) -> some View {
        VStack {
            Text(title).font(.headline)
            if let image { Image(nsImage: image).resizable().aspectRatio(9/16, contentMode: .fit) }
            else { ProgressView().frame(width: 285, height: 507) }
        }.frame(width: 285)
    }
}
