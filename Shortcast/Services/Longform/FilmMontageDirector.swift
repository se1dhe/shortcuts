import AppKit
import AVFoundation
import Foundation

struct FilmMontagePlan: Codable, Sendable, Equatable {
    struct Shot: Codable, Sendable, Equatable {
        var id: String
        var source: TimeSegment
        var sampledTimes: [Double]
        var observation: String
        var score: Int
    }
    var shots: [Shot]
    var visionModelID: String
    var selectionModelID: String
    var beatSeconds: Double? = nil
    var musicPhase: Double? = nil
    var cutTimes: [Double]? = nil
    var timingVersion: Int? = nil
    static let currentTimingVersion = 3
}

/// A separate whole-film visual search: silent/action shots are eligible even
/// when the dialogue catalogue does not contain them. Two probes are evidence
/// of those frames, not a claim to have watched every frame of the source.
@MainActor
enum FilmMontageDirector {
    static func ranges(duration: Double, count: Int = 72) -> [TimeSegment] {
        guard duration.isFinite, duration > 30, count > 0 else { return [] }
        let start = min(30, duration * 0.04), end = duration * 0.95
        return (0..<count).map { index in
            let time = start + Double(index) / Double(count) * (end - start - 6)
            return TimeSegment(start: time, end: min(duration, time + 5.5))
        }
    }

