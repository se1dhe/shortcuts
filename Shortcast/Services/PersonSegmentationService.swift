import Foundation
import AVFoundation
import Vision
import CoreImage

/// Generates person segmentation mattes using Apple's Vision framework
/// to allow cinematic subtitles to be placed with depth behind the actor.
struct PersonSegmentationService {

    /// Generates a grayscale silhouette matte where the actor is white (1.0) and the background is black (0.0).
    static func generateActorMask(from cgImage: CGImage) async -> CGImage? {
        if #available(macOS 12.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                guard let maskPixelBuffer = request.results?.first?.pixelBuffer else { return nil }
                let ciMask = CIImage(cvPixelBuffer: maskPixelBuffer)
                let context = CIContext(options: nil)
                return context.createCGImage(ciMask, from: ciMask.extent)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Determines if a frame has a prominent foreground actor suitable for depth compositing.
    static func hasProminentForegroundActor(in cgImage: CGImage, minAreaFraction: CGFloat = 0.12) async -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        let faces = request.results ?? []
        return faces.contains { ($0.boundingBox.width * $0.boundingBox.height) >= minAreaFraction }
    }
}
