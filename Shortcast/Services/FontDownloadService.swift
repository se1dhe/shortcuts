import Foundation
import CoreText
import os.log

/// Manages registration and downloading of premium viral fonts (SOLID: SRP/DIP).
public final class FontDownloadService: @unchecked Sendable {
    public static let shared = FontDownloadService()
    private let logger = OSLog(subsystem: "com.shortcast.fonts", category: "FontDownload")
    private let lock = NSLock()

    private let fonts: [String: String] = [
        "Anton-Regular": "https://raw.githubusercontent.com/google/fonts/main/ofl/anton/Anton-Regular.ttf",
        "Oswald-Bold": "https://raw.githubusercontent.com/google/fonts/main/ofl/oswald/static/Oswald-Bold.ttf",
        "Montserrat-Black": "https://cdn.jsdelivr.net/gh/JulietaUla/Montserrat@master/fonts/ttf/Montserrat-Black.ttf",
        "Montserrat-ExtraBold": "https://cdn.jsdelivr.net/gh/JulietaUla/Montserrat@master/fonts/ttf/Montserrat-ExtraBold.ttf"
    ]

    private var didRegister = false

    private init() {
        registerBundledFonts()
    }

    /// Thread-safe synchronous registration of bundled fonts from app resources.
    public func registerBundledFonts() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRegister else { return }
        
        var registeredCount = 0
        let fileManager = FileManager.default

        // 1. Try direct Bundle TTF and OTF URLs (flat or subpath)
        let ttfURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        let otfURLs = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        for fontURL in (ttfURLs + otfURLs) {
            registerFontFile(url: fontURL, count: &registeredCount)
        }

        // 2. Try App Bundle Fonts directory
        if let bundleFontsURL = Bundle.main.url(forResource: "Fonts", withExtension: nil) {
            registerFonts(in: bundleFontsURL, count: &registeredCount)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let nestedFonts = resourceURL.appendingPathComponent("Fonts")
            if fileManager.fileExists(atPath: nestedFonts.path) {
                registerFonts(in: nestedFonts, count: &registeredCount)
            }
        }

        // 3. Try AppSupport directory
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupportFonts = appSupport.appendingPathComponent("Shortcast/Fonts")
            registerFonts(in: appSupportFonts, count: &registeredCount)
        }

        // 4. Source tree fallback via #filePath (development / testing environment)
        let sourceDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Shortcast
            .appendingPathComponent("Resources/Fonts")
        if fileManager.fileExists(atPath: sourceDir.path) {
            registerFonts(in: sourceDir, count: &registeredCount)
        }

        // 5. Fallback to developer workspace relative path
        let devFontsDir = URL(fileURLWithPath: "Shortcast/Resources/Fonts")
        if fileManager.fileExists(atPath: devFontsDir.path) {
            registerFonts(in: devFontsDir, count: &registeredCount)
        }

        didRegister = true
        os_log("Registered %d bundled fonts", log: logger, type: .info, registeredCount)
    }

    private func registerFontFile(url: URL, count: inout Int) {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            count += 1
            os_log("Successfully registered font: %@", log: logger, type: .info, url.lastPathComponent)
        }
    }

    private func registerFonts(in directory: URL, count: inout Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in items where fileURL.pathExtension.lowercased() == "ttf" || fileURL.pathExtension.lowercased() == "otf" {
            registerFontFile(url: fileURL, count: &count)
        }
    }

    /// Ensures all required fonts are installed, downloading missing ones asynchronously if needed.
    public func ensureFontsInstalled() async {
        registerBundledFonts()

        for (postscriptName, urlString) in fonts {
            guard let url = URL(string: urlString) else { continue }
            do {
                try await ensureFont(postscriptName: postscriptName, downloadURL: url)
            } catch {
                os_log("Failed to ensure font %@: %@", log: logger, type: .error, postscriptName, error.localizedDescription)
            }
        }
    }

    private func ensureFont(postscriptName: String, downloadURL: URL) async throws {
        if let available = CTFontManagerCopyAvailableFontFamilyNames() as? [String] {
            if available.contains(where: { $0.localizedCaseInsensitiveContains("montserrat") }) {
                return
            }
        }

        let fontsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Shortcast/Fonts")

        if !FileManager.default.fileExists(atPath: fontsDir.path) {
            try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        }

        let localURL = fontsDir.appendingPathComponent("\(postscriptName).ttf")

        if !FileManager.default.fileExists(atPath: localURL.path) {
            os_log("Downloading font %@ from CDN...", log: logger, type: .info, postscriptName)
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
            try FileManager.default.moveItem(at: tempURL, to: localURL)
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(localURL as CFURL, .process, &error) {
            os_log("Successfully downloaded and registered font %@", log: logger, type: .info, postscriptName)
        }
    }
}
