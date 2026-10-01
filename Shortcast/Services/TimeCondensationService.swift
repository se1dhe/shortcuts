import Foundation
import AVFoundation

struct CondensedSegment: Sendable {
    let timeRange: CMTimeRange
    let needsCrossfade: Bool
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
        let totalDuration = segments.last?.end ?? 0.0
        
        for i in 1..<segments.count {
            let nextSegment = segments[i]
            let gap = nextSegment.start - currentEnd
            
            // Linear acceleration towards the end (up to 50% faster pacing in the punchline act)
            let progress = totalDuration > 0 ? min(max(0.0, currentEnd / totalDuration), 1.0) : 0.0
            let adjustedMaxPause = maxPause * (1.0 - (progress * 0.5))
            
            if gap > adjustedMaxPause {
                // Gap is too large: commit current range with subtle natural padding
                let expandedEnd = currentEnd + (adjustedMaxPause / 2.0)
                let safeEnd = max(currentStart + 0.05, expandedEnd)
                rangesToKeep.append(CMTimeRange(
                    start: CMTime(seconds: currentStart, preferredTimescale: 600),
                    duration: CMTime(seconds: safeEnd - currentStart, preferredTimescale: 600)
                ))
                
                // Start next range
                currentStart = max(currentStart, nextSegment.start - (adjustedMaxPause / 2.0))
                currentEnd = max(currentStart + 0.05, nextSegment.end)
            } else {
                // Merge into current range, handling potential overlapping transcripts
                currentEnd = max(currentEnd, nextSegment.end)
            }
        }
        
        // Append the final range
        let finalEnd = max(currentStart + 0.05, currentEnd + 0.1)
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
