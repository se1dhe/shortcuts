import Testing
import Foundation
import AppKit
@testable import Shortcast

@Suite("ThematicConcept & Analysis Result Tests")
struct ThematicConceptTests {

    private func decoded(_ json: String) throws -> ThematicAnalysisResult {
        try JSONDecoder().decode(ThematicAnalysisResult.self, from: Data(json.utf8))
    }

    @Test("a hand built concept carries no provenance until someone records it")
    func testConceptDefaultsToUnknownSource() {
        let concept = ThematicConcept(
            word: "ІЛЮЗІЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля. Просто тебе так кажется."
        )

        #expect(concept.word == "ІЛЮЗІЯ")
        #expect(concept.isPrimaryChoice == false)
        #expect(concept.aiReasoning == nil)
        #expect(concept.accentColorHex == "#F5D020")
        #expect(concept.source == .unknown)
        #expect(concept.source.isTrustworthy == false)
    }

    @Test("only llm and manual provenance is trustworthy")
    func testSourceTrustworthiness() {
        #expect(ThematicSource.llm.isTrustworthy == true)
        #expect(ThematicSource.manual.isTrustworthy == true)
        #expect(ThematicSource.unknown.isTrustworthy == false)
        #expect(ThematicSource.llm.rawValue == "llm")
        #expect(ThematicSource.manual.rawValue == "manual")
        #expect(ThematicSource.unknown.rawValue == "unknown")
    }

    @Test("an analysis result passes its llm provenance to a primary concept built without one")
    func testAnalysisInitBackfillsLLMSourceOntoPrimaryConcept() {
        let primary = ThematicConcept(
            word: "ІЛЮЗІЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля. Просто тебе так кажется."
        )
        #expect(primary.source == .unknown)

        let analysis = ThematicAnalysisResult(
            primaryConcept: primary,
            aiReasoning: "Вся драма строится на иллюзии контроля.",
            alternativeConcepts: [],
            source: .llm
        )

        #expect(analysis.source == .llm)
        #expect(analysis.primaryConcept.source == .llm)
        #expect(analysis.primaryConcept.source.isTrustworthy == true)
        #expect(analysis.primaryConcept.isPrimaryChoice == true)
        #expect(analysis.primaryConcept.aiReasoning == "Вся драма строится на иллюзии контроля.")
    }

    @Test("a concept that already records its own provenance keeps it")
    func testAnalysisInitDoesNotOverrideExplicitConceptSource() {
        let curated = ThematicConcept(
            word: "ІЛЮЗІЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля. Просто тебе так кажется.",
            source: .manual
        )

        let analysis = ThematicAnalysisResult(
            primaryConcept: curated,
            aiReasoning: "Тему выбрал автор, не модель.",
            alternativeConcepts: [ThematicConcept(
                word: "ПРИВЫЧКА",
                tagline: "Повторение заменяет решение.",
                philosophicalPremise: "Тебя делает то, что ты повторяешь.",
                suggestedTitle: "Твой самый опасный выбор — тот, который ты не делал."
            )],
            source: .llm
        )

        #expect(analysis.primaryConcept.source == .manual)
        #expect(analysis.source == .llm)
        // Alternatives keep whatever they came with: `.unknown` is not silently upgraded.
        #expect(analysis.alternativeConcepts.first?.source == .unknown)
    }

