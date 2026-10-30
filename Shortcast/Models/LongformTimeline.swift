import Foundation

/// Одна шкала времени для монтажа, глав и проверки длительности.
struct LongformTimeline: Sendable {
    static let intro: Double = 2.5
    static let outro: Double = 4
    static let interActGap: Double = 0.8
    static let intraActGap: Double = 0

    struct Placement: Sendable {
        let actIndex: Int
        let sceneIndex: Int
        let source: TimeSegment
        let start: Double
        var end: Double { start + source.duration }
        let gapBefore: Double
        let isInterAct: Bool
    }

    let placements: [Placement]
    let introDuration: Double
    let speechEnd: Double
    let outroDuration: Double
    var duration: Double { speechEnd + outroDuration }

    init(arc: LongformNarrativeArc, coldOpenEnabled: Bool = true) {
        introDuration = coldOpenEnabled ? Self.intro : 0
        var cursor = introDuration
        var result: [Placement] = []
        for (ai, act) in arc.acts.enumerated() {
            for (si, segment) in act.segments.enumerated() {
                let interAct = result.last.map { $0.actIndex != ai } ?? false
                let gap = result.isEmpty ? 0 : (interAct ? Self.interActGap : Self.intraActGap)
                cursor += gap
                result.append(Placement(actIndex: ai, sceneIndex: si, source: segment,
                                        start: cursor, gapBefore: gap, isInterAct: interAct))
                cursor += segment.duration
            }
        }
        placements = result
        speechEnd = cursor
        outroDuration = LongformEditorialSupport.finalCardDuration(text: LongformEditorialSupport.finalCard(for: arc))
    }

    func start(ofAct index: Int) -> Double? {
        placements.first { $0.actIndex == index }?.start
    }
}

/// Рампы не добавляют времени: внутри акта кадр уходит в чёрный на самой
/// склейке и сразу проявляется. Все интервалы строго раздельны для AVFoundation.
enum LongformTransitionPlan {
    struct Ramp: Equatable, Sendable {
        let from: Float
        let to: Float
        let start: Double
        let end: Double
    }

    static func ramps(intro: Double, speechEnd: Double, cuts: [LongformCutTransition]) -> [Ramp] {
        guard speechEnd.isFinite, speechEnd > 0 else { return [] }
        var result: [Ramp] = []
        func append(_ from: Float, _ to: Float, _ start: Double, _ end: Double) {
            guard start.isFinite, end.isFinite else { return }
            let lower = max(0, start, (result.last?.end ?? -0.001) + 0.001)
            let upper = min(end, speechEnd)
            guard upper - lower >= 0.02 else { return }
            result.append(Ramp(from: from, to: to, start: lower, end: upper))
        }
        append(0, 1, intro, intro + (intro > 0 ? 1.5 : 1.2))
        for cut in cuts.sorted(by: { $0.sceneEndTime < $1.sceneEndTime }) {
            guard cut.sceneEndTime.isFinite, cut.nextSceneStartTime.isFinite,
                  cut.nextSceneStartTime >= cut.sceneEndTime else { continue }
            append(1, 0, max(intro + 0.5, cut.sceneEndTime - (cut.isInterAct ? 0.35 : 0.28)), cut.sceneEndTime)
            append(0, 1, cut.nextSceneStartTime, cut.nextSceneStartTime + (cut.isInterAct ? 0.45 : 0.32))
        }
        append(1, 0, max(intro + 2, speechEnd - 1.2), speechEnd)
        return result
    }
}
