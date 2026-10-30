import AppKit
import CoreGraphics
import Foundation

struct ThumbnailSubjectEvidence: Codable, Equatable, Sendable {
    let leadingCast: [String]
    let sourceTime: Double
    let modelID: String
    let confidence: Double
}

struct ReviewedThumbnail: Sendable {
    let url: URL
    let subject: ThumbnailSubjectEvidence?
}

struct ThumbnailVisionGateway: Sendable {
    let modelID: String
    let complete: @Sendable (URL, String) async throws -> String
}

enum ThumbnailSelectionError: LocalizedError {
    case missingCast, visionUnavailable, noVerifiedLead, noAlternativeLead
    var errorDescription: String? {
        switch self {
        case .missingCast: "Для проверки главного героя нужны имена ведущих актёров из данных фильма."
        case .visionUnavailable: "Визуальная модель для проверки героя недоступна. Повторите обновление оформления."
        case .noVerifiedLead: "Не удалось уверенно подтвердить главного героя в кадрах. Непроверенное лицо на обложку не подставлено."
        case .noAlternativeLead: "Не нашлось другого подходящего кадра с подтверждённым главным актёром. Текущая обложка сохранена."
        }
    }
}

/// Два визуальных решения: отбор по портретам, затем подтверждение на полном кадре.
/// Размер лица оценивает композицию; личность подтверждает мультимодальная модель.
struct ThumbnailSubjectVerifier: Sendable {
    let model: ThumbnailVisionGateway
    let leadingCast: [String]