    @Test("llm provenance survives a full encode/decode round trip")
    func testLLMProvenanceSurvivesRoundTrip() throws {
        let analysis = ThematicAnalysisResult(
            primaryConcept: ThematicConcept(
                word: "ІЛЮЗІЯ",
                tagline: "Ты держишь руль, которого никогда не касался.",
                philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
                suggestedTitle: "Ты не у руля. Просто тебе так кажется.",
                accentColorHex: "#1C7FD8",
                source: .llm
            ),
            aiReasoning: "Каждый акт возвращает героя к иллюзии контроля.",
            alternativeConcepts: [ThematicConcept(
                word: "ПАМЯТЬ",
                tagline: "Ты помнишь только то, что выгодно тебе.",
                philosophicalPremise: "Прошлое — черновик, который ты переписываешь.",
                suggestedTitle: "Твоя память врёт тебе в пользу.",
                accentColorHex: "#2BB673",
                source: .llm
            )],
            source: .llm
        )

        let data = try JSONEncoder().encode(analysis)
        let restored = try JSONDecoder().decode(ThematicAnalysisResult.self, from: data)

        #expect(restored == analysis)
        #expect(restored.source == .llm)
        #expect(restored.primaryConcept.source == .llm)
        #expect(restored.alternativeConcepts.first?.source == .llm)
        #expect(restored.primaryConcept.isPrimaryChoice == true)
        #expect(restored.allConcepts.count == 2)

        let asObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(asObject["source"] as? String == "llm")
        let primaryDict = try #require(asObject["primaryConcept"] as? [String: Any])
        #expect(primaryDict["source"] as? String == "llm")
    }

    @Test("a manually written theme round trips as manual")
    func testManualProvenanceRoundTrips() throws {
        let concept = ThematicConcept(
            word: "БОРГ",
            tagline: "Выбор, который ты не делал, но от которого не отвертишься.",
            philosophicalPremise: "Свобода без ответственности — это просто малодушие.",
            suggestedTitle: "Ты думаешь, что выбрал. Тебя выбрали.",
            isPrimaryChoice: true,
            source: .manual
        )

        let data = try JSONEncoder().encode(concept)
        let restored = try JSONDecoder().decode(ThematicConcept.self, from: data)

        #expect(restored == concept)
        #expect(restored.source == .manual)
        #expect(restored.source.isTrustworthy == true)
    }

    @Test("themes saved before the source field existed decode as unknown and untrustworthy")
    func testLegacyDecodingWithoutSourceKey() throws {
        let legacyConcept = """
        {
          "word": "БОРГ",
          "tagline": "Выбор, который ты не делал, но от которого не отвертишься.",
          "philosophicalPremise": "Свобода без ответственности — это просто малодушие.",
          "suggestedTitle": "Ты думаешь, что выбрал. Тебя выбрали."
        }
        """
        let concept = try JSONDecoder().decode(ThematicConcept.self, from: Data(legacyConcept.utf8))
        #expect(concept.source == .unknown)
        #expect(concept.source.isTrustworthy == false)
        #expect(concept.isPrimaryChoice == false)
        #expect(concept.aiReasoning == nil)
        #expect(concept.accentColorHex == "#F5D020")

        let legacyAnalysis = """
        {
          "primaryConcept": \(legacyConcept),
          "aiReasoning": "Модель так и не была спрошена, но тема уже лежала в коде."
        }
        """
        let analysis = try decoded(legacyAnalysis)
        #expect(analysis.source == .unknown)
        #expect(analysis.source.isTrustworthy == false)
        #expect(analysis.primaryConcept.source == .unknown)
        #expect(analysis.alternativeConcepts.isEmpty)
    }

    @Test("decoding does not push result provenance into a concept that never recorded one")
    func testResultSourceIsNotBackfilledWhenDecoding() throws {
        // The backfill lives in the memberwise init only. An on-disk file that claims
        // `"source": "llm"` at the result but not on the concept decodes as written —
        // the concept stays `.unknown` and stays untrustworthy.
        let json = """
        {
          "primaryConcept": {
            "word": "БОРГ",
            "tagline": "Выбор, который ты не делал, но от которого не отвертишься.",
            "philosophicalPremise": "Свобода без ответственности — это просто малодушие.",
            "suggestedTitle": "Ты думаешь, что выбрал. Тебя выбрали."
          },
          "aiReasoning": "Разбор, приписанный модели задним числом.",
          "alternativeConcepts": [],
          "source": "llm"
        }
        """
        let analysis = try decoded(json)
        #expect(analysis.source == .llm)
        #expect(analysis.primaryConcept.source == .unknown)
        #expect(analysis.primaryConcept.source.isTrustworthy == false)
    }

