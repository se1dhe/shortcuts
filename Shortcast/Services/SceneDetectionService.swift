import Foundation
import AVFoundation
import CoreImage
import Accelerate

/// Detects scene boundaries in a video by analyzing frame histograms.
/// Used to provide CinemaMomentDirector with scene-level context so it
/// can pick COMPLETE scenes instead of random cross-cut fragments.
struct SceneDetectionService {
    
    struct SceneBoundary: Sendable {
        let timestamp: Double      // seconds
        let confidence: Double     // 0.0-1.0 how strong the scene change is
    }
    
    struct Scene: Sendable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }
    
    /// Analyzes the video at the given URL and returns detected scene boundaries.
    /// Uses histogram comparison between consecutive frames.
    ///
    /// - Parameters:
    ///   - url: Video file URL
    ///   - threshold: Histogram difference threshold (0.0-1.0). Default 0.3
    ///   - sampleRate: How many frames per second to analyze. Default 2.0
    /// - Returns: Array of detected scenes (start-end pairs in seconds)
    static func detectScenes(
        in url: URL,
        threshold: Double = 0.3,
        sampleRate: Double = 2.0
    ) async throws -> [Scene] {
        let asset = AVURLAsset(url: url)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }
        
        let assetReader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 90
        ]
        
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        assetReader.add(trackOutput)
        assetReader.startReading()
        
        var scenes: [Scene] = []
        var lastSceneStart: Double = 0
        var previousHistogram: [Float]?
        
        let sampleInterval = CMTime(seconds: 1.0 / sampleRate, preferredTimescale: 600)
        var nextSampleTime = CMTime.zero
        let duration = try await asset.load(.duration).seconds
        
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if presentationTime < nextSampleTime {
                continue
            }
            
            nextSampleTime = presentationTime + sampleInterval
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            
            let currentHistogram = computeHistogram(for: pixelBuffer)
            
            if let prev = previousHistogram {
                let diff = computeL1Distance(hist1: prev, hist2: currentHistogram)
                
                // Normalizing diff (max diff is approx 160*90 * 3) -> adjust logic based on normalization
                let maxDiff: Float = 160.0 * 90.0 * 3.0
                let normalizedDiff = Double(diff / maxDiff)
                
                if normalizedDiff > threshold {
                    let currentTime = presentationTime.seconds
                    scenes.append(Scene(start: lastSceneStart, end: currentTime))
                    lastSceneStart = currentTime
                }
            }
            
            previousHistogram = currentHistogram
        }
        
        if lastSceneStart < duration {
            scenes.append(Scene(start: lastSceneStart, end: duration))
        }
        
        return scenes
    }
    
    private static func computeHistogram(for pixelBuffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        
        var histogram = [Float](repeating: 0, count: 256 * 3)
        
        for y in 0..<height {
            let rowData = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = rowData.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                let b = Int(pixel[0])
                let g = Int(pixel[1])
                let r = Int(pixel[2])
                
                histogram[r] += 1
                histogram[256 + g] += 1
                histogram[512 + b] += 1
            }
        }
        
        return histogram
    }
    
    private static func computeL1Distance(hist1: [Float], hist2: [Float]) -> Float {
        guard hist1.count == hist2.count, !hist1.isEmpty else { return 0 }
        
        var diff = [Float](repeating: 0, count: hist1.count)
        vDSP_vsub(hist1, 1, hist2, 1, &diff, 1, vDSP_Length(hist1.count))
        
        var absDiff = [Float](repeating: 0, count: hist1.count)
        vDSP_vabs(diff, 1, &absDiff, 1, vDSP_Length(hist1.count))
        
        var sum: Float = 0
        vDSP_sve(absDiff, 1, &sum, vDSP_Length(hist1.count))
        
        return sum
    }
    
    struct SuperBlock: Sendable {
        let id: Int
        let start: Double
        let end: Double
        let sceneCount: Int
        let cutCount: Int
        var duration: Double { end - start }
        var cutRatePerMinute: Double { (Double(cutCount) / max(duration, 1.0)) * 60.0 }
    }
    
    /// Clusters adjacent detected scenes into ~90-120s semantic super-blocks with cut-rate metadata.
    static func clusterIntoSuperBlocks(scenes: [Scene], targetDuration: Double = 120.0) -> [SuperBlock] {
        guard !scenes.isEmpty else { return [] }
        var blocks: [SuperBlock] = []
        var currentStart = scenes[0].start
        var currentEnd = scenes[0].end
        var currentScenes = 1
        var blockId = 1

        for i in 1..<scenes.count {
            let nextScene = scenes[i]
            let accumulatedDuration = nextScene.end - currentStart
            if accumulatedDuration > targetDuration && currentScenes >= 2 {
                blocks.append(SuperBlock(
                    id: blockId,
                    start: currentStart,
                    end: currentEnd,
                    sceneCount: currentScenes,
                    cutCount: currentScenes - 1
                ))
                blockId += 1
                currentStart = nextScene.start
                currentEnd = nextScene.end
                currentScenes = 1
            } else {
                currentEnd = nextScene.end
                currentScenes += 1
            }
        }
        blocks.append(SuperBlock(
            id: blockId,
            start: currentStart,
            end: currentEnd,
            sceneCount: currentScenes,
            cutCount: max(0, currentScenes - 1)
        ))
        return blocks
    }
    
    /// Formats detected scenes and super-blocks into a text context string for the LLM prompt.
    static func formatForPrompt(scenes: [Scene], transcriptDuration: Double) -> String {
        let superBlocks = clusterIntoSuperBlocks(scenes: scenes, targetDuration: 120.0)
        var prompt = "Super-Blocks & Scene Map (total \(Int(transcriptDuration))s):\n"
        for block in superBlocks {
            let startStr = String(format: "%.1f", block.start)
            let endStr = String(format: "%.1f", block.end)
            let durStr = String(format: "%.0f", block.duration)
            let rateStr = String(format: "%.1f", block.cutRatePerMinute)
            prompt += "• Block #\(block.id): \(startStr)-\(endStr)s (\(durStr)s, \(block.sceneCount) shots, \(rateStr) cuts/min)\n"
        }
        return prompt
    }
}
