import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies a cinematic "Teal & Orange" / Dark Sigma color grade to a video.
enum CinemaColorGradingService {
    
    enum GradingError: LocalizedError {
        case trackNotFound
        case exportFailed
        var errorDescription: String? {
            switch self {
            case .trackNotFound: return "Video track not found."
            case .exportFailed: return "Export failed."
            }
        }
    }
    
    /// Renders a new video with the cinematic color grade applied.
    static func applyCinematicGrade(
        to videoURL: URL,
        outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw GradingError.trackNotFound
        }
        
        let composition = AVMutableComposition()
        // INSERT THE ENTIRE ASSET TO PRESERVE EXACT TIMING (EDTS / B-FRAMES)
        let duration = try await asset.load(.duration)
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: .zero)
        guard let _ = try await composition.loadTracks(withMediaType: .video).first else {
            throw GradingError.trackNotFound
        }
        
        // Setup CoreImage filter composition
        let filterHandler: @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void = { request in
            let source = request.sourceImage
            
            // 1. Color Controls (Darker, more contrast, slightly saturated)
            let colorFilter = CIFilter.colorControls()
            colorFilter.inputImage = source
            colorFilter.brightness = -0.04   // Darker / Sigma vibe
            colorFilter.contrast = 1.08      // Punchy
            colorFilter.saturation = 1.15    // Richer colors
            
            // 2. Exposure Adjust (Crush highlights slightly)
            let exposureFilter = CIFilter.exposureAdjust()
            exposureFilter.inputImage = colorFilter.outputImage
            exposureFilter.ev = -0.2
            
            let finalImage = exposureFilter.outputImage ?? source
            request.finish(with: finalImage, context: nil)
        }

        let videoComposition: AVMutableVideoComposition
        nonisolated(unsafe) let safeAsset = composition
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) {
            videoComposition = try await AVMutableVideoComposition.videoComposition(with: safeAsset, applyingCIFiltersWithHandler: filterHandler)
        } else {
            videoComposition = AVMutableVideoComposition(asset: safeAsset, applyingCIFiltersWithHandler: filterHandler)
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = naturalSize.applying(transform)
        videoComposition.renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        videoComposition.frameDuration = try await videoTrack.load(.minFrameDuration)
        
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw GradingError.exportFailed
        }
        
        exportSession.videoComposition = videoComposition
        
        do {
            try await exportSession.export(to: outputURL, as: .mp4)
        } catch {
            throw GradingError.exportFailed
        }
    }
}
