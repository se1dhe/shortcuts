import AVFoundation
import CoreMedia
import Foundation
import Observation

/// Video is kept on a muted AVPlayer; the corresponding PCM is sent through
/// MontageScenePreviewAudio so AVPlayer never opens its unstable audio queue.
enum MontageVideoPreviewPlayer {
    static func makeVideoOnlyPlayer(url: URL) -> AVPlayer {
        let player = AVPlayer(playerItem: makeVideoOnlyItem(url: url))
        player.isMuted = true
        return player
    }

    static func makeVideoOnlyItem(url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        // Muting does not prevent AVPlayer from opening an AudioQueue. Give it
        // an asset that physically contains no audio tracks.
        let video = AVMutableComposition()
        if let source = asset.tracks(withMediaType: .video).first,
           let track = video.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: source, at: .zero)
            track.preferredTransform = source.preferredTransform
        }
        return AVPlayerItem(asset: video)
    }
}

/// Decodes the selected audition range to PCM and plays it through the Mac's
/// mixer format. Keep the audio engine alive between previews; repeatedly
/// creating/stopping AVPlayer audio queues is what caused CoreAudio to abort.
@MainActor
final class MontageScenePreviewAudio {
    struct PCMChunk: Sendable {
        let bytes: Data
        let frameCount: AVAudioFrameCount
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat

    init() {
        let mixer = engine.mainMixerNode
        // On this Mac the hardware is 48 kHz while the main mixer input is
        // 44.1 kHz. Connecting with the hardware format causes AVFAudio to
        // throw an Objective-C exception. Use the destination bus's format.
        format = mixer.inputFormat(forBus: 0)
        engine.attach(node)
        engine.connect(node, to: mixer, format: format)
    }

    func prepare(url: URL, start: Double, end: Double) async throws -> [PCMChunk] {
        let sampleRate = format.sampleRate
        return try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw PreviewError.noAudioTrack
            }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: max(0, start), preferredTimescale: 600),
                duration: CMTime(seconds: max(0.1, end - start), preferredTimescale: 600)
            )
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw PreviewError.cannotReadAudio }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? PreviewError.cannotReadAudio
            }

            var chunks: [PCMChunk] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                let byteCount = CMBlockBufferGetDataLength(block)
                guard frames > 0, byteCount >= Int(frames) * 2 * MemoryLayout<Float>.size else { continue }
                var bytes = Data(count: byteCount)
                let status = bytes.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                    guard let base = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                    return CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: base.assumingMemoryBound(to: Int8.self)
                    )
                }
                guard status == kCMBlockBufferNoErr else { throw PreviewError.cannotReadAudio }
                chunks.append(PCMChunk(bytes: bytes, frameCount: frames))
            }
            guard !chunks.isEmpty else {
                throw reader.error ?? PreviewError.emptyAudioRange
            }
            return chunks
        }.value
    }

    func play(_ chunks: [PCMChunk]) throws {
        node.stop()
        for chunk in chunks {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameCount) else {
                throw PreviewError.cannotReadAudio
            }
            buffer.frameLength = chunk.frameCount
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self),
                  buffers[0].mDataByteSize >= chunk.frameCount * UInt32(MemoryLayout<Float>.size),
                  buffers[1].mDataByteSize >= chunk.frameCount * UInt32(MemoryLayout<Float>.size) else {
                throw PreviewError.cannotReadAudio
            }
            chunk.bytes.withUnsafeBytes { source in
                guard let samples = source.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for frame in 0..<Int(chunk.frameCount) {
                    left[frame] = samples[frame * 2]
                    right[frame] = samples[frame * 2 + 1]
                }
            }
            node.scheduleBuffer(buffer)
        }
        if !engine.isRunning { try engine.start() }
        node.play()
    }

    func setVolume(_ volume: Float) { node.volume = max(0, min(1, volume)) }

    func pause() { node.pause() }

    func resume() { node.play() }

    func stop() {
        node.stop()
    }

    func shutdown() {
        node.stop()
        if engine.isRunning { engine.stop() }
    }

    private enum PreviewError: LocalizedError {
        case noAudioTrack
        case cannotReadAudio
        case emptyAudioRange

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: L10n.stored("В исходном фильме не найдена аудиодорожка.")
            case .cannotReadAudio: L10n.stored("Не удалось декодировать звук выбранного фрагмента.")
            case .emptyAudioRange: L10n.stored("В выбранном диапазоне фильма нет доступного звука.")
            }
        }
    }
}

// MARK: - Sequence playback and source-time mapping

struct EditorTimelinePosition: Equatable {
    let index: Int
    let id: UUID
    let sourceTime: Double
    let sequenceTime: Double
}

enum EditorTimelineMapping {
    static func duration(_ clips: [EditorTimelineClip]) -> Double {
        clips.reduce(0) { $0 + $1.duration }
    }

    static func position(at seconds: Double, clips: [EditorTimelineClip]) -> EditorTimelinePosition? {
        let total = duration(clips)
        guard seconds.isFinite, total > 0 else { return nil }
        let time = min(total, max(0, seconds))
        var cursor = 0.0
        for (index, clip) in clips.enumerated() where clip.duration > 0 {
            let end = cursor + clip.duration
            if time < end || index == clips.count - 1 {
                return .init(index: index, id: clip.id,
                    sourceTime: clip.start + min(clip.duration, max(0, time - cursor)), sequenceTime: time)
            }
            cursor = end
        }
        return nil
    }

    static func sequenceTime(sourceTime: Double, clipID: UUID, clips: [EditorTimelineClip]) -> Double? {
        guard sourceTime.isFinite else { return nil }
        var cursor = 0.0
        for clip in clips {
            if clip.id == clipID { return cursor + min(clip.duration, max(0, sourceTime - clip.start)) }
            cursor += clip.duration
        }
        return nil
    }
}

