import Foundation
import Testing
import CryptoKit
import AVFoundation
@testable import Shortcast

@Suite("Film plan and torrent safety")
struct FilmLibraryTests {
    @Test func shippedPlanIncludesFiftyAndOriginalThree() throws {
        let url = try #require(Bundle.main.url(forResource: "essays_20_films", withExtension: "md"))
        let films = PlannedFilm.parse(try String(contentsOf: url, encoding: .utf8))
        #expect(films.count == 50)
        #expect(films.prefix(3).map(\.title) == ["Бійцівський клуб", "Острів проклятих", "Інтерстеллар"])
        #expect(Set(films.map(\.id)).count == 50)
    }
    @MainActor @Test func completedIsSeededOnceAndPersistsChanges() throws {
        let suite = "FilmLibraryTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let first = FilmLibrary(defaults: defaults)
        #expect(first.completed.count == 3)
        let film = try #require(first.films.first); first.toggleCompleted(film)
        let restored = FilmLibrary(defaults: defaults)
        #expect(restored.completed.count == 2)
        #expect(!restored.completed.contains(film.id))
    }
    @Test func manifestRejectsTraversalTruncationAndInvalidLengths() throws {
        let valid = Data("d4:infod6:lengthi12e4:name8:film.mkvee".utf8)
        let files = try TorrentManifest.files(valid)
        #expect(files.count == 1); #expect(files[0].path == "film.mkv"); #expect(files[0].bytes == 12)
        for string in ["d4:infod6:lengthi12e4:name9:../x.mkvee", "d4:infod6:lengthi-1e4:name8:film.mkvee", "d4:infod6:lengthi12e4:name800:film.mkvee", "<html>403</html>"] {
            #expect(throws: (any Error).self) { try TorrentManifest.files(Data(string.utf8)) }
        }
    }
    @Test func preservesRealFileIndexesForVideoSelection() throws {
        let data = Data("d4:infod5:filesld6:lengthi2e4:pathl8:read.txteed6:lengthi50e4:pathl8:film.mkveee4:name4:rootee".utf8)
        let files = try TorrentManifest.files(data)
        #expect(files.map(\.index) == [1, 2]); #expect(files[1].path == "root/film.mkv")
    }
    @Test func packagingRequiresThreeDifferentConcisePromises() throws {
        let good = #"{"variants":[{"title":"Ціна вибору","coverText":"ВИБІР","rationale":"Наслідки рішення"},{"title":"Чому він повернувся","coverText":"ПОВЕРНЕННЯ","rationale":"Мотив героя"},{"title":"Що ми втратили","coverText":"ВТРАТА","rationale":"Ціна конфлікту"}]}"#
        let variants = try PackagingVariantParser.parse(good)
        #expect(variants.count == 3)
        #expect(throws: (any Error).self) { try PackagingVariantParser.parse(good.replacingOccurrences(of: "ПОВЕРНЕННЯ", with: "ВИБІР")) }
        #expect(try JSONDecoder().decode([PackagingExperiment].self, from: JSONEncoder().encode(variants)) == variants)
    }
    @Test func cleanShortDurationMatchesActualScenes() throws {
        let short = EssayShort(id: "short1", angle: "Думка", hook: "Хук", title: "Назва", why: "Причина", payoffQuote: "Цитата", question: "Питання", segments: [.init(start: 10, end: 30)])
        #expect(short.duration == 20); #expect(!short.showsSubtitles)
        let restored = try JSONDecoder().decode(EssayShort.self, from: JSONEncoder().encode(short))
        #expect(restored.duration == 20); #expect(!restored.showsSubtitles)
    }
}