    static func parseBatch(_ raw: String, candidates: [FilmMontagePlan.Shot]) throws -> [FilmMontagePlan.Shot] {
        struct Reply: Decodable {
            struct Pick: Decodable { let id, observation: String; let score: Int }
            let picks: [Pick]
        }
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)),
              (1...3).contains(reply.picks.count), Set(reply.picks.map(\.id)).count == reply.picks.count else {
            throw EssayReleaseError.invalid("Визуальный редактор должен выбрать 1–3 показанных кадра по ID.")
        }
        return try reply.picks.map { pick in
            guard var shot = candidates.first(where: { $0.id == pick.id }), (1...5).contains(pick.score),
                  !pick.observation.trimmed.isEmpty, pick.observation.count <= 240 else {
                throw EssayReleaseError.invalid("Выбран кадр вне показанного визуального каталога.")
            }
            shot.observation = pick.observation; shot.score = pick.score
            return shot
        }
    }

    static func parseOrder(_ raw: String, pool: [FilmMontagePlan.Shot]) throws -> [FilmMontagePlan.Shot] {
        struct Order: Decodable { let shots: [String] }
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let order = try? JSONDecoder().decode(Order.self, from: Data(json.utf8)),
              (12...16).contains(order.shots.count) else {
            throw EssayReleaseError.invalid("Для эдита нужны 12–16 разных подтверждённых планов.")
        }
        let core = order.shots.first == order.shots.last ? Array(order.shots.dropLast()) : order.shots
        guard core.count >= 12, Set(core).count == core.count else {
            throw EssayReleaseError.invalid("Нужны минимум 12 разных планов; только последний может повторить первый для петли.")
        }
        let shots = try order.shots.map { id in
            guard let shot = pool.first(where: { $0.id == id }) else {
                throw EssayReleaseError.invalid("В монтаж попал непроверенный визуальный план.")
            }
            return shot
        }
        let bands = Set(shots.map { Int($0.source.start / 600) })
        guard bands.count >= min(3, Set(pool.map { Int($0.source.start / 600) }).count) else {
            throw EssayReleaseError.invalid("Эдит повторяет один эпизод. Нужны сильные моменты разных частей фильма.")
        }
        return shots
    }

    private static func sheet(_ shots: [FilmMontagePlan.Shot], source: URL,
                              directory: URL) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.06, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.06, preferredTimescale: 600)
        let size = CGSize(width: 960, height: 660)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        // Never hold an AppKit focus context across an await.
        for (row, shot) in shots.enumerated() {
            for (column, time) in shot.sampledTimes.enumerated() {
                let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                image.lockFocus()
                let rect = CGRect(x: column * 480, y: 660 - (row + 1) * 220 + 24, width: 480, height: 196)
                NSImage(cgImage: frame, size: .zero).draw(in: rect)
                if column == 0 {
                    (shot.id as NSString).draw(at: CGPoint(x: 12, y: rect.minY - 22),
                        withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 18)])
                }
                image.unlockFocus()
            }
        }
        guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw EssayReleaseError.invalid("Не удалось собрать визуальные пробы эдита.")
        }
        return try LongformThumbnailExporter().export(image: frame,
            to: directory.appendingPathComponent("montage-probes-" + UUID().uuidString + ".jpg"))
    }

    static func prepare(source: URL, movie: String, transcript: Transcript, manager: ModelManager,
                        profile: ChatModelProfile, directory: URL,
                        progress: @escaping @MainActor (String) -> Void) async throws -> EssayShort {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let sourceRanges = ranges(duration: duration)
        let candidates = sourceRanges.enumerated().map { index, range in
            FilmMontagePlan.Shot(id: "V\(index + 1)", source: range,
                sampledTimes: [range.start + 0.5, range.start + 3.5], observation: "", score: 0)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("montage-visual-pool.json")
        struct Cache: Codable { let source: String; let duration: Double; let model: String; let shots: [FilmMontagePlan.Shot] }
        var pool: [FilmMontagePlan.Shot] = []
        let visionID = ModelManager.model.rawValue
        if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(Cache.self, from: data),
           saved.source == source.path, abs(saved.duration - duration) < 0.01, saved.model == visionID,
           saved.shots.allSatisfy({ shot in candidates.contains { $0.id == shot.id && $0.source == shot.source } }) {
            pool = saved.shots
        }
        if pool.isEmpty {
            manager.freeDirectorIfMemoryTight()
            let session = CoverVisionSession(model: ModelManager.model)
            do {
                for start in stride(from: 0, to: candidates.count, by: 3) {
                    try Task.checkCancellation()
                    progress("Третий шортс: визуальный поиск по фильму · \(start + 1)–\(min(start + 3, candidates.count)) из \(candidates.count)…")
                    let batch = Array(candidates[start..<min(start + 3, candidates.count)])
                    let url = try await sheet(batch, source: source, directory: directory)
                    defer { try? FileManager.default.removeItem(at: url) }
                    var accepted: [FilmMontagePlan.Shot]?
                    for _ in 0..<2 {
                        let raw = try await session.complete(image: url, prompt: """
                            Фільм: \(movie). На зображенні три рядки V: кожен показує ДВА кадри одного фрагмента.
                            Обери 1–3 найвиразніших фрагменти для музичного кіноредиту: рух, автомобіль,
                            сильний погляд, виразний контраст, напруга або яскравий ракурс. Уникай чорних/титрових кадрів.
                            Оцінюй лише видимі кадри, не вигадуй рух між пробами, культовість чи події сюжету.
                            score: 1–5 (візуальна виразність). observation: коротко українською, що видно.
                            ID лише з \(batch.map(\.id).joined(separator: ", ")). Без пояснень, JSON:
                            {"picks":[{"id":"\(batch[0].id)","score":4,"observation":"..."}]}
                            """)
                        DirectorRunLog.dumpRaw(raw, stage: "montage-vision", attempt: start / 3 + 1)
                        if let picks = try? parseBatch(raw, candidates: batch) { accepted = picks; break }
                    }
                    guard let accepted else { throw EssayReleaseError.invalid("Визуальная модель не проверила часть фильма для эдита. Два готовых шортса сохранены.") }
                    pool += accepted
                }
                await session.unload()
            } catch { await session.unload(); throw error }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Cache(source: source.path, duration: duration, model: visionID, shots: pool)).write(to: cache, options: .atomic)
        }
        guard pool.count >= 12 else { throw EssayReleaseError.invalid("Недостаточно проверенных визуальных моментов для третьего шортса.") }
        try await manager.requireDirector(profile: profile)
        let finder = manager.momentFinder
        let gateway = DirectorChatGateway(readiness: { await finder.isReady }, identifier: { await finder.profile.modelID },
            completion: { instructions, prompt, tokens in await finder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: tokens) })
        let material = pool.map { "\($0.id) [\(Int($0.source.start)) с, \($0.score)/5]: \($0.observation)" }.joined(separator: "\n")
        var order: [FilmMontagePlan.Shot]?, feedback = ""
        for attempt in 1...3 {
            progress("Третий шортс: строим ритм и последовательность сильных кадров…")
            guard let raw = await gateway.complete(instructions: """
                Змонтуй музичний едит фільму з 12–16 показаних ID V, мінімум 12 різних.
                Найвиразніший кадр — на початок. Далі чергуй ракурси й великі/загальні плани,
                нарощуй напругу, завершуй виразним кадром. Лише останній ID може повторити перший для петлі.
                У середині повтори заборонені. Це не переказ сюжету.
                Бери різні частини фільму; не вигадуй непоказаних сцен. Не підганяй під тему есе.
                Лише JSON з ключем shots — масив 12–16 точних ID з каталогу. Не додавай непоказаних ID.
                """, prompt: "Фільм: \(movie)\n" + material + feedback, maxTokens: 450) else { continue }
            DirectorRunLog.dumpRaw(raw, stage: "montage-order", attempt: attempt)
            try Data(raw.utf8).write(to: directory.appendingPathComponent("order-attempt\(attempt).txt"), options: .atomic)
            do { order = try parseOrder(raw, pool: pool); break }
            catch {
                DirectorRunLog.write("montage order rejected: " + error.localizedDescription)
                feedback = "\nВиправ попередній вибір: " + error.localizedDescription
            }
        }
        guard let shots = order else { throw EssayReleaseError.invalid("Модель не построила подтверждённый монтаж третьего шортса.") }
        let short = EssayShort(id: "short3", angle: "Візуальний ритм фільму", hook: "Впізнаєш цей погляд?",
            title: "Ритм фільму", why: "Музичний монтаж перевірених візуальних моментів", payoffQuote: "",
            question: "Який кадр запам'ятався тобі?", segments: shots.map { .init(start: $0.source.start, end: $0.source.start + 2) },
            selectionModelID: profile.modelID, selectionVersion: EssayShortDirector.selectionVersion,
            selectedSourceSegments: shots.map(\.source), format: .montage,
            montagePlan: .init(shots: shots, visionModelID: visionID, selectionModelID: profile.modelID))
        // The common release copy pass reviews this draft against visual
        // observations, before any music preparation or render can publish it.
        return short
    }

    static func musicalPhase(energy: [Double], offset: Double, beat: Double) -> Double {
        guard beat.isFinite, beat > 0, offset.isFinite, offset >= 0, !energy.isEmpty else { return 0 }
        var best = 0.0, bestScore = -Double.infinity
        for phase in stride(from: 0.0, to: beat, by: 0.01) {
            var score = 0.0
            for pulse in 0..<24 {
                let index = Int((offset + phase + Double(pulse) * beat) * 100)
                if index > 0, index < energy.count { score += max(0, energy[index] - energy[index - 1]) }
            }
            if score > bestScore { bestScore = score; best = phase }
        }
        return best
    }

    static func alignToMusic(_ original: EssayShort) async throws -> EssayShort {
        guard let music = original.musicSettings?.backgroundMusicURL else { return original }
        let energy = try await AudioDropDetector.energyProfile(in: music, binSeconds: 0.01)
        return try align(original, energy: energy)
    }

    static func align(_ original: EssayShort, energy: [Double]) throws -> EssayShort {
        guard var plan = original.montagePlan, let edit = original.editPlan else { return original }
        let beat = 60 / min(180, max(70, edit.bpm ?? 110))
        var beats = plan.shots.indices.map { index in
            min(max(1, Int(floor(plan.shots[index].source.duration / beat))),
                index == 0 || index == plan.shots.count - 1 ? 8 : (index < 4 ? 4 : 2))
        }
        let maximum = min(30, original.duration)
        while Double(beats.reduce(0, +)) * beat > maximum {
            guard let index = beats.indices.filter({ beats[$0] > 1 }).max(by: { beats[$0] < beats[$1] }) else { break }
            beats[index] -= 1
        }
        while Double(beats.reduce(0, +)) * beat < 20 {
            guard let index = beats.indices.filter({ Double(beats[$0] + 2) * beat <= plan.shots[$0].source.duration }).min(by: { beats[$0] < beats[$1] }) else { break }
            beats[index] += 2
        }
        let finalDuration = Double(beats.reduce(0, +)) * beat
        guard Double(energy.count) / 100 >= finalDuration else {
            throw EssayReleaseError.invalid("Музыкальный файл короче итогового эдита. Выберите полный трек.")
        }
        // Timing changes must not leave the chosen musical climax just beyond
        // the new end of the edit. Move the entry so it lands in the build.
        let baseOffset = min(max(0, Double(energy.count) / 100 - finalDuration - 0.05),
            max(0, edit.musicPeak - finalDuration * 0.68))
        let detectedPhase = musicalPhase(energy: energy, offset: baseOffset, beat: beat)
        let phase = baseOffset + detectedPhase + finalDuration <= Double(energy.count) / 100
            ? detectedPhase : 0
        var short = original, cursor = 0.0, cuts: [Double] = []
        short.segments = zip(plan.shots, beats).map { shot, pulses in
            let duration = min(shot.source.duration, Double(pulses) * beat)
            defer { cursor += duration; cuts.append(cursor) }
            return TimeSegment(start: shot.source.start, end: shot.source.start + duration)
        }
        plan.beatSeconds = beat; plan.musicPhase = phase; plan.cutTimes = Array(cuts.dropLast())
        plan.timingVersion = FilmMontagePlan.currentTimingVersion
        short.montagePlan = plan
        // A saved video contains the old music entry and cut timings. Updating
        // its plan is not a render; prevent the export loop from skipping it.
        short.renderStyleVersion = nil
        short.musicSettings?.musicOffsetSeconds = baseOffset + phase
        short.editPlan?.musicOffset = baseOffset + phase
        short.editPlan?.payoffTime = min(finalDuration, max(0, edit.musicPeak - baseOffset - phase))
        let renderedDuration = short.duration
        short.musicSettings?.musicEnvelope = [.init(time: 0, gain: 0.8), .init(time: renderedDuration * 0.4, gain: 1), .init(time: renderedDuration, gain: 0.9)]
        return short
    }
}
