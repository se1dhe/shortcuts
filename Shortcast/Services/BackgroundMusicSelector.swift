import Foundation
import AVFoundation

/// Domain model for an available background music track.
public struct BackgroundMusicTrack: Identifiable, Hashable, Sendable {
    public var id: String { url.absoluteString }
    public let name: String
    public let moodTag: String
    public let url: URL
    public let isBuiltIn: Bool
    public var durationSeconds: Double?
    
    public init(name: String, moodTag: String, url: URL, isBuiltIn: Bool, durationSeconds: Double? = nil) {
        self.name = name
        self.moodTag = moodTag
        self.url = url
        self.isBuiltIn = isBuiltIn
        self.durationSeconds = durationSeconds
    }
}

/// Protocol defining background music discovery and selection (DIP / ISP in SOLID).
public protocol BackgroundMusicSelecting: Sendable {
    func loadAvailableTracks(customDirectory: URL?) async -> [BackgroundMusicTrack]
    func selectBestTrack(from directory: URL?, mood: String?) async -> URL?
    func defaultMusicDirectory() -> URL
    func importUserTrack(from sourceURL: URL) async throws -> BackgroundMusicTrack
}

/// Production implementation of BackgroundMusicSelecting.
public final class BackgroundMusicService: BackgroundMusicSelecting, Sendable {
    public static let shared = BackgroundMusicService()
    
    public init() {}
    
    public func defaultMusicDirectory() -> URL {
        // First check bundled resources
        if let bundleDir = Bundle.main.resourceURL?.appendingPathComponent("Music"),
           FileManager.default.fileExists(atPath: bundleDir.path) {
            return bundleDir
        }
        
        // Fallback to Application Support / Shortcast / Music
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let musicDir = appSupport.appendingPathComponent("Shortcast/Music")
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        return musicDir
    }
    
    public func loadAvailableTracks(customDirectory: URL?) async -> [BackgroundMusicTrack] {
        var results: [BackgroundMusicTrack] = []
        let fm = FileManager.default
        
        // 1. Scan built-in / bundled music
        let builtInDir = defaultMusicDirectory()
        if let enumerator = fm.enumerator(at: builtInDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                if ["mp3", "wav", "m4a", "aac"].contains(ext) {
                    let name = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                    results.append(BackgroundMusicTrack(
                        name: name,
                        moodTag: deriveMood(from: fileURL.lastPathComponent),
                        url: fileURL,
                        isBuiltIn: true
                    ))
                }
            }
        }
        
        // Also check project Resources/Music directory if in development
        if results.isEmpty {
            let localResource = URL(fileURLWithPath: "Shortcast/Resources/Music")
            if fm.fileExists(atPath: localResource.path),
               let enumerator = fm.enumerator(at: localResource, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                while let fileURL = enumerator.nextObject() as? URL {
                    let ext = fileURL.pathExtension.lowercased()
                    if ["mp3", "wav", "m4a", "aac"].contains(ext) {
                        let name = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                        results.append(BackgroundMusicTrack(
                            name: name,
                            moodTag: deriveMood(from: fileURL.lastPathComponent),
                            url: fileURL,
                            isBuiltIn: true
                        ))
                    }
                }
            }
        }
        
        // 2. Scan custom user music directory
        if let customDir = customDirectory {
            let hasAccess = customDir.startAccessingSecurityScopedResource()
            defer { if hasAccess { customDir.stopAccessingSecurityScopedResource() } }
            
            if let enumerator = fm.enumerator(at: customDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                while let fileURL = enumerator.nextObject() as? URL {
                    let ext = fileURL.pathExtension.lowercased()
                    if ["mp3", "wav", "m4a", "aac"].contains(ext) {
                        let name = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                        results.append(BackgroundMusicTrack(
                            name: name,
                            moodTag: deriveMood(from: fileURL.lastPathComponent),
                            url: fileURL,
                            isBuiltIn: false
                        ))
                    }
                }
            }
        }
        
        // Сортировка: Foggy Night на первом месте, затем саундтреки prrodan, затем остальные
        results.sort { t1, t2 in
            let isFoggy1 = t1.url.lastPathComponent.lowercased().contains("foggy_night")
            let isFoggy2 = t2.url.lastPathComponent.lowercased().contains("foggy_night")
            if isFoggy1 != isFoggy2 { return isFoggy1 }

            let isPrrodan1 = t1.moodTag == "prrodan" || t1.url.lastPathComponent.lowercased().contains("prrodan")
            let isPrrodan2 = t2.moodTag == "prrodan" || t2.url.lastPathComponent.lowercased().contains("prrodan")
            if isPrrodan1 != isPrrodan2 { return isPrrodan1 }

            return t1.name < t2.name
        }