@Suite("Story formats and music envelope")
struct StoryFormatTests {
    @MainActor @Test func storyUsesConflictAndConsequenceInsteadOfAnalyticalQuotas() {
        var concept = ThematicConcept(word: "ВИБІР", tagline: "Ціна", philosophicalPremise: "Ціна вибору", suggestedTitle: "Ціна", source: .llm)
        concept.essayFormat = .emotionalStory
        #expect(concept.format.roles == [.hook, .downfall, .struggle, .catharsis])
        #expect(concept.format.minimumScenes(.struggle) == 1)
        let prompt = DirectorStagedAnalysis.catalogueInstructions(movieTitle: "Фільм", concept: concept)
        #expect(prompt.contains("8–22")); #expect(prompt.contains("наслідок"))
        var moments: [SelectedMoment] = []
        for i in 0..<9 {
            let role: LongformActType = i == 0 ? .hook : concept.format.roles[1 + (i - 1) % 3]
            moments.append(SelectedMoment(startTime: Double(i * 30), endTime: Double(i * 30 + 28), reason: "Дія", dramaticWeight: 0.8, actRole: role))
        }
        let analysis = ThematicAnalysisResult(primaryConcept: concept, aiReasoning: "Розбір", selectedMoments: moments, source: .llm)
        switch DirectorArtifactGate.analysis(analysis, completeness: .complete) {
        case .accepted, .repaired: break
        case .rejected(let reason, _): Issue.record("\(reason)")
        }
        var wrong = analysis; wrong.primaryConcept.essayFormat = .analytical
        #expect(!SelectedThemeAnalysisResolver.matches(wrong, selection: concept))
    }
    @Test func envelopeInterpolationAndDuckingAreCombined() {
        var settings = LongformAudioSettings(musicVolume: 0.1, duckingEnabled: true)
        settings.musicFadeInSeconds = 0; settings.musicFadeOutSeconds = 0
        settings.musicEnvelope = [.init(time: 0, gain: 0.2), .init(time: 10, gain: 1), .init(time: 20, gain: 0.4)]
        #expect(abs(MusicBedMixing.envelopeGain(at: 5, points: settings.musicEnvelope!) - 0.6) < 0.0001)
        let plain = MusicBedMixing.automation(duration: 20, settings: settings, speech: [])
        let ducked = MusicBedMixing.automation(duration: 20, settings: settings, speech: [.init(start: 9, end: 11)])
        #expect(abs((plain.first?.gain ?? 1) - 0.02) < 0.0001)
        #expect((ducked.first { $0.time == 10 }?.gain ?? 1) < (plain.first { $0.time == 10 }?.gain ?? 0))
    }
}