/// The playhead follows AVPlayer's actual source clock. UUIDs disambiguate
/// repeated source ranges, and a fresh request always replaces an older seek.
@MainActor @Observable
final class MontageTimelinePlayback {
    private(set) var player: AVPlayer?
    private(set) var currentTime = 0.0
    private(set) var activeClipID: UUID?
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    var error: String?
    let audio = MontageScenePreviewAudio()
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var clips: [EditorTimelineClip] = []
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var seekRequest = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var rangeEnd: Double?
    @ObservationIgnored private var followsSequence = false

    func open(url: URL, clips: [EditorTimelineClip]) {
        close()
        sourceURL = url; self.clips = clips
        let next = MontageVideoPreviewPlayer.makeVideoOnlyPlayer(url: url)
        player = next
        observer = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self, weak next] time in
            MainActor.assumeIsolated {
                guard let self, self.player === next else { return }
                self.tick(sourceTime: time.seconds)
            }
        }
        seekFrame(to: 0)
    }

    func setClips(_ updated: [EditorTimelineClip]) {
        guard updated != clips else { return }
        let sourceTime = player?.currentTime().seconds ?? 0
        let id = activeClipID
        pause()
        clips = updated
        let time = id.flatMap { EditorTimelineMapping.sequenceTime(sourceTime: sourceTime, clipID: $0, clips: updated) }
            ?? min(currentTime, EditorTimelineMapping.duration(updated))
        seekFrame(to: time)
    }

    func select(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }),
              let time = EditorTimelineMapping.sequenceTime(sourceTime: clip.start, clipID: id, clips: clips) else { return }
        pause(); seekFrame(to: time)
    }

    func toggle() {
        if isPlaying { pause() }
        else {
            let time = currentTime >= EditorTimelineMapping.duration(clips) - 0.02 ? 0 : currentTime
            play(at: time)
        }
    }

    func scrub(to time: Double, editing: Bool) {
        if editing, !scrubbing {
            resumeAfterScrub = isPlaying
            pause(); scrubbing = true
        }
        if !editing, scrubbing {
            scrubbing = false
            let resume = resumeAfterScrub
            resumeAfterScrub = false
            if resume { play(at: time) } else { seekFrame(to: time) }
        } else {
            if !editing, isPlaying { play(at: time); return }
            if !editing { pause() }
            seekFrame(to: time)
        }
    }

    func audition(start: Double, end: Double, preferredID: UUID? = nil) {
        guard start.isFinite, end.isFinite, end > start else { return }
        let clip = clips.first { $0.id == preferredID && start >= $0.start - 0.01 && start < $0.end }
            ?? clips.first { start >= $0.start - 0.01 && start < $0.end }
        guard let clip, let time = EditorTimelineMapping.sequenceTime(sourceTime: start, clipID: clip.id, clips: clips) else { return }
        play(at: time, stopAt: min(end, clip.end))
    }

    func pause() {
        request = UUID(); task?.cancel(); task = nil
        seekRequest = UUID(); seekTask?.cancel(); seekTask = nil
        player?.pause(); player?.currentItem?.cancelPendingSeeks(); audio.stop()
        isPlaying = false; isPreparing = false; isSeeking = false
    }

    func close() {
        pause(); scrubbing = false; resumeAfterScrub = false
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.replaceCurrentItem(with: nil); player = nil
        audio.shutdown()
    }

    private func seekFrame(to time: Double) {
        guard let position = EditorTimelineMapping.position(at: time, clips: clips), let player else { return }
        currentTime = position.sequenceTime; activeClipID = position.id
        let token = UUID(); seekRequest = token
        seekTask?.cancel(); player.currentItem?.cancelPendingSeeks(); isSeeking = true
        seekTask = Task { @MainActor in
            _ = await player.seek(to: CMTime(seconds: position.sourceTime, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.04, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.04, preferredTimescale: 600))
            guard self.seekRequest == token else { return }
            self.isSeeking = false
        }
    }

    private func play(at time: Double, stopAt: Double? = nil) {
        guard let position = EditorTimelineMapping.position(at: time, clips: clips),
              let player, let sourceURL else { return }
        pause()
        let clip = clips[position.index]
        let end = stopAt ?? clip.end
        guard end - position.sourceTime > 0.02 else { return }
        currentTime = position.sequenceTime; activeClipID = clip.id
        rangeEnd = end; followsSequence = stopAt == nil
        let token = UUID(); request = token
        isPreparing = true; isPlaying = true; error = nil
        task = Task { @MainActor in
            do {
                let pcm = try await audio.prepare(url: sourceURL, start: position.sourceTime, end: end)
                guard !Task.isCancelled, request == token else { return }
                let finished = await player.seek(to: CMTime(seconds: position.sourceTime, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.02, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.02, preferredTimescale: 600))
                guard !Task.isCancelled, request == token else { return }
                guard finished else { pause(); self.error = L10n.stored("Не удалось перейти к выбранному кадру."); return }
                try audio.play(pcm)
                isPreparing = false
                player.play()
            } catch {
                guard request == token else { return }
                pause(); self.error = error.localizedDescription
            }
        }
    }

    private func tick(sourceTime: Double) {
        guard !scrubbing, !isSeeking, !isPreparing, let id = activeClipID,
              let time = EditorTimelineMapping.sequenceTime(sourceTime: sourceTime, clipID: id, clips: clips) else { return }
        currentTime = time
        guard isPlaying, let end = rangeEnd, sourceTime >= end - 0.05,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if followsSequence, index + 1 < clips.count {
            let next = clips.prefix(index + 1).reduce(0) { $0 + $1.duration }
            play(at: next)
        } else {
            pause()
        }
    }
}
