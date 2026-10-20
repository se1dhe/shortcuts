import Foundation

/// Результат прохода нейминга актов: арка с честными provenance-метками и
/// однострочный реестр для лога (сколько актов взяла модель, сколько — репликой,
/// сколько — шаблоном, и почему).
struct TitlingOutcome: Sendable {
    var arc: LongformNarrativeArc
    var summary: String
}

/// Протокол второго LLM-прохода: назвать каждый акт по РЕАЛЬНОМУ диалогу,
/// который в него вошёл. DI-стиль тот же, что у `LongformNarrativeDirecting`:
/// протокол + конкретная реализация, вызывающий инжектирует шлюз к модели.
protocol LongformActTitling: Sendable {
    /// Один вызов модели на все четыре акта. Модель недоступна или не прошла гейты —
    /// акт получает детерминированный запасной путь с ЧЕСТНОЙ меткой, никогда молчаливый шаблон.
    func applyTitles(
        to arc: LongformNarrativeArc,
        transcript: Transcript,
        movieTitle: String,
        progress: (@Sendable (String) -> Void)?
    ) async -> TitlingOutcome
}

/// Шлюз к ОДНОМУ вызову уже прогретого Director'а.
///
/// Единственная причина, по которой он замыкается на closure'ы: MLX-контейнер живёт
/// в `MomentFinderService` приватным полем, а naming-проход обязан переиспользовать
/// прогретую модель, а не загружать её сам (18 ГБ машина, холодная загрузка ради
/// четырёх заголовков — ровно то, чего политика RAM запрещает).
protocol LongformActTitleModeling: Sendable {
    /// Только `true`, когда модель УЖЕ в памяти. Здесь никто не грузит.
    var isReady: Bool { get async }
    /// Имя модели для provenance-метки (nil — модель не представлена)
    var modelID: String? { get async }
    /// Синхронный one-shot: системные инструкции + промпт → сырой текст ответа (nil — сбой)
    func complete(instructions: String, prompt: String, maxTokens: Int) async -> String?
}

/// Готовый шлюз для продакшна: вызывающий (WorkspaceModel) прокидывает в него
/// `ModelManager.shared.momentFinder` — readiness, имя профиля и generic-генерацию.
struct DirectorChatGateway: LongformActTitleModeling {
    let readiness: @Sendable () async -> Bool
    let identifier: @Sendable () async -> String?
    let completion: @Sendable (String, String, Int) async -> String?

    var isReady: Bool {
        get async { await readiness() }
    }

    var modelID: String? {
        get async { await identifier() }
    }

    func complete(instructions: String, prompt: String, maxTokens: Int) async -> String? {
        await completion(instructions, prompt, maxTokens)
    }
}