    @Test("a result round trips through the theme file exactly as produced by the model")
    func testParsedAnalysisRoundTripsToDiskAndBack() throws {
        let json = """
        {
          "primaryConcept": {
            "word": "Ілюзія",
            "tagline": "Ты держишь руль, которого никогда не касался.",
            "philosophicalPremise": "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            "suggestedTitle": "Ты не у руля. Просто тебе так кажется.",
            "accentColorHex": "#1C7FD8"
          },
          "aiReasoning": "Каждый акт возвращает героя к одному и тому же самообману.",
          "alternativeConcepts": [
            {
              "word": "Привычка",
              "tagline": "Повторение заменяет решение.",
              "philosophicalPremise": "То, что ты делаешь по привычке, делает тебя.",
              "suggestedTitle": "Твой самый опасный выбор — тот, который ты не делал.",
              "accentColorHex": "#E50914"
            }
          ]
        }
        """
        let parsed = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        let restored = try JSONDecoder().decode(
            ThematicAnalysisResult.self, from: try JSONEncoder().encode(parsed))

        #expect(restored == parsed)
        #expect(restored.source == .llm)
        #expect(restored.primaryConcept.word == "Ілюзія")
        #expect(restored.alternativeConcepts.first?.accentColorHex == "#E50914")
    }

    @Test("essay plan round-trips and exposes chosen texts")
    func essayPlanRoundTripsAndDefaults() throws {
        let plan = EssayPlan(
            thesis: "Ціна контролю",
            hookVariants: [.init(text: "Ти контролюєш усе, крім себе.")],
            ctaVariants: [.init(text: "Напиши, від чого ти досі не відпустив.")],
            targetDuration: 600,
            actFocus: ["form": "ритм", "psychology": "страх"]
        )
        let decoded = try JSONDecoder().decode(EssayPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        #expect(decoded.chosenHook == "Ти контролюєш усе, крім себе.")
        #expect(decoded.chosenCTA == "Напиши, від чого ти досі не відпустив.")
        #expect(decoded.effectiveTargetDuration == 600)
        #expect(decoded.focus(for: .form) == "ритм")
    }

    @Test("legacy analysis decodes without essay plan or scene roles")
    func legacyAnalysisDecodesWithoutEssayPlanOrRoles() throws {
        let json = """
        {"primaryConcept":{"word":"ЕГО","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з","source":"llm"},
         "aiReasoning":"р","source":"llm",
         "selectedMoments":[{"startTime":1,"endTime":9,"reason":"r","dramaticWeight":0.5}]}
        """
        let result = try decoded(json)
        #expect(result.essayPlan == nil)
        #expect(result.selectedMoments.first?.actRole == nil)
        #expect(result.selectedMoments.first?.featured == nil)
    }

    @Test("analytic act order and prompt keys stay stable")
    func analyticActOrderAndPromptKeysAreStable() {
        #expect(LongformActType.canonicalAnalyticOrder.map(\.promptKey)
                == ["hook", "form", "psychology", "philosophy", "catharsis"])
        #expect(LongformActType.allCases.prefix(4) == [.hook, .downfall, .struggle, .catharsis])
        #expect(LongformActType(promptKey: "psychology") == .psychology)
        #expect(LongformActType(promptKey: "unknown") == nil)
    }
}

/// Клампинг акцентного цвета по WCAG 2.1 — чистая арифметика, без CALayer и без рендера.
/// Акцент темы уходит прямо в титры поверх произвольного кадра фильма, поэтому он обязан
/// держать контраст AA 4.5:1 против тёмного кадра, а не тонуть в нём.
@Suite("Longform Accent WCAG Contrast Tests")
struct LongformAccentContrastTests {

    /// Эталонная светлота тёмного кинокадра, с которой работает рендерер
    private let frameLuminance = String.cinemaFrameLuminance   // 0.02

