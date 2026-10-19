import Testing
import Foundation
@testable import Shortcast

// The integration suite that used to live here asserted that `discoverThematicAnalysis`
// returned a hardcoded theme when no model was passed — i.e. it certified the silent
// fallback. That fallback is gone, so the file now pins the contract that replaced it.
// File name kept: Shortcast.xcodeproj references this exact path.

@Suite("Thematic Discovery Contract Tests")
struct ThematicDiscoveryContractTests {

    /// The only discovery entry point: it takes a non-optional `ModelManager` plus a
    /// `ChatModelProfile`, and `requireDirector(profile:)` runs before any generation.
    private typealias ModelBoundDiscovery =
        (Transcript, String, String?, ModelManager, ChatModelProfile) async throws -> ThematicAnalysisResult

    @Test("discovery cannot be called without a ModelManager")
    func testOnlyModelBoundDiscoveryEntryPointExists() {
        // Type-checks only because every theme-producing call site demands a loaded
        // Director. The closure is never invoked, so nothing here loads a model.
        // Removed with the fallback tables: `discoverConcepts(from:movieTitle:)`,
        // `fallbackConcepts(for:)`, `bespokeConcepts(for:)`, `universalFallbackConcepts()`,
        // `LongformThematicService.parseConcepts(from:)`.
        let modelBound: ModelBoundDiscovery? = {
            (transcript: Transcript, title: String, overview: String?,
             manager: ModelManager, profile: ChatModelProfile) in
            try await LongformThematicService().discoverThematicAnalysis(
                from: transcript,
                movieTitle: title,
                movieOverview: overview,
                modelManager: manager,
                directorProfile: profile
            )
        }
        #expect(modelBound != nil)
    }

    @Test("every discovery failure announces itself in Russian instead of returning a theme")
    func testDiscoveryErrorDescriptionsAreRussianAndActionable() throws {
        let cases: [(ThematicDiscoveryError, [String])] = [
            (.transcriptEmpty, ["Транскрипт", "Whisper"]),
            (.directorUnavailable(" веса модели не найдены"), ["Director", "веса модели"]),
            (.modelReturnedNoText, ["пустой"]),
            (.unparseableOutput("{ без закрывающей скобки"), ["JSON", "без закрывающей"])
        ]

        for (error, fragments) in cases {
            let description = try #require(error.errorDescription)
            #expect(description.isEmpty == false)
            #expect(description.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
            for fragment in fragments {
                #expect(description.contains(fragment))
            }
        }

        let bridged: any Error = ThematicDiscoveryError.transcriptEmpty
        #expect(bridged.localizedDescription == ThematicDiscoveryError.transcriptEmpty.errorDescription)
    }

    @Test("a model that returns nothing yields no theme, not a theme from the codebase")
    func testNothingProducesAThemeWithoutModelOutput() {
        for silence in ["", "   ", "{}", "[]", "<|end|>", "Главная тема — это доверие."] {
            #expect(LongformThematicService.parseThematicAnalysis(from: silence) == nil)
        }

        let emptyTranscript = Transcript(segments: [], language: "ru")
        #expect(LongformThematicService.stratifiedThematicSample(from: emptyTranscript).isEmpty)
        #expect(ThematicDiscoveryError.transcriptEmpty.errorDescription?.isEmpty == false)

        let theme = LongformThematicService.parseThematicAnalysis(from: """
        {"primaryConcept": {"word": "Иллюзия", "tagline": "Ты не у руля.", "suggestedTitle": "Тебя везёт."},
         "aiReasoning": "Все четыре акта — про самообман."}
        """)
        #expect(theme?.source == .llm)
        #expect(theme?.source.isTrustworthy == true)
        #expect(theme?.primaryConcept.source == .llm)
        #expect(theme?.primaryConcept.word == "Иллюзия")
    }

    @Test("the prompt asks the model for exactly the fields the parser refuses to invent")
    func testPromptContractMatchesTheFieldsTheParserRequires() {
        let prompt = LongformThematicService.thematicSystemPrompt(movieTitle: "Неизвестный фильм 2026")

        #expect(prompt.contains("Неизвестный фильм 2026"))
        for field in ["primaryConcept", "aiReasoning", "alternativeConcepts",
                      "word", "tagline", "philosophicalPremise", "suggestedTitle"] {
            #expect(prompt.contains(field))
        }
        #expect(prompt.contains("ОДНУ ГЛАВНУЮ ТЕМУ"))
        #expect(prompt.contains("валидным JSON"))
    }
}
