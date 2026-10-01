import SwiftUI
import AVFoundation
import AppKit

/// Manual trim UI: a thumbnail filmstrip of the clip with two draggable in/out
/// handles, the selected span highlighted, live timecodes, and a preview frame
/// at the moved handle. Writes back into `trimStart` / `trimEnd` (seconds).
struct ClipTrimEditor: View {

    let videoURL: URL
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double

    @State private var thumbnails: [NSImage] = []
    @State private var previewFrame: NSImage?
    @State private var previewTime: Double = 0
    @State private var frameTask: Task<Void, Never>?

    private let handleWidth: CGFloat = 12
    private let trackHeight: CGFloat = 56
    private let minGap: Double = 0.5
    private static let trackSpace = "trimTrack"

    private var effectiveEnd: Double { trimEnd > 0 ? min(trimEnd, duration) : duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Trim", systemImage: "timeline.selection")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(timecode(trimStart)) – \(timecode(effectiveEnd))  ·  \(timecode(effectiveEnd - trimStart))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if trimStart > 0.05 || effectiveEnd < duration - 0.05 {
                    Button {
                        reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let previewFrame {
                Image(nsImage: previewFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        Text(timecode(previewTime))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
            }

            timeline
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .task(id: videoURL) {
            await loadThumbnails()
            if previewFrame == nil { await updatePreview(to: trimStart) }
        }
    }

    // MARK: - Timeline track

    private var timeline: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let startX = position(for: trimStart, width: w)
            let endX = position(for: effectiveEnd, width: w)

            ZStack(alignment: .leading) {
                filmstrip
                    .frame(width: w, height: trackHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Dim the trimmed-away regions.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, startX), height: trackHeight)
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, w - endX), height: trackHeight)
                    .offset(x: endX)

                // Selection border.
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: max(0, endX - startX), height: trackHeight)
                    .offset(x: startX)

                handle(at: startX, isStart: true, width: w)
                handle(at: endX, isStart: false, width: w)
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.trackSpace)
        }
        .frame(height: trackHeight)
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle().fill(.black.opacity(0.25))
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: trackHeight)
                        .clipped()
                }
            }
        }
    }

    private func handle(at x: CGFloat, isStart: Bool, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: trackHeight + 6)
            .overlay(
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: 2, height: trackHeight * 0.4))
            .offset(x: x - handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
                    .onChanged { value in
                        let t = time(forX: value.location.x, width: width)
                        if isStart {
                            trimStart = min(max(0, t), effectiveEnd - minGap)
                            schedulePreview(trimStart)
                        } else {
                            let newEnd = max(trimStart + minGap, min(t, duration))
                            trimEnd = newEnd
                            schedulePreview(newEnd)
                        }
                    })
    }

    // MARK: - Geometry helpers

    private func position(for time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private func time(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(max(0, min(x, width)) / width) * duration
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func reset() {
        trimStart = 0
        trimEnd = 0
        schedulePreview(0)
    }

    // MARK: - Frames

    private func schedulePreview(_ time: Double) {
        frameTask?.cancel()
        frameTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            await updatePreview(to: time)
        }
    }

    private func updatePreview(to time: Double) async {
        if let image = await Self.frame(from: videoURL, at: time) {
            previewFrame = image
            previewTime = time
        }
    }

    private func loadThumbnails() async {
        guard thumbnails.isEmpty, duration > 0 else { return }
        let count = 8
        var frames: [NSImage] = []
        for index in 0..<count {
            let t = duration * Double(index) / Double(count - 1)
            if let image = await Self.frame(from: videoURL, at: t, maxWidth: 160) {
                frames.append(image)
            }
        }
        thumbnails = frames
    }

    /// Extracts a single frame. Stays on the main actor so the resulting
    /// (non-Sendable) NSImage never crosses an actor boundary; the generator's
    /// own work happens off-thread while the call is suspended.
    @MainActor
    private static func frame(from url: URL, at seconds: Double, maxWidth: CGFloat = 480) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 2)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            if #available(macOS 13.0, *) {
                let (cgImage, _) = try await generator.image(at: time)
                return NSImage(cgImage: cgImage, size: .zero)
            } else {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                return NSImage(cgImage: cgImage, size: .zero)
            }
        } catch {
            return nil
        }
    }
}