    struct Choice: Decodable, Equatable, Sendable {
        let frame: Int
        let leadIndex: Int
        let confidence: Double
    }
    static func choices(from raw: String, frameCount: Int, leadCount: Int) -> [Choice] {
        guard frameCount > 0, leadCount > 0 else { return [] }
        struct Reply: Decodable { let choices: [Choice] }
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(json.utf8)) else { return [] }
        var seen = Set<Int>()
        return reply.choices.filter {
            (1...frameCount).contains($0.frame) && (1...leadCount).contains($0.leadIndex)
                && $0.confidence.isFinite && (0.8...1).contains($0.confidence) && seen.insert($0.frame).inserted
        }
    }

    func select(from candidates: [ThumbnailCandidateFrame], movieTitle: String,
                avoidingTimes: [Double] = []) async throws
        -> (ThumbnailCandidateFrame, ThumbnailSubjectEvidence) {
        guard !leadingCast.isEmpty else { throw ThumbnailSelectionError.missingCast }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shortcast-cover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cast = leadingCast.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        let minimumSeparation: Double = 35
        let eligible = candidates.filter { candidate in
            candidate.faceBox != nil && candidate.faceCount == 1
                && avoidingTimes.allSatisfy { abs(candidate.time - $0) >= minimumSeparation }
        }
        guard !eligible.isEmpty else {
            throw avoidingTimes.isEmpty ? ThumbnailSelectionError.noVerifiedLead : ThumbnailSelectionError.noAlternativeLead
        }
        for start in stride(from: 0, to: min(eligible.count, 24), by: 6) {
            try Task.checkCancellation()
            let batch = Array(eligible[start..<min(start + 6, eligible.count)])
            DirectorRunLog.write("cover batch: " + batch.enumerated().map { "frame=\($0.offset + 1) time=\($0.element.time)" }.joined(separator: "; "))
            let sheet = try contactSheet(batch)
            let sheetURL = folder.appendingPathComponent("sheet-\(start).jpg")
            _ = try LongformThumbnailExporter().export(image: sheet, to: sheetURL)
            let prompt = """
            These are numbered portrait crops from the real film «\(movieTitle)».
            Choose ONLY clearly recognizable leading cast members from this list:
            \(cast)
            Do not choose an extra or a supporting actor just because their face is large.
            Do not infer identity from the film title or clothing alone. If uncertain, omit it.
            Frame numbers are printed above each portrait; leadIndex is the number in the cast list.
            Return ONLY JSON: {"choices":[{"frame":1,"leadIndex":1,"confidence":0.95}]}.
            Use real frame numbers 1 through \(batch.count). Empty choices is valid.
            """
            let raw = try await model.complete(sheetURL, prompt)
            DirectorRunLog.dumpRaw(raw, stage: "cover-candidates", attempt: start / 6 + 1)
            let approved = Self.choices(from: raw, frameCount: batch.count, leadCount: leadingCast.count)
            // Композиционный рейтинг не может перебить отсутствие подтверждения героя.
            for choice in approved.sorted(by: { batch[$0.frame - 1].score > batch[$1.frame - 1].score }).prefix(3) {
                let candidate = batch[choice.frame - 1]
                let frameURL = folder.appendingPathComponent("verify-\(start)-\(choice.frame).jpg")
                _ = try LongformThumbnailExporter().export(image: candidate.image, to: frameURL)
                let verification = try await model.complete(frameURL, """
                Check the actual full movie frame from «\(movieTitle)». Identify the visible person
                only if they are clearly recognizable as one of these leading actors:
                \(cast)
                Return ONLY {"leadIndex":1,"confidence":0.95}. Use leadIndex=0 and confidence=0
                if uncertain, if it is a supporting character, or if the face is not recognizable.
                """)
                DirectorRunLog.dumpRaw(verification, stage: "cover-confirm", attempt: 1)
                struct Confirmation: Decodable { let leadIndex: Int; let confidence: Double }
                guard let json = JSONVariantParser.extractJSONObject(from: verification),
                      let check = try? JSONDecoder().decode(Confirmation.self, from: Data(json.utf8)),
                      check.leadIndex == choice.leadIndex, (0.8...1).contains(check.confidence) else { continue }
                return (candidate, ThumbnailSubjectEvidence(leadingCast: leadingCast,
                    sourceTime: candidate.time, modelID: model.modelID, confidence: min(choice.confidence, check.confidence)))
            }
        }
        throw ThumbnailSelectionError.noVerifiedLead
    }

    private func contactSheet(_ candidates: [ThumbnailCandidateFrame]) throws -> CGImage {
        let width = 1536, height = 768
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ThumbnailSelectionError.noVerifiedLead }
        context.setFillColor(CGColor(gray: 0.04, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        for (index, candidate) in candidates.enumerated() {
            let cell = CGRect(x: (index % 3) * 512, y: (1 - index / 3) * 384, width: 512, height: 384)
            let face = candidate.faceBox ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let imageSize = CGSize(width: candidate.image.width, height: candidate.image.height)
            let expanded = face.insetBy(dx: -face.width * 0.65, dy: -face.height * 0.65)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            // CGImage cropping uses top-left image coordinates, Vision uses bottom-left.
            let crop = CGRect(x: expanded.minX * imageSize.width, y: (1 - expanded.maxY) * imageSize.height,
                              width: expanded.width * imageSize.width, height: expanded.height * imageSize.height)
            let portrait = candidate.image.cropping(to: crop) ?? candidate.image
            let target = cell.insetBy(dx: 12, dy: 12)
            let pictureArea = CGRect(x: target.minX, y: target.minY, width: target.width, height: target.height - 40)
            let scale = min(pictureArea.width / CGFloat(portrait.width), pictureArea.height / CGFloat(portrait.height))
            let size = CGSize(width: CGFloat(portrait.width) * scale, height: CGFloat(portrait.height) * scale)
            context.draw(portrait, in: CGRect(x: pictureArea.midX - size.width / 2, y: pictureArea.midY - size.height / 2,
                                             width: size.width, height: size.height))
            ("FRAME \(index + 1)" as NSString).draw(at: CGPoint(x: target.minX, y: cell.maxY - 38),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white])
        }
        guard let image = context.makeImage() else { throw ThumbnailSelectionError.noVerifiedLead }
        return image
    }
}
