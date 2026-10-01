import Foundation
import AVFoundation

/// Scans the user-selected music directory and smartly selects an appropriate background track based on mood.
enum BackgroundMusicSelector {
    
    struct TrackMatch {
        let url: URL
        let score: Int
    }
    
    /// Finds the best background music track from the given directory, matched to the mood.
    static func selectBestTrack(from directory: URL?, mood: String? = nil) async -> URL? {
        guard let musicDir = directory else {
            Self.log("No custom music directory provided.")
            return nil
        }
        
        let fileManager = FileManager.default
        let hasAccess = musicDir.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                musicDir.stopAccessingSecurityScopedResource()
            }
        }
        
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: musicDir.path, isDirectory: &isDir), isDir.boolValue else {
            Self.log("Music directory not found or is not a directory at \(musicDir.path)")
            return nil
        }
        
        do {
            let enumerator = fileManager.enumerator(at: musicDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            var audioFiles: [URL] = []
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "mp3" || ext == "wav" || ext == "m4a" || ext == "aac" {
                    audioFiles.append(fileURL)
                }
            }
            
            if audioFiles.isEmpty {
                Self.log("No audio files found in \(musicDir.path)")
                return nil
            }
            
            // SMART MATCHING ALGORITHM
            var matches: [TrackMatch] = []
            let moodLower = (mood ?? "").lowercased()
            
            for file in audioFiles {
                let name = file.lastPathComponent.lowercased()
                var score = 0
                
                // Match keywords if mood is provided
                if !moodLower.isEmpty {
                    if moodLower.contains("tension") || moodLower.contains("напряж") {
                        if name.contains("tension") || name.contains("dark") || name.contains("suspense") || name.contains("sigma") || name.contains("phonk") { score += 10 }
                    }
                    if moodLower.contains("sad") || moodLower.contains("груст") || moodLower.contains("драм") || moodLower.contains("drama") {
                        if name.contains("sad") || name.contains("piano") || name.contains("slow") || name.contains("emotional") { score += 10 }
                    }
                    if moodLower.contains("epic") || moodLower.contains("эпич") || moodLower.contains("action") {
                        if name.contains("epic") || name.contains("battle") || name.contains("action") || name.contains("bass") { score += 10 }
                    }
                    if moodLower.contains("chill") || moodLower.contains("спокой") {
                        if name.contains("chill") || name.contains("lofi") || name.contains("relax") || name.contains("calm") { score += 10 }
                    }
                }
                
                // Add some randomness to equal scores so we don't pick the same track every time
                score += Int.random(in: 0...3)
                matches.append(TrackMatch(url: file, score: score))
            }
            
            matches.sort { $0.score > $1.score }
            guard let bestMatch = matches.first?.url else { return nil }
            
            Self.log("Smart selected music: \(bestMatch.lastPathComponent) for mood: \(mood ?? "none")")
            
            // Copy to temp directory
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(bestMatch.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.copyItem(at: bestMatch, to: tempURL)
            
            // SMART AUDIO DROP DETECTION
            // Find the best moment (the drop or climax) to start the music!
            let dropOffset = await AudioDropDetector.findDrop(in: tempURL)
            Self.log("Smart Audio Drop detected at \(dropOffset)s")
            
            // We append the offset to the query parameters so AVAssetExportSession (CinemaAudioMastering) can read it
            var components = URLComponents(url: tempURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "dropOffset", value: String(dropOffset))]
            let finalURL = components?.url ?? tempURL
            
            Self.log("Copied to temp for mastering: \(finalURL.path)")
            return finalURL
            
        } catch {
            Self.log("Error scanning music directory: \(error.localizedDescription)")
            return nil
        }
    }
    
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/smart-music-selector] \(message)\n".utf8))
    }
}
