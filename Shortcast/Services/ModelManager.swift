import Foundation
import Observation
import Gemma4Swift

/// The essay Director is loaded lazily; no unrelated captioning model at startup.
@MainActor
@Observable
final class ModelManager {
    /// Vision checkpoint used only to verify essay cover subjects.
    static let model: Gemma4Pipeline.Model = .e4b4bit
    let momentFinder = MomentFinderService()
    var systemRAMGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    var canKeepBothResident: Bool { systemRAMGB >= 24 }

    func prepareDirector(profile: ChatModelProfile) async {
        momentFinder.setProfile(profile)
        await momentFinder.prepareIfNeeded()
    }

    /// Загружает Director в нужном профиле и требует, чтобы модель реально
    /// была готова. Ошибка здесь — единственный способ узнать, что тему для
    /// эссе выбирала не модель: молча подставлять заготовку больше некуда.
    func requireDirector(profile: ChatModelProfile) async throws {
        momentFinder.setProfile(profile)
        await momentFinder.prepareIfNeeded()
        guard momentFinder.isReady else {
            throw ThematicDiscoveryError.directorUnavailable(
                momentFinder.loadFailureDescription ?? "фаза \(momentFinder.phase)"
            )
        }
    }

    func freeDirectorIfMemoryTight() {
        guard !canKeepBothResident else { return }
        momentFinder.unload()
    }
}
