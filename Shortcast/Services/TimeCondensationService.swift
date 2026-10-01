import Foundation
import AVFoundation

struct CondensedSegment: Sendable {
    let timeRange: CMTimeRange
    let needsCrossfade: Bool

    init(timeRange: CMTimeRange, needsCrossfade: Bool) {
        self.timeRange = timeRange
        self.needsCrossfade = needsCrossfade
    }
}

/// Service responsible for conversational pacing and silence condensation in viral shorts.
/// Compresses dead-air pauses between spoken sentences based on Whisper timestamps and cinematic mood profiles.
struct TimeCondensationService: Sendable {
    
    /// Compresses silence between segments in a clip to maintain the specified maximum pause duration.
    /// Returns the condensed time ranges of the original video to keep.
    static func condenseTime(
        segments: [(start: Double, end: Double)],
        mood: CinematicMoodProfile
    ) -> [CMTimeRange] {
        guard !segments.isEmpty else { return [] }
        
        let maxPause = max(0.06, mood.mood.timeCondensationPauseMs / 1000.0) // seconds
        var rangesToKeep: [CMTimeRange] = []
        
        var currentStart = segments[0].start
        var currentEnd = segments[0].end
        let clipStart = segments.first?.start ?? 0.0
        let clipEnd = segments.last?.end ?? clipStart
        let totalDuration = max(clipEnd - clipStart, 0.01)
        
        for i in 1..<segments.count {
            let nextSegment = segments[i]
            let gap = nextSegment.start - currentEnd
            
            // Linear acceleration towards the end (up to 50% faster pacing in the punchline act)
            let progress = min(max(0.0, (currentEnd - clipStart) / totalDuration), 1.0)
            let adjustedMaxPause = maxPause * (1.0 - (progress * 0.5))
            
            // Natural conversational pauses in dialogue (< 1.4s) must NEVER be cut!
            let minPauseThreshold = max(1.4, adjustedMaxPause)
            
            if gap > minPauseThreshold {
                // Gap is too large (dead air > 1.4s): commit current range with 0.30s room tone padding
                let expandedEnd = currentEnd + 0.30
                let safeEnd = max(currentStart + 0.05, expandedEnd)
                rangesToKeep.append(CMTimeRange(
                    start: CMTime(seconds: currentStart, preferredTimescale: 600),
                    duration: CMTime(seconds: safeEnd - currentStart, preferredTimescale: 600)
                ))
                
                // Start next range with 0.20s room tone padding before speech
                currentStart = max(safeEnd, nextSegment.start - 0.20)
                currentEnd = max(currentStart + 0.05, nextSegment.end)
            } else {
                // Natural dialogue pause (<= 1.4s): merge into current range
                currentEnd = max(currentEnd, nextSegment.end)
            }
        }
        
        // Append the final range with 0.45s tail padding to prevent cutting decaying consonants
        let finalEnd = max(currentStart + 0.05, currentEnd + 0.45)
        rangesToKeep.append(CMTimeRange(
            start: CMTime(seconds: currentStart, preferredTimescale: 600),
            duration: CMTime(seconds: finalEnd - currentStart, preferredTimescale: 600)
        ))
        
        return rangesToKeep
    }
    
    /// Compresses silence between speech segments to maintain optimal pacing.
    /// Returns segments with time ranges ready for video stitching.
    static func condenseTimeWithAudio(
        segments: [(start: Double, end: Double)],
        audioURL: URL? = nil,
        mood: CinematicMoodProfile
    ) async throws -> [CondensedSegment] {
        let ranges = condenseTime(segments: segments, mood: mood)
        return ranges.map { CondensedSegment(timeRange: $0, needsCrossfade: false) }
    }
}
