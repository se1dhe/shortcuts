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
    
    struct Scene: Codable, Sendable, Equatable {
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
        sampleRate: Double = 2.0,
        range: TimeSegment? = nil,
        spatialThreshold: Double? = nil
    ) async throws -> [Scene] {
        let asset = AVURLAsset(url: url)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }
        
        let assetReader = try AVAssetReader(asset: asset)
        let assetDuration = try await asset.load(.duration).seconds
        let analysisStart = max(0, range?.start ?? 0)
        let analysisEnd = min(assetDuration, range?.end ?? assetDuration)
        guard analysisEnd > analysisStart, sampleRate > 0 else { return [] }
        assetReader.timeRange = CMTimeRange(start: CMTime(seconds: analysisStart, preferredTimescale: 600),
            end: CMTime(seconds: analysisEnd, preferredTimescale: 600))
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 90
        ]
        
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        assetReader.add(trackOutput)
        assetReader.startReading()
        defer { assetReader.cancelReading() }
        
        var scenes: [Scene] = []
        var lastSceneStart = analysisStart
        var previousHistogram: [Float]?
        var previousThumbnail: [UInt8]?
        
        let sampleInterval = CMTime(seconds: 1.0 / sampleRate, preferredTimescale: 600)
        var nextSampleTime = CMTime(seconds: analysisStart, preferredTimescale: 600)
        let duration = analysisEnd
        
        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if presentationTime < nextSampleTime {
                continue
            }
            
            nextSampleTime = presentationTime + sampleInterval
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            
            let currentHistogram = computeHistogram(for: pixelBuffer)
            let thumbnail = spatialThreshold == nil ? nil : computeThumbnail(for: pixelBuffer)
            
            if let prev = previousHistogram {
                let diff = computeL1Distance(hist1: prev, hist2: currentHistogram)
                
                // Readers may ignore requested buffer dimensions. Normalize
                // by the actual sampled pixel count, not an assumed 160×90.
                let maxDiff = max(1, currentHistogram.reduce(0, +))
                let normalizedDiff = Double(diff / maxDiff)
                
                let spatialDiff: Double
                if let thumbnail, let previousThumbnail, thumbnail.count == previousThumbnail.count {
                    spatialDiff = zip(thumbnail, previousThumbnail).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                        / Double(max(1, thumbnail.count) * 255)
                } else { spatialDiff = 0 }
                if normalizedDiff > threshold || spatialThreshold.map({ spatialDiff > $0 }) == true {
                    let currentTime = presentationTime.seconds
                    scenes.append(Scene(start: lastSceneStart, end: currentTime))
                    lastSceneStart = currentTime
                }
            }
            
            previousHistogram = currentHistogram
            previousThumbnail = thumbnail
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
        
        for y in stride(from: 0, to: height, by: max(1, height / 90)) {
            let rowData = baseAddress.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: max(1, width / 160)) {
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

    /// Layout changes can be a hard cut even when the palette is identical
    /// (e.g. reverse shots in the same room). Compare a small spatial grid too.
    private static func computeThumbnail(for pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var bytes: [UInt8] = []; bytes.reserveCapacity(32 * 18 * 3)
        for y in 0..<18 {
            for x in 0..<32 {
                let pixel = base.advanced(by: min(height - 1, y * height / 18) * stride
                    + min(width - 1, x * width / 32) * 4).assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: [pixel[0], pixel[1], pixel[2]])
            }
        }
        return bytes
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
