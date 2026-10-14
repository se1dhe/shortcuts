import Foundation
import AppKit

/// Shared helper service for exporting clips and copying content to pasteboard.
@MainActor
enum ClipExportHelper {

    /// Prompts the user with an NSSavePanel and exports the clip with active enhancement options.
    static func downloadClip(
        _ clip: ShortClip,
        settings: AppSettings
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = clip.suggestedFileName
        panel.canCreateDirectories = true
        panel.title = String(localized: "Download short")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let enhance = VideoEnhancementOptions(
                    preset: clip.videoEnhancementPreset,
                    rifeFrameRate: clip.videoEnhancementRifeFPS,
                    realesrganScale: clip.videoEnhancementScale,
                    sharpness: clip.videoEnhancementSharpness,
                    contrast: clip.videoEnhancementContrast,
                    saturation: clip.videoEnhancementSaturation,
                    bitrateMbps: clip.videoEnhancementBitrate)
                await clip.export(
                    to: destination,
                    workingDirectory: settings.workingDirectory,
                    customMusicDirectory: settings.customMusicDirectory,
                    enhancementOptions: enhance)
            }
        }
    }

    /// Copies given text string to the macOS general pasteboard.
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
