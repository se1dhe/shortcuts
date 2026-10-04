import Foundation
import CoreGraphics

/// Формат выходного видеоролика в Shortcast
enum CinemaOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortSquare = "Шортс 1:1"
    case shortVertical = "Шортс 9:16"
    case longformLandscape = "Длинный метр 16:9 (YouTube)"

    var id: String { rawValue }

    var targetSize: CGSize {
        switch self {
        case .shortSquare:
            return CGSize(width: 1080, height: 1080)
        case .shortVertical:
            return CGSize(width: 1080, height: 1920)
        case .longformLandscape:
            return CGSize(width: 1920, height: 1080)
        }
    }

    var isLongform: Bool {
        self == .longformLandscape
    }

    var defaultDurationRange: ClosedRange<Double> {
        switch self {
        case .shortSquare, .shortVertical:
            return 42.0...58.0
        case .longformLandscape:
            return 300.0...480.0 // 5 - 8 минут
        }
    }

    var symbol: String {
        switch self {
        case .shortSquare: return "square"
        case .shortVertical: return "rectangle.portrait"
        case .longformLandscape: return "play.rectangle.fill"
        }
    }
}