        return results
    }
    
    private func deriveMood(from filename: String) -> String {
        let lower = filename.lowercased()
        if lower.contains("prrodan") { return "prrodan" }
        if lower.contains("drama") || lower.contains("sad") || lower.contains("emotional") { return "drama" }
        if lower.contains("suspense") || lower.contains("dark") || lower.contains("tension") { return "suspense" }
        if lower.contains("epic") || lower.contains("action") || lower.contains("battle") { return "action" }
        if lower.contains("comedy") || lower.contains("pizzicato") || lower.contains("funny") { return "comedy" }
        if lower.contains("sigma") || lower.contains("phonk") { return "sigma" }
        return "cinematic"
    }
    
    /// Reads the audio file duration in seconds asynchronously using AVURLAsset.
    public static func getTrackDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) {
            let sec = d.seconds
            if !sec.isNaN, !sec.isInfinite, sec > 0 {
                return sec
            }
        }
        return 0.0
    }

    /// Imports a user audio file into the persistent Application Support music folder.
    public func importUserTrack(from sourceURL: URL) async throws -> BackgroundMusicTrack {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let userMusicDir = defaultMusicDirectory().appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: userMusicDir, withIntermediateDirectories: true)

        let filename = sourceURL.lastPathComponent
        let targetURL = userMusicDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)

        let duration = await Self.getTrackDuration(url: targetURL)
        let name = targetURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        let mood = deriveMood(from: filename)

        Self.log("Imported custom audio track: '\(name)' (\(String(format: "%.1f", duration))s) -> \(targetURL.path)")

        return BackgroundMusicTrack(
            name: name,
            moodTag: mood,
            url: targetURL,
            isBuiltIn: false,
            durationSeconds: duration
        )
    }
    
    public func selectBestTrack(from directory: URL?, mood: String? = nil) async -> URL? {
        let tracks = await loadAvailableTracks(customDirectory: directory)
        if tracks.isEmpty {
            Self.log("No background music tracks available.")
            return nil
        }
        
        let moodLower = (mood ?? "").lowercased()
        var scored: [(track: BackgroundMusicTrack, score: Int)] = []
        
        for track in tracks {
            var score = 0
            let nameLower = track.name.lowercased()
            let tagLower = track.moodTag.lowercased()
            
            if !moodLower.isEmpty {
                if moodLower.contains("tension") || moodLower.contains("напряж") || moodLower.contains("suspense") || moodLower.contains("thriller") {
                    if tagLower == "suspense" || nameLower.contains("dark") || nameLower.contains("tension") { score += 20 }
                }
                if moodLower.contains("sad") || moodLower.contains("груст") || moodLower.contains("драм") || moodLower.contains("drama") || moodLower.contains("emotional") {
                    if tagLower == "drama" || nameLower.contains("emotional") || nameLower.contains("theme") { score += 20 }
                }
                if moodLower.contains("epic") || moodLower.contains("эпич") || moodLower.contains("action") || moodLower.contains("blockbuster") {
                    if tagLower == "action" || nameLower.contains("pulse") || nameLower.contains("epic") { score += 20 }
                }
                if moodLower.contains("comedy") || moodLower.contains("юмор") || moodLower.contains("eccentric") {
                    if tagLower == "comedy" || nameLower.contains("comedy") || nameLower.contains("pizzicato") { score += 20 }
                }
                if moodLower.contains("sigma") || moodLower.contains("phonk") || moodLower.contains("tarantino") {
                    if tagLower == "sigma" || nameLower.contains("monologue") || nameLower.contains("sigma") { score += 20 }
                }
            }
            
            // Prefer custom user tracks slightly if available
            if !track.isBuiltIn { score += 2 }
            score += Int.random(in: 0...2)
            scored.append((track, score))
        }
        
        scored.sort { $0.score > $1.score }
        guard let best = scored.first?.track else { return nil }
        
        Self.log("Selected background track: '\(best.name)' for mood '\(mood ?? "default")'")
        
        // Copy to temp directory for stable audio processing
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(best.url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: best.url, to: tempURL)
            let dropOffset = await AudioDropDetector.findDrop(in: tempURL)
            var components = URLComponents(url: tempURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "dropOffset", value: String(dropOffset))]
            return components?.url ?? tempURL
        } catch {
            Self.log("Could not copy track to temp: \(error.localizedDescription)")
            return best.url
        }
    }
    
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/background-music] \(message)\n".utf8))
    }
}

/// Facade for backwards compatibility.
public enum BackgroundMusicSelector {
    public static func selectBestTrack(from directory: URL?, mood: String? = nil) async -> URL? {
        await BackgroundMusicService.shared.selectBestTrack(from: directory, mood: mood)
    }
}