@MainActor @Suite("Managed torrent engine", .serialized)
struct ManagedTorrentEngineTests {
    @Test func downloadsAndResumesVerifiedWebseedWithoutMovieData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcast-torrent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<(2 * 1024 * 1024)).map { UInt8($0 % 251) })
        try bytes.write(to: directory.appendingPathComponent("fixture.mp4"))
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", """
        import http.server,socketserver,time,pathlib,sys,os
        os.chdir(sys.argv[1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                data=pathlib.Path('fixture.mp4').read_bytes()
                start,end=0,len(data)-1
                value=self.headers.get('Range','')
                if value.startswith('bytes='):
                    first,last=value[6:].split('-',1)
                    start=int(first or 0); end=min(int(last) if last else end,end)
                self.send_response(206 if value else 200)
                self.send_header('Content-Length',str(end-start+1))
                self.send_header('Accept-Ranges','bytes')
                if value: self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
                self.end_headers()
                try:
                    for offset in range(start,end+1,16384):
                        self.wfile.write(data[offset:min(offset+16384,end+1)]); self.wfile.flush(); time.sleep(0.04)
                except (BrokenPipeError,ConnectionResetError): pass
            def log_message(self,*args): pass
        with socketserver.ThreadingTCPServer(('127.0.0.1',0),Handler) as server:
            pathlib.Path('port').write_text(str(server.server_address[1]))
            server.serve_forever()
        """, directory.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run(); defer { server.terminate() }
        let portFile = directory.appendingPathComponent("port")
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: portFile.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        func b(_ data: Data) -> Data { Data("\(data.count):".utf8) + data }
        func b(_ text: String) -> Data { b(Data(text.utf8)) }
        var pieces = Data()
        for start in stride(from: 0, to: bytes.count, by: 262144) { pieces.append(contentsOf: Insecure.SHA1.hash(data: bytes[start..<min(bytes.count, start + 262144)])) }
        let info = Data("d6:lengthi\(bytes.count)e4:name".utf8) + b("fixture.mp4") + Data("12:piece lengthi262144e6:pieces".utf8) + b(pieces) + Data("e".utf8)
        let torrentData = Data("d4:info".utf8) + info + Data("8:url-listl".utf8) + b("http://127.0.0.1:\(port)/") + Data("ee".utf8)
        let torrent = directory.appendingPathComponent("fixture.torrent"); try torrentData.write(to: torrent)
        let file = try #require(TorrentManifest.files(torrentData).first)
        let suite = "TorrentEngineTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = FilmLibrary(defaults: defaults)
        let film = PlannedFilm(number: 99, title: "Тест", year: 2026, topic: "Тест")
        try library.enqueue(film: film, torrent: torrent, file: file, workingDirectory: directory)
        defer { library.pause(film.id) }
        try await Task.sleep(for: .milliseconds(700)); library.pause(film.id)
        #expect(library.downloads.first?.state == "Приостановлено")
        try await Task.sleep(for: .seconds(2)); try library.resume(film.id)
        for _ in 0..<150 {
            if library.downloads.first?.state != "Загрузка" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let task = try #require(library.downloads.first)
        #expect(task.state == "Скачан", "\(task.state): \(task.progress)")
        let output = try Data(contentsOf: task.sourceURL)
        #expect(SHA256.hash(data: output) == SHA256.hash(data: bytes))
        #expect(FilmLibrary(defaults: defaults).downloads.first?.state == "Скачан")
    }
}

@Suite("UAKino adapter")
struct UAKinoAdapterTests {
    @Test func matchesOnlyUniqueTitleAndYear() throws {
        let film = PlannedFilm(number: 4, title: "Шоу Трумана", year: 1998, topic: "Свобода")
        let url = URL(string: "https://uakino.best/filmy/genre_comedy/109-shou-trumena.html")!
        let match = UAKinoAdapter.SearchResult(title: "Шоу Трумена", year: 1998, url: url)
        #expect(UAKinoAdapter.match([match], film: film) == url)
        #expect(UAKinoAdapter.match([match, match], film: film) == nil)
        #expect(UAKinoAdapter.match([.init(title: "Шоу Трумена", year: 2026, url: url)], film: film) == nil)
    }
    @Test func distinguishesReleasePageFromFinalTorrentFile() {
        let page = URL(string: "https://uakino.best/download/118778/torrent/")!
        let file = URL(string: "https://uakino.best/torrent/118778/Шоу%20Трумена%20.torrent")!
        #expect(UAKinoAdapter.validTorrentURL(page)); #expect(!UAKinoAdapter.validFileURL(page))
        #expect(UAKinoAdapter.validFileURL(file)); #expect(!UAKinoAdapter.validTorrentURL(file))
    }
    @Test func parsesObservedRowsAndExcludesUnrelatedLinks() throws {
        let rows = #"[{"title":"Фільм 1080p Ukr","size":"8.74 GB","seeds":61,"peers":0,"url":"https://uakino.best/download/492649/torrent/"},{"title":"Advertising","size":"1 GB","seeds":100,"peers":0,"url":"https://other.example/download/1/torrent/"}]"#
        let parsed = try UAKinoAdapter.parseTorrents(rows)
        #expect(parsed.count == 1); let torrent = try #require(parsed.first); #expect(torrent.seeds == 61)
        #expect(UAKinoAdapter.recommended(parsed, availableBytes: 40 * 1024 * 1024 * 1024) == torrent.id)
        #expect(UAKinoAdapter.recommended(parsed, availableBytes: 1024 * 1024 * 1024) == nil)
    }
    @MainActor @Test func actualWebKitTableExtraction() async throws {
        let model = FilmTorrentBrowserModel(folder: FileManager.default.temporaryDirectory)
        model.web.loadHTMLString("""
        <table class="restable"><tbody><tr><th>Фільм 1080p Ukr</th><th>8.74 GB</th><th>61</th><th>0</th><th><a href="https://uakino.best/download/492649/torrent/">Скачати</a></th></tr></tbody></table>
        """, baseURL: nil)
        for _ in 0..<100 {
            if !model.torrents.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.torrents.count == 1); #expect(model.torrents.first?.seeds == 61)
    }
}

@Suite("Compilation export")
struct CompilationSourceTests {
    @Test func preservesSourceMapAndOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compilation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let generated = try await ProcessRunner.shared.run(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "8", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source.path])
        #expect(generated.isSuccess)
        let clips = [CompilationSource(title: "Фільм", url: source, start: 1, end: 4, audioStreamIndex: 1), CompilationSource(title: "Інтерв'ю", url: source, start: 4, end: 7, audioStreamIndex: 1)]
        let output = try await CompilationSourceService.build(title: "Тема", sources: clips, directory: directory)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let manifest = try #require(CompilationManifest.load(for: output))
        #expect(manifest.sources.map(\.timelineStart) == [0, 3]); #expect(manifest.sources.map(\.start) == [1, 4])
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 6) < 0.2)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }
}

extension StoryFormatTests {
    @Test func storyBuildsAndValidatesFourActsWithoutAnalyticalRoles() async throws {
        var concept = ThematicConcept(word: "ВИБІР", tagline: "Ціна вибору", philosophicalPremise: "Вибір героя має наслідки", suggestedTitle: "Ціна вибору", source: .llm)
        concept.essayFormat = .emotionalStory
        let text = "Ти маєш зробити свій вибір і відповісти за його наслідки."
        var lines: [TranscriptSegment] = []
        var moments: [SelectedMoment] = []
        for i in 0..<9 {
            let start = Double(i * 30), end = start + 28
            let role: LongformActType = i == 0 ? .hook : concept.format.roles[1 + (i - 1) % 3]
            lines.append(TranscriptSegment(start: start, end: end, text: text))
            moments.append(SelectedMoment(startTime: start, endTime: end, reason: "Наслідок вибору", dramaticWeight: 0.8, actRole: role, supports: "Показує ціну рішення", evidenceQuote: "Ти маєш зробити свій вибір"))
        }
        let transcript = Transcript(segments: lines, language: "uk")
        let plan = EssayPlan(thesis: "Ціна вибору", actFocus: ["downfall":"Проблема", "struggle":"Рішення", "catharsis":"Наслідок"])
        var analysis = ThematicAnalysisResult(primaryConcept: concept, aiReasoning: "Розбір", selectedMoments: moments, source: .llm)
        analysis.essayPlan = plan
        try EssaySceneEvidence.validate(analysis, transcript: transcript)
        let arc = try await LongformNarrativeDirector().buildArc(from: transcript, concept: concept, selectedMoments: moments, movieTitle: "Фільм", essayPlan: plan)
        #expect(arc.acts.map(\.type) == [.hook, .downfall, .struggle, .catharsis])
        try EssaySceneEvidence.validateArc(arc, selectedMoments: moments, coldOpenEnabled: true)
    }
}

@Suite("Saved project pipeline audit", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_AUDIT_PROJECT"] != nil))
struct SavedProjectPipelineAuditTests {
    @Test func savedFilmEssayAndReleaseUseVerifiedArtifacts() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SHORTCAST_AUDIT_PROJECT"])
        let url = URL(fileURLWithPath: path)
        let before = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(FilmProject.self, from: before)
        let transcript = try #require(project.transcript)
        let analysis = try #require(project.thematicAnalysis)
        let result = try #require(project.longformResult)
        #expect(transcript.contentLanguage?.hasPrefix("uk") == true)
        try EssaySceneEvidence.validate(analysis, transcript: transcript)
        try EssaySceneEvidence.validateArc(result.arc, selectedMoments: analysis.selectedMoments,
            coldOpenEnabled: result.audioSettings?.coldOpenEnabled ?? true, allowApprovedTrim: true, allowUserApprovedScenes: true)
        #expect(result.arc.acts.map(\.type) == result.arc.concept.format.roles)
        #expect(result.metadata.description.contains("https://donatello.to/"))
        let source = AVURLAsset(url: project.sourceMovieURL)
        let sourceDuration = try await source.load(.duration).seconds
        #expect(try await source.loadTracks(withMediaType: .audio).count == 1)
        let essay = AVURLAsset(url: result.outputURL)
        #expect(abs(try await essay.load(.duration).seconds - result.duration) < 0.2)
        let variants = project.packagingExperiments ?? []
        #expect(variants.count >= 3)
        for variant in variants {
            let cover = try #require(variant.coverURL)
            #expect(FileManager.default.fileExists(atPath: cover.path))
            #expect(variant.coverSubject != nil)
        }
        let release = try #require(project.essayRelease, "Шортсы ещё не подготовлены")
        #expect(release.hasReadyShorts && release.hasCurrentShortStyle && release.usesWholeFilmSelection)
        for short in release.shorts {
            try EssayShortEditing.validate(short, arc: result.arc, sourceDuration: sourceDuration)
            #expect(!short.showsSubtitles)
            let output = try #require(short.outputURL)
            let asset = AVURLAsset(url: output)
            #expect(abs(try await asset.load(.duration).seconds - short.duration) < 0.2)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 1080, height: 1920))
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
