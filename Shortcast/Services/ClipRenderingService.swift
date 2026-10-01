import Foundation
import AVFoundation

@MainActor
struct ClipRenderingService {
    
    static func renderAndCaption(
        clip: ShortClip,
        jobURL: URL,
        transcript: Transcript,
        captionLanguage: String?,
        modelManager: ModelManager,
        settings: AppSettings,
        transcription: TranscriptionService,
        boundaryDetector: SentenceBoundaryDetecting = SentenceBoundaryDetector()
    ) async throws {
        FontDownloadService.shared.registerBundledFonts()
        clip.stage = .cutting
        let condensedRanges: [CMTimeRange]
        
        // MARK: - Phase 5.4: Cinema defaults are independent from app settings.
        if clip.isCinemaMode {
            clip.burnSubtitles = true
            clip.reframeEnabled = true
            clip.overlayEnabled = false
            // Ensure cinema appearance stays cinemaPremium with mood profile intact
            clip.subtitleAppearance = SubtitleAppearance.cinemaPremium
            clip.subtitleAppearance.moodProfile = clip.candidate.mood
        }
        
        var clipRanges = clip.candidate.segments ?? []
        if clipRanges.isEmpty {
            clipRanges = [TimeSegment(start: clip.candidate.start, end: clip.candidate.end)]
        }
        
        // MARK: - Phase 5.5: Reject defective short clips (<10.0s) or expand dialogue boundaries
        let initialDuration = clipRanges.reduce(0) { $0 + $1.duration }
        if initialDuration < 10.0 {
            ShortClip.log("Clip candidate initial duration is \(initialDuration)s (< 10.0s threshold). Attempting dialogue expansion...")
            let curStart = clipRanges.first?.start ?? clip.candidate.start
            let curEnd = clipRanges.last?.end ?? clip.candidate.end
            let expanded = expandDialogueBoundaries(
                currentStart: curStart,
                currentEnd: curEnd,
                transcript: transcript,
                minTargetDuration: 40.0,
                maxAllowedDuration: 58.0
            )
            let expandedDuration = max(expanded.end - expanded.start, 0)
            if expandedDuration >= 10.0 {
                ShortClip.log("Successfully expanded dialogue boundaries from \(initialDuration)s to \(expandedDuration)s [\(expanded.start)...\(expanded.end)]")
                clipRanges = [TimeSegment(start: expanded.start, end: expanded.end)]
            } else {
                ShortClip.log("REJECTED DEFECT: Scene duration (\(expandedDuration)s) is strictly under 10.0s. Aborting render of defective arc.")
                throw CinemaDefectError.sceneTooShort(duration: expandedDuration, threshold: 10.0)
            }
        }
        
        var speechTuples: [(start: Double, end: Double)] = []
        for range in clipRanges {
            let inside = transcript.segments.filter { tSeg in
                tSeg.end > range.start && tSeg.start < range.end
            }
            if !inside.isEmpty {
                // Filter micro-stutter fragments (< 0.35s)
                let validSegments = inside.filter { ($0.end - $0.start) >= 0.35 }
                speechTuples.append(contentsOf: validSegments.map { (start: $0.start, end: $0.end) })
            } else {
                speechTuples.append((start: range.start, end: range.end))
            }
        }
        speechTuples.sort { $0.start < $1.start }
        
        // Remove trailing truncated word fragments at the very tail of the clip (e.g. 0.5s glitch like "ОБАВНО")
        if speechTuples.count > 1, let last = speechTuples.last, let prev = speechTuples.dropLast().last {
            if (last.end - last.start) < 1.0 && (last.start - prev.end) > 1.2 {
                speechTuples.removeLast()
            }
        }
        
        let mood = clip.candidate.mood ?? .default
        let rawRanges: [CMTimeRange]
        if clipRanges.count == 1, let singleRange = clipRanges.first {
            // For continuous scenes (clipRanges.count == 1):
            // Treat the candidate scene as a continuous shot unless there are extreme silence pauses (> 2.5s)
            let hasExtremePause = (1..<speechTuples.count).contains { i in
                (speechTuples[i].start - speechTuples[i - 1].end) > 2.5
            }
            if !hasExtremePause {
                let start = max(0, singleRange.start)
                let duration = max(0.01, singleRange.end - start)
                rawRanges = [CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                )]
            } else if speechTuples.count > 1 {
                rawRanges = TimeCondensationService.condenseTime(segments: speechTuples, mood: mood)
            } else {
                let start = max(0, singleRange.start)
                let duration = max(0.01, singleRange.end - start)
                rawRanges = [CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                )]
            }
        } else if speechTuples.count > 1 {
            rawRanges = TimeCondensationService.condenseTime(segments: speechTuples, mood: mood)
        } else if let first = speechTuples.first {
            rawRanges = [CMTimeRange(
                start: CMTime(seconds: max(0, first.start - 0.05), preferredTimescale: 600),
                duration: CMTime(seconds: max(0.01, first.end - max(0, first.start - 0.05) + 0.1), preferredTimescale: 600)
            )]
        } else {
            let start = max(0, clipRanges.first?.start ?? clip.candidate.start)
            let end = clipRanges.last?.end ?? clip.candidate.end
            rawRanges = [CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.01, end - start), preferredTimescale: 600)
            )]
        }
        
        // Allow highly condensed dynamic Jump Cuts! Do NOT fallback to uncompressed scene.
        let safeRawRanges = rawRanges
        
        // Strict boundary: Cap total condensed duration to maximum 58.0s for Shorts/Reels retention
        var cappedRanges: [CMTimeRange] = []
        var runningSeconds: Double = 0
        let maxAllowedSeconds: Double = 58.0
        for range in safeRawRanges {
            let rangeSec = range.duration.seconds
            if runningSeconds + rangeSec <= maxAllowedSeconds {
                cappedRanges.append(range)
                runningSeconds += rangeSec
            } else {
                let remaining = maxAllowedSeconds - runningSeconds
                let cutLimit = range.start.seconds + remaining
                if let safeEnd = boundaryDetector.findPreviousSentenceEnd(before: cutLimit, in: transcript.segments),
                   safeEnd > (range.start.seconds + 5.0) {
                    cappedRanges.append(CMTimeRange(
                        start: range.start,
                        duration: CMTime(seconds: safeEnd - range.start.seconds, preferredTimescale: 600)
                    ))
                } else if remaining > 5.0 {
                    cappedRanges.append(CMTimeRange(
                        start: range.start,
                        duration: CMTime(seconds: remaining, preferredTimescale: 600)
                    ))
                }
                break
            }
        }
        condensedRanges = cappedRanges.isEmpty ? safeRawRanges : cappedRanges
        
        let clipURL: URL
        if condensedRanges.count > 1 {
            clipURL = try await VideoTrimmer.stitch(videoURL: jobURL, segments: condensedRanges)
            
            let asset = AVURLAsset(url: clipURL)
            let newDuration = try? await asset.load(.duration)
            clip.clipJob = VideoJob(url: clipURL, durationSeconds: CMTimeGetSeconds(newDuration ?? .zero))
            
            // Re-transcribing stitched clip for perfect subtitle sync...
            let newTranscript = try await transcription.transcript(for: clipURL, languageHint: settings.languageOverride)
            clip.subtitleSegments = newTranscript.segments.map {
                SubtitleSegment(start: $0.start, end: $0.end, text: $0.text, words: $0.words)
            }
            
            clip.variants = []
        } else {
            let segStart: Double = (condensedRanges.first.map { CMTimeGetSeconds($0.start) }) ?? clip.candidate.start
            let segDuration: Double = (condensedRanges.first.map { CMTimeGetSeconds($0.duration) }) ?? clip.candidate.duration
            clipURL = try await VideoTrimmer.trim(
                videoURL: jobURL,
                startSeconds: segStart,
                endSeconds: segStart + segDuration)
            clip.clipJob = VideoJob(url: clipURL, durationSeconds: segDuration)

            // Re-align subtitle segments to the trimmed start boundary
            let mappedSegs = transcript.segments
                .filter { $0.end > segStart && $0.start < (segStart + segDuration) }
                .map { seg in
                    let wordTimings = seg.words.map {
                        WordTimestamp(
                            word: $0.word,
                            start: max(0, $0.start - segStart),
                            end: max(0, $0.end - segStart)
                        )
                    }
                    return SubtitleSegment(
                        start: max(0, seg.start - segStart),
                        end: max(0, seg.end - segStart),
                        text: seg.text.trimmed,
                        words: wordTimings
                    )
                }
            if !mappedSegs.isEmpty {
                clip.subtitleSegments = mappedSegs
            }
        }
        
        // Final sanity check on rendered clip duration
        let finalJobDuration = clip.clipJob?.durationSeconds ?? 0
        guard finalJobDuration >= 10.0 else {
            ShortClip.log("REJECTED DEFECT: Final clip duration (\(finalJobDuration)s) is under 10.0s. Aborting render.")
            throw CinemaDefectError.sceneTooShort(duration: finalJobDuration, threshold: 10.0)
        }
        
        clip.isLandscape = await VerticalReframer.isLandscape(url: clipURL)
        
        let sampleTime = min(2.0, clip.clipJob?.durationSeconds ?? 2.0)
        if let framing = await extractFraming(from: clipURL, at: sampleTime) {
            clip.subtitleAppearance.safeTextZoneNorm = framing.safeTextZoneNorm
            clip.subtitleAppearance.verticalPosition = 0.72
            if framing.safeTextZoneNorm.width > 0.5 {
                clip.subtitleAppearance.horizontalAlign = "center"
            } else {
                clip.subtitleAppearance.horizontalAlign = framing.textOnLeft ? "left" : "right"
            }
        }
        
        let hasCondensation = condensedRanges.count > 1
        if !clip.candidate.variants.isEmpty && !hasCondensation {
            clip.variants = clip.candidate.variants
            clip.detectedLanguage = captionLanguage
            clip.stage = .ready
        } else {
            clip.stage = .captioning
            let result = try await generateCaption(
                clip: clip,
                modelManager: modelManager,
                settings: settings,
                transcriptLanguage: captionLanguage)
            clip.applyGeneratedCopy(result, detectedLanguage: result.detectedLanguage)
            clip.stage = .ready
        }
    }
    
    static func generateCaption(
        clip: ShortClip,
        modelManager: ModelManager,
        settings: AppSettings,
        transcriptLanguage: String?
    ) async throws -> GenerationResult {
        let effectiveLanguage = settings.languageOverride.trimmed.isEmpty
            ? (transcriptLanguage ?? "")
            : settings.languageOverride
        
        switch settings.copywriterModel {
        case .gemmaE4B:
            guard let engine = modelManager.engine, let clipJob = clip.clipJob else {
                throw MomentFinderError.notReady
            }
            return try await GemmaService.generate(
                job: clipJob,
                engine: engine,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples,
                videoTitle: clip.sourceMetadata?.title ?? "",
                videoDescription: clip.sourceMetadata?.description ?? "")
        case .gemma12B, .qwen35_9b:
            await modelManager.prepareDirector(profile: settings.copywriterModel.directorProfile)
            return try await modelManager.momentFinder.caption(
                transcriptSlice: clip.transcriptSlice,
                hook: clip.candidate.hook,
                languageOverride: effectiveLanguage,
                styleExamples: settings.styleExamples,
                videoTitle: clip.sourceMetadata?.title ?? "",
                videoDescription: clip.sourceMetadata?.description ?? "")
        }
    }

    // MARK: - Dialogue Expansion (Phase 5.5)
    
    /// Expands dialogue boundaries up to the nearest complete phrase in the scene
    /// so the dramatic arc meets the 40.0–58.0s quality threshold without cutting mid-sentence.
    private static func expandDialogueBoundaries(
        currentStart: Double,
        currentEnd: Double,
        transcript: Transcript,
        minTargetDuration: Double = 40.0,
        maxAllowedDuration: Double = 58.0
    ) -> (start: Double, end: Double) {
        let sorted = transcript.segments.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return (currentStart, currentEnd) }
        
        var start = currentStart
        var end = currentEnd
        
        var startIdx = sorted.lastIndex { $0.start <= currentStart } ?? 0
        var endIdx = sorted.firstIndex { $0.end >= currentEnd } ?? (sorted.count - 1)
        
        start = min(start, sorted[startIdx].start)
        end = max(end, sorted[endIdx].end)
        
        var canExpandForward = true
        var canExpandBackward = true
        
        while (end - start) < minTargetDuration && (canExpandForward || canExpandBackward) {
            // Expand forward (dialogue continuation / punchline)
            if canExpandForward && endIdx + 1 < sorted.count {
                let nextSeg = sorted[endIdx + 1]
                let pause = nextSeg.start - sorted[endIdx].end
                if pause <= 8.0 && (nextSeg.end - start) <= maxAllowedDuration {
                    endIdx += 1
                    end = nextSeg.end
                } else {
                    canExpandForward = false
                }
            } else {
                canExpandForward = false
            }
            
            if (end - start) >= minTargetDuration { break }
            
            // Expand backward (hook / escalation context)
            if canExpandBackward && startIdx > 0 {
                let prevSeg = sorted[startIdx - 1]
                let pause = sorted[startIdx].start - prevSeg.end
                if pause <= 8.0 && (end - prevSeg.start) <= maxAllowedDuration {
                    startIdx -= 1
                    start = prevSeg.start
                } else {
                    canExpandBackward = false
                }
            } else {
                canExpandBackward = false
            }
        }
        
        return (start: start, end: end)
    }

    nonisolated private static func extractFraming(from clipURL: URL, at seconds: Double) async -> CinemaSquareReframer.FaceCompositionInfo? {
        let asset = AVURLAsset(url: clipURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
        return await CinemaSquareReframer.analyzeFraming(image: cgImage)
    }
}

/// Domain-specific errors for quality rejection of defective video clips.
enum CinemaDefectError: LocalizedError {
    case sceneTooShort(duration: Double, threshold: Double)
    
    var errorDescription: String? {
        switch self {
        case .sceneTooShort(let duration, let threshold):
            return "Отбракован: длительность фрагмента (\(String(format: "%.1f", duration))с) меньше допустимого порога качества (\(String(format: "%.1f", threshold))с). Брак драматургической арки."
        }
    }
}