    /// Независимая (своя реализация!) формула тона HSB в градусах — чтобы тест
    /// не подтверждал баг тем же кодом, что его содержит.
    private func hueDegrees(red: Double, green: Double, blue: Double) -> Double {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC
        guard delta > 0 else { return -1 }
        let hue: Double
        if maxC == red {
            hue = 60.0 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6.0))
        } else if maxC == green {
            hue = 60.0 * (((blue - red) / delta) + 2.0)
        } else {
            hue = 60.0 * (((red - green) / delta) + 4.0)
        }
        return hue < 0 ? hue + 360.0 : hue
    }

    private func components(_ color: NSColor) -> (red: Double, green: Double, blue: Double) {
        (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    private func contrast(_ color: NSColor, against backgroundL: Double) -> Double {
        let rgb = components(color)
        let luminance = Double.wcagRelativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
        return Double.wcagContrast(foregroundL: luminance, backgroundL: backgroundL)
    }

    @Test("relative luminance and contrast match the WCAG 2.1 reference values")
    func testWCAGReferenceMath() {
        // черное / белое / средний серый из эталона 2.1
        #expect(Double.wcagRelativeLuminance(red: 0, green: 0, blue: 0) == 0.0)
        #expect(abs(Double.wcagRelativeLuminance(red: 1, green: 1, blue: 1) - 1.0) < 1e-9)
        #expect(abs(Double.wcagRelativeLuminance(red: 0.5, green: 0.5, blue: 0.5) - 0.21405) < 0.001)
        #expect(abs(Double.wcagContrast(foregroundL: 1.0, backgroundL: 0.0) - 21.0) < 1e-9)
        #expect(abs(Double.wcagContrast(foregroundL: 0.0, backgroundL: 1.0) - 21.0) < 1e-9)
        #expect(abs(Double.wcagContrast(foregroundL: 0.21405, backgroundL: 0.21405) - 1.0) < 1e-9)
        // 4.5:1 против L=0.02 требует L >= 4.5 * 0.07 - 0.05 = 0.265
        #expect(abs(Double.minimumLuminance(forContrast: 4.5, against: 0.02) - 0.265) < 1e-9)
        #expect(abs(Double.minimumLuminance(forContrast: 3.0, against: 1.0) - 1.0) < 1e-9)  // упирается в потолок
        #expect(Double.minimumLuminance(forContrast: 1.0, against: 0.0) == 0.0)
    }

    @Test("the shipped accent fixtures land where the frame inspection says they land")
    func testAccentFixtureLuminances() throws {
        let blueL = try #require(String.wcagLuminance(hex: "#1C7FD8"))
        #expect(abs(blueL - 0.204) < 0.01)
        let blueContrast = Double.wcagContrast(foregroundL: blueL, backgroundL: frameLuminance)
        #expect(abs(blueContrast - 3.63) < 0.1)
        #expect(blueContrast < String.accentMinContrast)   // этот надо поднимать

        let greenL = try #require(String.wcagLuminance(hex: "#2BB673"))
        #expect(abs(greenL - 0.352) < 0.01)
        let greenContrast = Double.wcagContrast(foregroundL: greenL, backgroundL: frameLuminance)
        #expect(abs(greenContrast - 5.74) < 0.15)
        #expect(greenContrast >= String.accentMinContrast) // этот не трогаем
    }

    @Test("a dark accent is lifted to AA 4.5:1 while keeping its hue")
    func testDarkAccentIsLiftedButKeepsHue() throws {
        let before = try #require(String.srgbComponents(hex: "#1C7FD8"))
        let lifted = String.legibleAccent(hex: "#1C7FD8", backgroundL: frameLuminance, minContrast: 4.5)
        let after = components(lifted)

        #expect(contrast(lifted, against: frameLuminance) >= 4.5)
        #expect(Double.wcagRelativeLuminance(red: after.red, green: after.green, blue: after.blue)
                > Double.wcagRelativeLuminance(red: before.red, green: before.green, blue: before.blue))
        // насыщенность чуть приглушена, тон — тот же самый
        #expect(abs(hueDegrees(red: after.red, green: after.green, blue: after.blue)
                    - hueDegrees(red: before.red, green: before.green, blue: before.blue)) < 1.5)
    }

    @Test("an accent that already clears 4.5:1 comes back byte-identical")
    func testCompliantAccentIsUntouched() throws {
        let original = try #require(NSColor(hex: "#2BB673"))
        let kept = String.legibleAccent(hex: "#2BB673", backgroundL: frameLuminance, minContrast: 4.5)
        #expect(Double(kept.redComponent) == Double(original.redComponent))
        #expect(Double(kept.greenComponent) == Double(original.greenComponent))
        #expect(Double(kept.blueComponent) == Double(original.blueComponent))
        #expect(Double(kept.alphaComponent) == Double(original.alphaComponent))
        // фирменное золото тоже уже комплаентно против тёмного кадра
        let gold = String.legibleAccent(hex: "#F5D020", backgroundL: frameLuminance, minContrast: 4.5)
        #expect(Double(gold.redComponent) == Double(0xF5) / 255.0)
    }

    @Test("an unreachable target gives up at full brightness instead of going darker")
    func testUnreachableTargetStopsAtMaxBrightness() throws {
        // против почти белого кадра синий никогда не добьёт 4.5:1 — отдаём самый светлый оттенок
        let lifted = String.legibleAccent(hex: "#1C7FD8", backgroundL: 0.9, minContrast: 4.5)
        let rgb = components(lifted)
        let originalL = try #require(String.wcagLuminance(hex: "#1C7FD8"))
        #expect(max(rgb.red, max(rgb.green, rgb.blue)) >= 0.999)   // упёрлось в B = 1.0
        #expect(Double.wcagRelativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue) > originalL)
    }

    @Test("a broken hex falls back to the brand gold instead of crashing the render")
    func testInvalidHexFallsBackToBrandGold() {
        let broken = String.legibleAccent(hex: "не цвет", backgroundL: frameLuminance, minContrast: 4.5)
        #expect(contrast(broken, against: frameLuminance) >= 4.5)
        #expect(String.srgbComponents(hex: "#FFE45C") != nil)
        #expect(String.srgbComponents(hex: "ZZZZZZ") == nil)
    }

    @Test("акцентные стили текста проходят через клампинг: либо AA 4.5:1, либо потолок яркости")
    func testAccentTextStylesAreClamped() throws {
        // Чистый красный физически не добивает 4.5:1 с сохранением тона (L_max ≈ 0.213),
        // поэтому честное ожидание такое: либо планка AA выполнена, либо упираемся в B = 1.0.
        for hex in ["#1C7FD8", "#E50914", "#2BB673", "#F5D020"] {
            let originalL = try #require(String.wcagLuminance(hex: hex))
            let styles: [String: [NSAttributedString.Key: Any]] = [
                "субтитры": LongformSubtitleRenderer.captionAttributes(k: 1.0, accentHex: hex)
            ]
            for (name, attrs) in styles {
                let color = try #require(attrs[.foregroundColor] as? NSColor)
                let rgb = components(color)
                let liftedL = Double.wcagRelativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
                let ceiling = max(rgb.red, max(rgb.green, rgb.blue)) >= 0.999
                #expect(contrast(color, against: frameLuminance) >= String.accentMinContrast || ceiling,
                        "\(name) \(hex)")
                #expect(liftedL >= originalL - 1e-9, "\(name) \(hex) не должен темнеть")
            }
        }
        // синий из живой темы — именно он давал 1.2:1 в тёмных сценах; он обязан добить планку
        let blueCaption = try #require(
            LongformSubtitleRenderer.captionAttributes(k: 1.0, accentHex: "#1C7FD8")[.foregroundColor] as? NSColor
        )
        #expect(contrast(blueCaption, against: frameLuminance) >= 4.5)
    }
}
