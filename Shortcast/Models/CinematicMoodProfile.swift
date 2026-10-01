import Foundation
import CoreGraphics
import AppKit

enum CinematicMood: String, Codable, CaseIterable, Sendable {
    case suspenseThriller = "suspenseThriller"
    case tarantinoDialogue = "tarantinoDialogue"
    case eccentricComedy = "eccentricComedy"
    case emotionalDrama = "emotionalDrama"
    case actionBlockbuster = "actionBlockbuster"
    case defaultCinema = "defaultCinema"
    
    var timeCondensationPauseMs: Double {
        switch self {
        case .eccentricComedy: return 60.0
        case .actionBlockbuster: return 120.0
        case .tarantinoDialogue: return 130.0
        case .defaultCinema: return 150.0
        case .suspenseThriller, .emotionalDrama: return 180.0
        }
    }
    
    var backgroundMusicQuery: String {
        switch self {
        case .suspenseThriller: return "dark tension ambient drone"
        case .tarantinoDialogue: return "vintage western acoustic tension"
        case .eccentricComedy: return "fast upbeat electronic energetic"
        case .emotionalDrama: return "sad emotional piano strings"
        case .actionBlockbuster: return "epic orchestral action drums"
        case .defaultCinema: return "cinematic ambient"
        }
    }
    
    var subtitleAnimation: String {
        switch self {
        case .eccentricComedy: return "bounce"
        case .suspenseThriller: return "fade" // Slower pop-in
        default: return "pop" // Default hard pop
        }
    }
}

struct CinematicMoodProfile: Codable, Sendable, Equatable {
    let mood: CinematicMood
    let primaryColorHex: String
    let verbColorHex: String
    let punchlineColorHex: String
    
    init(mood: CinematicMood, primaryColorHex: String = "#F0F0F0", verbColorHex: String = "#F5D020", punchlineColorHex: String = "#E50914") {
        self.mood = mood
        self.primaryColorHex = primaryColorHex
        self.verbColorHex = verbColorHex
        self.punchlineColorHex = punchlineColorHex
    }
    
    static let `default` = CinematicMoodProfile(mood: .defaultCinema)
}
