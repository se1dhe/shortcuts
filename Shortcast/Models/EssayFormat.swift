import Foundation

enum EssayFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case analytical, emotionalStory
    var id: String { rawValue }
    var title: String { self == .analytical ? "Аналитическое эссе" : "Эмоциональная киноистория" }
    var roles: [LongformActType] { self == .analytical ? LongformActType.canonicalAnalyticOrder : [.hook, .downfall, .struggle, .catharsis] }
    var sceneCount: ClosedRange<Int> { self == .analytical ? EssayDurationPolicy.pool : 8...22 }
    func minimumScenes(_ role: LongformActType) -> Int { role == .hook || self == .emotionalStory ? 1 : 3 }
}
