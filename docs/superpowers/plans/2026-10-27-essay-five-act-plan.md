# Essay Five-Act Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the LLM essay pipeline into a general 5-act analytic structure (hook → form → psychology → philosophy → catharsis) with a model-proposed/optionally user-authored hook, role-based scene selection, a duration budget, and a rendered hook/CTA.

**Architecture:** Extend the existing Director output with an optional `EssayPlan` and optional per-moment act roles. When roles are present, `LongformNarrativeDirector` assembles five analytic acts by role instead of splitting moments by film quartiles. Legacy 4-act heuristic and old archives remain byte-compatible. The plan travels through the coordinator into rendering and metadata.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation/CoreAnimation, Swift Testing (`@Test`/`#expect`), XcodeGen project.

**Spec:** `docs/superpowers/specs/2026-10-27-essay-five-act-plan-design.md`

## Global Constraints

- Essay theme still comes only from the Director LLM (`ThematicSource.llm`); no fabricated themes.
- No per-film hardcode: film titles must not appear in prompts or logic.
- Whisper remains the only transcript/subtitle source.
- New enum cases go **after** the legacy four so `LongformActType.allCases.prefix(4)` stays `hook/downfall/struggle/catharsis`.
- New Codable fields are optional (`decodeIfPresent`) so old archives open.
- Heuristic fallback (`buildArcHeuristic`, `makeSyntheticArc`) stays 4-act and behavior-compatible.
- All new user-visible content strings are Ukrainian; UI chrome/comments stay Russian.
- Add new source files only through `xcodegen generate`; new tests go into existing test files.
- Full `xcodebuild -project "Shortcast.xcodeproj" -scheme Shortcast test` must pass before completion.

---

### Task 1: Models — EssayPlan, act types, moment roles, arc texts

**Files:**
- Modify: `Shortcast/Models/LongformNarrativeArc.swift`
- Modify: `Shortcast/Models/ThematicConcept.swift`
- Test: `ShortcastTests/ThematicConceptTests.swift`
- Test: `ShortcastTests/LongformMomentSanitationTests.swift`

**Interfaces:**
- Produces:
  - `LongformActType.form/.psychology/.philosophy`, `static canonicalAnalyticOrder: [LongformActType]`, `var promptKey: String`, `init?(promptKey: String)`
  - `struct EssayPlan: Codable, Equatable, Sendable` with `TextVariant`, `thesis`, `hookVariants`, `selectedHook`, `ctaVariants`, `selectedCTA`, `targetDuration`, `actFocus`, `chosenHook`, `chosenCTA`, `effectiveTargetDuration`, `focus(for:)`, `confirming(hookText:ctaText:targetDuration:)`
  - `SelectedMoment.actRole/supports/featured`
  - `ThematicAnalysisResult.essayPlan`
  - `LongformNarrativeArc.hookText/ctaText/thesis`

- [ ] **Step 1: Write failing model tests**

Add to `ShortcastTests/ThematicConceptTests.swift`:

```swift
@Test func essayPlanRoundTripsAndDefaults() throws {
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

@Test func legacyAnalysisDecodesWithoutEssayPlanOrRoles() throws {
    let json = """
    {"primaryConcept":{"word":"ЕГО","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з","source":"llm"},
     "aiReasoning":"р","source":"llm",
     "selectedMoments":[{"startTime":1,"endTime":9,"reason":"r","dramaticWeight":0.5}]}
    """
    let decoded = try JSONDecoder().decode(ThematicAnalysisResult.self, from: Data(json.utf8))
    #expect(decoded.essayPlan == nil)
    #expect(decoded.selectedMoments.first?.actRole == nil)
    #expect(decoded.selectedMoments.first?.featured == nil)
}

@Test func analyticActOrderAndPromptKeysAreStable() {
    #expect(LongformActType.canonicalAnalyticOrder.map(\.promptKey) == ["hook", "form", "psychology", "philosophy", "catharsis"])
    #expect(LongformActType.allCases.prefix(4) == [.hook, .downfall, .struggle, .catharsis])
    #expect(LongformActType(promptKey: "psychology") == .psychology)
    #expect(LongformActType(promptKey: "unknown") == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project "Shortcast.xcodeproj" -scheme Shortcast test -only-testing:ShortcastTests/ThematicConceptTests`
Expected: compile failure — `EssayPlan` / `promptKey` / `actRole` do not exist.

- [ ] **Step 3: Extend `LongformActType`**

In `Shortcast/Models/LongformNarrativeArc.swift`, keep the enum declaration order and append new cases after `.catharsis`:

```swift
enum LongformActType: String, Codable, CaseIterable, Sendable {
    case hook = "Хук и Тезис"
    case downfall = "Падение и Испытание"
    case struggle = "Борьба и Упорство"
    case catharsis = "Катарсис и Прорыв"
    // Аналитическая 5-актная структура (LLM-путь). Объявлены после legacy,
    // чтобы allCases.prefix(4) оставался прежним каноническим порядком.
    case form = "Анализ формы"
    case psychology = "Психология героя"
    case philosophy = "Философский подтекст"

    static let canonicalAnalyticOrder: [LongformActType] = [
        .hook, .form, .psychology, .philosophy, .catharsis
    ]

    var promptKey: String {
        switch self {
        case .hook: return "hook"
        case .form: return "form"
        case .psychology: return "psychology"
        case .philosophy: return "philosophy"
        case .catharsis: return "catharsis"
        case .downfall: return "downfall"
        case .struggle: return "struggle"
        }
    }

    init?(promptKey: String) {
        let clean = promptKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let type = LongformActType.allCases.first(where: { $0.promptKey == clean }) else { return nil }
        self = type
    }

    var targetDurationRatio: Double {
        switch self {
        case .hook: return 0.12
        case .form: return 0.24
        case .psychology: return 0.26
        case .philosophy: return 0.24
        case .catharsis: return 0.14
        case .downfall: return 0.33
        case .struggle: return 0.35
        }
    }
}
```

- [ ] **Step 4: Add optional texts to `LongformNarrativeArc`**

Add properties and init parameters with defaults:

```swift
    var hookText: String? = nil
    var ctaText: String? = nil
    var thesis: String? = nil
```

In the memberwise init add after `mood`:

```swift
        hookText: String? = nil,
        ctaText: String? = nil,
        thesis: String? = nil
```

and assign. Synthesized `Codable` handles missing keys because the properties are optional with defaults.

- [ ] **Step 5: Add `EssayPlan` and extend `SelectedMoment`/`ThematicAnalysisResult`**

At the end of `Shortcast/Models/ThematicConcept.swift` (before `SelectedMoment`), add:

```swift
/// План эссе, который Director предлагает вместе с темой: тезис, варианты хука и CTA,
/// фокус каждого аналитического акта и выбранный хронометраж.
struct EssayPlan: Codable, Equatable, Sendable {

    struct TextVariant: Codable, Equatable, Hashable, Sendable, Identifiable {
        var id: String { text }
        var text: String
        var source: ThematicSource

        init(text: String, source: ThematicSource = .llm) {
            self.text = text
            self.source = source
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            source = try c.decodeIfPresent(ThematicSource.self, forKey: .source) ?? .llm
        }

        private enum CodingKeys: String, CodingKey { case text, source }
    }

    var thesis: String?
    var hookVariants: [TextVariant]
    var selectedHook: TextVariant?
    var ctaVariants: [TextVariant]
    var selectedCTA: TextVariant?
    var targetDuration: Double?
    /// promptKey акта -> что именно доказывает акт в этом фильме
    var actFocus: [String: String]

    init(
        thesis: String? = nil,
        hookVariants: [TextVariant] = [],
        selectedHook: TextVariant? = nil,
        ctaVariants: [TextVariant] = [],
        selectedCTA: TextVariant? = nil,
        targetDuration: Double? = nil,
        actFocus: [String: String] = [:]
    ) {
        self.thesis = thesis
        self.hookVariants = hookVariants
        self.selectedHook = selectedHook
        self.ctaVariants = ctaVariants
        self.selectedCTA = selectedCTA
        self.targetDuration = targetDuration
        self.actFocus = actFocus
    }

    private enum CodingKeys: String, CodingKey {
        case thesis, hookVariants, selectedHook, ctaVariants, selectedCTA, targetDuration, actFocus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thesis = try c.decodeIfPresent(String.self, forKey: .thesis)
        hookVariants = try c.decodeIfPresent([TextVariant].self, forKey: .hookVariants) ?? []
        selectedHook = try c.decodeIfPresent(TextVariant.self, forKey: .selectedHook)
        ctaVariants = try c.decodeIfPresent([TextVariant].self, forKey: .ctaVariants) ?? []
        selectedCTA = try c.decodeIfPresent(TextVariant.self, forKey: .selectedCTA)
        targetDuration = try c.decodeIfPresent(Double.self, forKey: .targetDuration)
        actFocus = try c.decodeIfPresent([String: String].self, forKey: .actFocus) ?? [:]
    }

    var chosenHook: String? {
        Self.nonEmpty(selectedHook?.text) ?? hookVariants.lazy.compactMap { Self.nonEmpty($0.text) }.first
    }

    var chosenCTA: String? {
        Self.nonEmpty(selectedCTA?.text) ?? ctaVariants.lazy.compactMap { Self.nonEmpty($0.text) }.first
    }

    var effectiveTargetDuration: Double {
        min(max(targetDuration ?? 520.0, 300.0), 900.0)
    }

    func focus(for type: LongformActType) -> String? {
        Self.nonEmpty(actFocus[type.promptKey])
    }

    /// Фиксирует выбор пользователя: свой хук становится ручным вариантом плана.
    func confirming(hookText: String?, ctaText: String?, targetDuration: Double) -> EssayPlan {
        var copy = self
        if let hookText = Self.nonEmpty(hookText) {
            if let index = copy.hookVariants.firstIndex(where: { $0.text == hookText }) {
                copy.selectedHook = copy.hookVariants[index]
            } else {
                let manual = TextVariant(text: hookText, source: .manual)
                copy.hookVariants.append(manual)
                copy.selectedHook = manual
            }
        } else {
            copy.selectedHook = copy.selectedHook ?? copy.hookVariants.first
        }
        if let ctaText = Self.nonEmpty(ctaText) {
            if let index = copy.ctaVariants.firstIndex(where: { $0.text == ctaText }) {
                copy.selectedCTA = copy.ctaVariants[index]
            } else {
                let manual = TextVariant(text: ctaText, source: .manual)
                copy.ctaVariants.append(manual)
                copy.selectedCTA = manual
            }
        } else {
            copy.selectedCTA = copy.selectedCTA ?? copy.ctaVariants.first
        }
        copy.targetDuration = min(max(targetDuration, 300.0), 900.0)
        return copy
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
```

Extend `SelectedMoment` (new `let` properties with defaulted init params):

```swift
    /// Роль сцены в аналитической арке, если её назначила модель
    let actRole: LongformActType?
    /// Тезис акта, который эта сцена доказывает
    let supports: String?
    /// Сильнейшая сцена акта: не режется бюджетом, пока есть другие кандидаты
    let featured: Bool?

    init(
        startTime: Double,
        endTime: Double,
        reason: String,
        dramaticWeight: Double,
        actRole: LongformActType? = nil,
        supports: String? = nil,
        featured: Bool? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
        self.dramaticWeight = dramaticWeight
        self.actRole = actRole
        self.supports = supports
        self.featured = featured
    }
```

Add to `ThematicAnalysisResult`: property `var essayPlan: EssayPlan?`, init parameter `essayPlan: EssayPlan? = nil`, coding key, and `decodeIfPresent` line.

- [ ] **Step 6: Run model tests**

Run: `xcodebuild -project "Shortcast.xcodeproj" -scheme Shortcast test -only-testing:ShortcastTests/ThematicConceptTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shortcast/Models/ThematicConcept.swift Shortcast/Models/LongformNarrativeArc.swift ShortcastTests/ThematicConceptTests.swift
git commit -m "feat: add essay plan and analytic act types"
```

---

### Task 2: Director prompt and tolerant parsing

**Files:**
- Modify: `Shortcast/Services/Longform/LongformThematicService.swift`
- Modify: `Shortcast/Services/MomentFinderService.swift`
- Test: `ShortcastTests/ThematicParsingTests.swift`

**Interfaces:**
- Consumes: `EssayPlan`, `LongformActType.promptKey`, `SelectedMoment.actRole`
- Produces: `parseEssayPlan(_:) -> EssayPlan?`, role-aware `parseSelectedMoments`, `makeResult(..., essayPlan:)`

- [ ] **Step 1: Write failing parsing tests**

Add to `ShortcastTests/ThematicParsingTests.swift`:

```swift
@Test func parsesEssayPlanAndMomentRoles() throws {
    let json = """
    {"reasoning":"р","primaryConcept":{"word":"ЕГО","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з"},
     "essayPlan":{"thesis":"Контроль — це страх","hookVariants":["Ти контролюєш усе, крім себе.","Хто насправді обирає за тебе?"],
       "ctaVariants":["Напиши, від чого ти не відпустив."],
       "actFocus":{"form":"монтаж","psychology":"страх","philosophy":"свобода","catharsis":"вибір"}},
     "selectedMoments":[
       {"startTime":10,"endTime":20,"reason":"відкриття","dramaticWeight":0.9,"actRole":"hook","supports":"теза","featured":true},
       {"startTime":100,"endTime":130,"reason":"розбір","dramaticWeight":0.8,"actRole":"form"},
       {"startTime":300,"endTime":340,"reason":"страх","dramaticWeight":0.7,"actRole":"psychology"}
     ]}
    """
    let result = try #require(LongformThematicService.parseThematicAnalysis(from: json))
    let plan = try #require(result.essayPlan)
    #expect(plan.thesis == "Контроль — це страх")
    #expect(plan.hookVariants.count == 2)
    #expect(plan.chosenHook == "Ти контролюєш усе, крім себе.")
    #expect(plan.chosenCTA == "Напиши, від чого ти не відпустив.")
    #expect(plan.focus(for: .philosophy) == "свобода")
    #expect(result.selectedMoments.map(\.actRole) == [.hook, .form, .psychology])
    #expect(result.selectedMoments[0].featured == true)
    #expect(result.selectedMoments[1].featured == nil)
}

@Test func legacyResponseStillParsesWithoutEssayPlan() throws {
    let json = """
    {"reasoning":"р","primaryConcept":{"word":"ЕГО","tagline":"т","philosophicalPremise":"п","suggestedTitle":"з"},
     "selectedMoments":[{"startTime":10,"endTime":20,"reason":"r","dramaticWeight":0.5}],
     "alternativeConcepts":[]}
    """
    let result = try #require(LongformThematicService.parseThematicAnalysis(from: json))
    #expect(result.essayPlan == nil)
    #expect(result.selectedMoments.first?.actRole == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild ... test -only-testing:ShortcastTests/ThematicParsingTests`
Expected: compile failure or `essayPlan` nil.

- [ ] **Step 3: Extend the system prompt**

In `LongformThematicService.thematicSystemPrompt`, replace the "КРОК 2" moment instruction and add a plan section. Keep all Ukrainian-language rules. Insert before `ФОРМАТ ВИВОДУ`:

```text
        СТРУКТУРА ЕСЕ (5 аналітичних актів, саме в цьому порядку):
        1. hook — обіцянка/парадокс, який утримує глядача; 1-2 речення, без переказу фіналу.
        2. form — як фільм зроблений: монтаж, ритм, повторювані прийоми, структура сцен.
        3. psychology — що насправді рухає героєм: страх, бажання, захист, самообман.
        4. philosophy — прихований підтекст: що фільм каже про людину, свободу, владу, вибір.
        5. catharsis — розв'язка думки: що змінюється в глядачеві після цього аналізу.
        Дай 3 варіанти хука (hookVariants) і 2 варіанти заклику до дії (ctaVariants) українською.
        Для кожного акта сформулюй у actFocus, ЩО САМЕ цей акт доводить у цьому фільмі.
        Кожній сцені в selectedMoments признач actRole з цього списку: hook|form|psychology|philosophy|catharsis.
        supports — одним реченням, який тезис акта доводить сцена; featured=true лише для найсильніших 1-2 сцен акта.
        НЕ вигадуй конкретних візуальних деталей (кольори, ракурси, реквізит), яких немає в діалогах:
        акт form описуй через структуру, монтаж і ритм, які виводяться з матеріалу.
```

Add `essayPlan` to the JSON skeleton and `actRole`/`supports`/`featured` to the first moment example. Keep the JSON strictly valid.

- [ ] **Step 4: Extend the user prompt in `MomentFinderService.analyzeThematicCore`**

Replace the trailing instruction block with:

```swift
        promptParts.append("""
            Обери ОДНУ ГОЛОВНУ тему есе (primaryConcept), докладно обґрунтуй вибір (aiReasoning).
            Склади план есе (essayPlan): thesis, 3 hookVariants, 2 ctaVariants, actFocus для form/psychology/philosophy/catharsis.
            ВИЗНАЧ 8-14 КОНКРЕТНИХ МОМЕНТІВ для монтажу (selectedMoments) з точними таймкодами.
            Кожному моменту признач actRole (hook|form|psychology|philosophy|catharsis), supports і featured.
            Розподіляй сцени за РОЛЛЮ В ІСТОРІЇ, а не рівномірно по хронометражу: хук може бути з будь-якої частини фільму.
            ТАЙМКОДИ — секунди від початку фільму: якщо дія біля діалогу [754.5], то startTime ≈ 754.5.
            Запропонуй альтернативні грані (alternativeConcepts).
            Поверни СУВОРО валідний JSON-об'єкт у форматі системної інструкції.
            """)
```

- [ ] **Step 5: Implement tolerant parsing**

Add in `LongformThematicService`:

```swift
    static func parseEssayPlan(_ value: Any?) -> EssayPlan? {
        guard let dict = value as? [String: Any] else { return nil }
        let hooks = parseTextVariants(dict["hookVariants"])
        let ctas = parseTextVariants(dict["ctaVariants"])
        var focus: [String: String] = [:]
        if let rawFocus = dict["actFocus"] as? [String: Any] {
            for (key, raw) in rawFocus {
                guard let type = LongformActType(promptKey: key),
                      let text = nonEmptyString(raw) else { continue }
                let filtered = filterNonCyrillic(text)
                if !filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    focus[type.promptKey] = filtered
                }
            }
        }
        let thesis = nonEmptyString(dict["thesis"]).map(filterNonCyrillic)
        guard thesis != nil || !hooks.isEmpty || !ctas.isEmpty || !focus.isEmpty else { return nil }
        return EssayPlan(
            thesis: thesis,
            hookVariants: Array(hooks.prefix(3)),
            selectedHook: hooks.first,
            ctaVariants: Array(ctas.prefix(2)),
            selectedCTA: ctas.first,
            actFocus: focus
        )
    }

    private static func parseTextVariants(_ value: Any?) -> [EssayPlan.TextVariant] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry in
            let raw: String?
            if let text = entry as? String { raw = text }
            else if let dict = entry as? [String: Any] { raw = nonEmptyString(dict["text"]) }
            else { raw = nil }
            guard let raw else { return nil }
            let filtered = filterNonCyrillic(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return filtered.isEmpty ? nil : EssayPlan.TextVariant(text: filtered, source: .llm)
        }
    }
```

Update `parseSelectedMoments`:

```swift
            let role = (dict["actRole"] as? String).flatMap(LongformActType.init(promptKey:))
            let supports = nonEmptyString(dict["supports"]).map(filterNonCyrillic)
            let featured = dict["featured"] as? Bool
            return SelectedMoment(
                startTime: startTime, endTime: endTime, reason: reason,
                dramaticWeight: weight, actRole: role, supports: supports, featured: featured
            )
```

Update `parseThematicAnalysis` to pass the plan:

```swift
            let plan = parseEssayPlan(root["essayPlan"])
            ...
            let filteredMoments = moments.map { moment in
                SelectedMoment(
                    startTime: moment.startTime, endTime: moment.endTime,
                    reason: filterNonCyrillic(moment.reason),
                    dramaticWeight: moment.dramaticWeight,
                    actRole: moment.actRole,
                    supports: moment.supports.map(filterNonCyrillic),
                    featured: moment.featured
                )
            }
            return makeResult(..., plan: plan)
```

and in `makeResult` add `plan: EssayPlan?` parameter and `essayPlan: plan` in the result init. Pass `nil` in the array-fallback branch.

- [ ] **Step 6: Run parsing tests**

Run: `xcodebuild ... test -only-testing:ShortcastTests/ThematicParsingTests`
Expected: PASS. Then run `ThematicServiceFixesTests` and `ThematicDiscoveryIntegrationTests`.

- [ ] **Step 7: Commit**

```bash
git add Shortcast/Services/Longform/LongformThematicService.swift Shortcast/Services/MomentFinderService.swift ShortcastTests/ThematicParsingTests.swift
git commit -m "feat: director proposes essay plan and scene roles"
```

---

### Task 3: Analytic arc assembly and dynamic act titling

**Files:**
- Modify: `Shortcast/Services/Longform/LongformNarrativeDirecting.swift`
- Modify: `Shortcast/Services/Longform/LongformNarrativeDirector.swift`
- Modify: `Shortcast/Services/Longform/LongformActTitleService.swift`
- Test: `ShortcastTests/ActBalancingAndCreditsTests.swift`
- Test: `ShortcastTests/LongformActTitleTests.swift`

**Interfaces:**
- Consumes: `EssayPlan`, `LongformActType.canonicalAnalyticOrder`, `SelectedMoment.actRole/featured`
- Produces:
  - `buildArc(from:concept:selectedMoments:movieTitle:targetDuration:essayPlan:)`
  - `buildArcHeuristic` clamp 300…900
  - `parseActTitleProposals(from:expectedTypes:)`
  - `LongformNarrativeDirector.adaptiveActDescriptor(for:concept:)`

- [ ] **Step 1: Write failing arc tests**

Add to `ShortcastTests/ActBalancingAndCreditsTests.swift`:

```swift
private func planned(_ start: Double, _ end: Double, _ role: LongformActType?, weight: Double = 0.5, featured: Bool? = nil) -> SelectedMoment {
    SelectedMoment(startTime: start, endTime: end, reason: "scene", dramaticWeight: weight,
                   actRole: role, supports: nil, featured: featured)
}

@Test func analyticArcBuildsFiveActsByRole() async throws {
    let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 1200, text: "Тестовий транскрипт")
    ], language: "uk")
    let concept = ThematicConcept(word: "КОНТРОЛЬ", tagline: "т", philosophicalPremise: "п",
                                  suggestedTitle: "з", accentColorHex: "#FFFFFF")
    let moments = [
        planned(10, 30, .hook, weight: 0.9, featured: true),
        planned(100, 130, .form),
        planned(200, 240, .psychology),
        planned(300, 340, .philosophy),
        planned(400, 440, .catharsis, weight: 0.95)
    ]
    let plan = EssayPlan(thesis: "Контроль — це страх",
                         hookVariants: [.init(text: "Ти контролюєш усе, крім себе.")],
                         targetDuration: 480,
                         actFocus: ["philosophy": "свобода"])
    let arc = try await LongformNarrativeDirector().buildArc(
        from: transcript, concept: concept, selectedMoments: moments,
        movieTitle: "Test", targetDuration: 520, essayPlan: plan
    )
    #expect(arc.acts.map(\.type) == LongformActType.canonicalAnalyticOrder)
    #expect(arc.acts.allSatisfy { !$0.segments.isEmpty })
    #expect(arc.hookText == "Ти контролюєш усе, крім себе.")
    #expect(arc.thesis == "Контроль — це страх")
    #expect(arc.acts[3].dramaticBeat == "свобода")
}

@Test func rolelessMomentsKeepLegacyFourActPath() async throws {
    let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 1000, text: "Тестовий транскрипт")
    ], language: "uk")
    let concept = ThematicConcept(word: "СТРАХ", tagline: "т", philosophicalPremise: "п",
                                  suggestedTitle: "з", accentColorHex: "#FFFFFF")
    let moments = [moment(50, 80), moment(300, 330), moment(600, 640), moment(800, 840)]
    let arc = try await LongformNarrativeDirector().buildArc(
        from: transcript, concept: concept, selectedMoments: moments,
        movieTitle: "Test", targetDuration: 520
    )
    #expect(arc.acts.count == 4)
    #expect(arc.acts.map(\.type) == [.hook, .downfall, .struggle, .catharsis])
}
```

Add to `ShortcastTests/LongformActTitleTests.swift`:

```swift
@Test func fiveActProposalsRequireFiveCanonicalRows() {
    let json = """
    {"acts":[
      {"type":"hook","title":"Обіцянка","quotedLine":"a"},
      {"type":"form","title":"Ритм","quotedLine":"b"},
      {"type":"psychology","title":"Страх","quotedLine":"c"},
      {"type":"philosophy","title":"Свобода","quotedLine":"d"},
      {"type":"catharsis","title":"Вибір","quotedLine":"e"}
    ]}
    """
    let parsed = LongformActTitleService.parseActTitleProposals(
        from: json, expectedTypes: LongformActType.canonicalAnalyticOrder)
    #expect(parsed?.map(\.type) == LongformActType.canonicalAnalyticOrder)
    #expect(LongformActTitleService.parseActTitleProposals(from: json) == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild ... test -only-testing:ShortcastTests/ActBalancingAndCreditsTests -only-testing:ShortcastTests/LongformActTitleTests`
Expected: compile failure on `essayPlan:` and `expectedTypes:`.

- [ ] **Step 3: Extend the director protocol**

In `LongformNarrativeDirecting.swift`:

```swift
    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        selectedMoments: [SelectedMoment],
        movieTitle: String,
        targetDuration: Double,
        essayPlan: EssayPlan?
    ) async throws -> LongformNarrativeArc
```

- [ ] **Step 4: Implement analytic assembly**

In `LongformNarrativeDirector` change `buildArc` signature to:

```swift
    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        selectedMoments: [SelectedMoment],
        movieTitle: String,
        targetDuration: Double = 520.0,
        essayPlan: EssayPlan? = nil
    ) async throws -> LongformNarrativeArc {
        let requested = essayPlan?.targetDuration.map { $0 } ?? targetDuration
        let clampedAsk = min(max(requested, 300.0), 900.0)
        ...
        if !sanitizedMoments.isEmpty {
            if let plan = essayPlan,
               Self.analyticCoverage(of: sanitizedMoments) >= 3 {
                return try buildAnalyticArc(
                    selectedMoments: sanitizedMoments,
                    transcript: transcript,
                    concept: concept,
                    movieTitle: movieTitle,
                    targetDuration: clampedAsk,
                    plan: plan
                )
            }
            return try buildArcFromSelectedMoments(...)
        }
```

Add helpers:

```swift
    static func analyticCoverage(of moments: [SelectedMoment]) -> Int {
        Set(moments.compactMap(\.actRole).filter { LongformActType.canonicalAnalyticOrder.contains($0) }).count
    }

    private func buildAnalyticArc(
        selectedMoments: [SelectedMoment],
        transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double,
        plan: EssayPlan
    ) throws -> LongformNarrativeArc {
        let totalMovieDuration = transcript.segments.last?.end ?? targetDuration
        let creditsCutoff = totalMovieDuration * 0.95
        let filtered = selectedMoments.filter { $0.endTime < creditsCutoff }
        let moments = filtered.isEmpty ? selectedMoments : filtered

        var buckets: [LongformActType: [SelectedMoment]] = [:]
        for type in LongformActType.canonicalAnalyticOrder { buckets[type] = [] }
        for moment in moments {
            if let role = moment.actRole, buckets[role] != nil {
                buckets[role]?.append(moment)
            }
        }
        // Сцены без роли — в самый «голодный» по хронометражу аналитический акт.
        for moment in moments where moment.actRole == nil || buckets[moment.actRole!] == nil {
            let target = LongformActType.canonicalAnalyticOrder.min {
                bucketDuration(buckets[$0] ?? []) < bucketDuration(buckets[$1] ?? [])
            } ?? .psychology
            buckets[target]?.append(moment)
        }
        for type in LongformActType.canonicalAnalyticOrder {
            buckets[type]?.sort { $0.startTime < $1.startTime }
        }

        // Каждый акт получает хотя бы одну сцену, если есть донор с >1.
        for type in LongformActType.canonicalAnalyticOrder where (buckets[type] ?? []).isEmpty {
            guard let donor = LongformActType.canonicalAnalyticOrder
                .filter({ ($0 != type) && (buckets[$0]?.count ?? 0) > 1 })
                .max(by: { bucketDuration(buckets[$0] ?? []) < bucketDuration(buckets[$1] ?? []) })
            else { continue }
            let candidate = (buckets[donor] ?? []).min {
                let a = min(abs($0.startTime - nearestBoundary(type, buckets: buckets)),
                            abs($0.endTime - nearestBoundary(type, buckets: buckets)))
                let b = min(abs($1.startTime - nearestBoundary(type, buckets: buckets)),
                            abs($1.endTime - nearestBoundary(type, buckets: buckets)))
                return a < b
            }
            guard let candidate,
                  let index = buckets[donor]?.firstIndex(of: candidate) else { continue }
            buckets[donor]?.remove(at: index)
            buckets[type] = [candidate]
        }

        trimToBudget(&buckets, target: targetDuration * 1.10)

        var acts: [LongformAct] = []
        for type in LongformActType.canonicalAnalyticOrder {
            let scenes = buckets[type] ?? []
            guard !scenes.isEmpty else { continue }
            acts.append(LongformAct(
                type: type,
                title: "",
                dramaticBeat: plan.focus(for: type) ?? scenes.first?.reason ?? "Тема «\(concept.word)»",
                segments: scenes.map { TimeSegment(start: $0.startTime, end: $0.endTime) }
            ))
        }
        guard !acts.isEmpty else {
            return try buildArcFromSelectedMoments(
                selectedMoments: moments, transcript: transcript, concept: concept,
                movieTitle: movieTitle, targetDuration: targetDuration
            )
        }
        return LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: concept,
            acts: acts,
            summary: "Analytic plan: \(moments.count) moments across \(acts.count) acts",
            mood: "dramatic",
            hookText: plan.chosenHook,
            ctaText: plan.chosenCTA,
            thesis: plan.thesis
        )
    }
```

Add supporting helpers:

```swift
    private func bucketDuration(_ moments: [SelectedMoment]) -> Double {
        moments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
    }

    private func nearestBoundary(_ type: LongformActType, buckets: [LongformActType: [SelectedMoment]]) -> Double {
        guard let index = LongformActType.canonicalAnalyticOrder.firstIndex(of: type) else { return 0 }
        let order = LongformActType.canonicalAnalyticOrder
        if index > 0, let previous = buckets[order[index - 1]]?.last { return previous.endTime }
        if index + 1 < order.count, let next = buckets[order[index + 1]]?.first { return next.startTime }
        return 0
    }

    private func trimToBudget(_ buckets: inout [LongformActType: [SelectedMoment]], target: Double) {
        func total() -> Double {
            buckets.values.reduce(0) { $0 + bucketDuration($1) }
        }
        while total() > target {
            let removable = LongformActType.canonicalAnalyticOrder.compactMap { type -> (LongformActType, Int, SelectedMoment)? in
                guard let scenes = buckets[type], scenes.count > 1 else { return nil }
                let candidates = scenes.enumerated().filter { !($0.element.featured ?? false) }
                guard let weakest = candidates.min(by: { $0.element.dramaticWeight < $1.element.dramaticWeight })
                else { return nil }
                return (type, weakest.offset, weakest.element)
            }.min(by: { $0.2.dramaticWeight < $1.2.dramaticWeight })
            guard let (type, index, _) = removable else { break }
            buckets[type]?.remove(at: index)
        }
    }
```

Preserve roles through sanitation in `sanitizeSelectedMoments`: when expanding a short moment, and when merging overlaps, build `SelectedMoment` with `actRole:`, `supports:`, `featured:`. For a merge, carry metadata from the moment with the higher `dramaticWeight`:

```swift
                let primary = raw.dramaticWeight >= last.dramaticWeight ? raw : last
                clean[clean.count - 1] = SelectedMoment(
                    startTime: last.startTime,
                    endTime: max(last.endTime, end),
                    reason: primary.reason,
                    dramaticWeight: max(last.dramaticWeight, raw.dramaticWeight),
                    actRole: primary.actRole,
                    supports: primary.supports,
                    featured: (last.featured ?? false) || (raw.featured ?? false)
                )
```

Apply the same field pass-through in the non-merge branch.

Also attach plan texts to the legacy 4-act path: add `hookText/ctaText/thesis` parameters to `buildArcFromSelectedMoments` (default nil) and pass `plan?.chosenHook` etc. from `buildArc`; return them in the arc. Do not use roles there.

- [ ] **Step 5: Dynamic act titling**

In `LongformActTitleService`:

- `applyTitles`: replace `let templates = LongformNarrativeDirector().adaptiveActDescriptors(for: arc.concept)` with per-act descriptors:

```swift
        let director = LongformNarrativeDirector()
        let templates = arc.acts.map { director.adaptiveActDescriptor(for: $0.type, concept: arc.concept) }
```

- `requestProposals(..., expectedTypes: [LongformActType])`; build prompts with them; parse with them.
- `actTitlesSystemPrompt(movieTitle:concept:expectedTypes:)` builds:
  - `let typeList = expectedTypes.map(\.promptKey).joined(separator: ", ")`
  - JSON skeleton via `expectedTypes.map { "{\"type\":\"\($0.promptKey)\",\"title\":\"...\",\"dramaticBeat\":\"...\",\"quotedLine\":\"...\"}" }.joined(separator: ",")`
  - instruction text uses `typeList` instead of the hardcoded four.
- `actTitlesUserPrompt(..., expectedTypes:)` says `Назви всі \(expectedTypes.count) актів ... з \(expectedTypes.count) елементів`.
- `parseActTitleProposals(from:expectedTypes:)` defaults to `[.hook, .downfall, .struggle, .catharsis]`; requires `rows.count == expectedTypes.count`; zips; uses `actType(forKey:)`.
- `actType(forKey:)` add: `"form"`/`"форма"` → `.form`; `"psychology"`/`"психологія"` → `.psychology`; `"philosophy"`/`"філософія"` → `.philosophy`.
- `actMaterialBlock` roman list extend to `["I","II","III","IV","V","VI"]`.
- Add `LongformNarrativeDirector.adaptiveActDescriptor(for:concept:)`:

```swift
    func adaptiveActDescriptor(for type: LongformActType, concept: ThematicConcept) -> (title: String, beat: String) {
        let word = concept.word.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        switch type {
        case .hook:
            return ("Зародження «\(word)»", "Відкриваючий виклик і перший крок назустріч невідомому.")
        case .form:
            return ("Мова «\(word)»", "Як влаштована форма: монтаж, ритм і повторювані прийоми.")
        case .psychology:
            return ("Під маскою", "Що насправді рухає героєм: страх, бажання і самообман.")
        case .philosophy:
            return ("Ціна «\(word)»", "Прихований підтекст: що фільм каже про людину і вибір.")
        case .catharsis:
            return ("Прозріння", "Катарсис: осягнення справжнього сенсу та ціни пройденого шляху.")
        case .downfall:
            return ("Випробування сумнівом", "Криза та зіткнення з суворою реальністю.")
        case .struggle:
            return ("Точка зламу", "Боротьба на межі сил всупереч усім обставинам.")
        }
    }
```

Keep `adaptiveActDescriptors(for:)` as the legacy 4-item array built from this helper:

```swift
    func adaptiveActDescriptors(for concept: ThematicConcept) -> [(title: String, beat: String)] {
        [.hook, .downfall, .struggle, .catharsis].map { adaptiveActDescriptor(for: $0, concept: concept) }
    }
```

- [ ] **Step 6: Range clamp**

Change `buildArcHeuristic` clamp to `min(max(targetDuration, 300.0), 900.0)`.

- [ ] **Step 7: Run arc and titling tests**

Run: `xcodebuild ... test -only-testing:ShortcastTests/ActBalancingAndCreditsTests -only-testing:ShortcastTests/LongformActTitleTests -only-testing:ShortcastTests/SentenceBoundaryTests`
Expected: PASS (legacy 4-act assertions untouched; new 5-act test passes).

- [ ] **Step 8: Commit**

```bash
git add Shortcast/Services/Longform/LongformNarrativeDirecting.swift Shortcast/Services/Longform/LongformNarrativeDirector.swift Shortcast/Services/Longform/LongformActTitleService.swift ShortcastTests/ActBalancingAndCreditsTests.swift ShortcastTests/LongformActTitleTests.swift
git commit -m "feat: assemble analytic five-act arc by scene roles"
```

---

### Task 4: Thread the plan through pipeline, persistence, and metadata

**Files:**
- Modify: `Shortcast/Services/Longform/LongformPipelineCoordinating.swift`
- Modify: `Shortcast/Services/Longform/LongformPipelineCoordinator.swift`
- Modify: `Shortcast/Services/WorkspaceModel.swift`
- Modify: `Shortcast/Services/Longform/LongformMetadataGenerator.swift`
- Test: `ShortcastTests/FilmProjectTests.swift`
- Test: `ShortcastTests/PersistenceAndModelInjectionTests.swift`

**Interfaces:**
- Consumes: `EssayPlan.effectiveTargetDuration`, `arc.hookText/ctaText/thesis`
- Produces:
  - `buildLongformVideo(..., essayPlan: EssayPlan?)`
  - `WorkspaceModel.confirmLongformConcept(..., essayPlan:)`
  - `WorkspaceModel.stagedEssayPlan`
  - metadata description/pinned comment use plan texts

- [ ] **Step 1: Write failing persistence/metadata tests**

Add to `ShortcastTests/FilmProjectTests.swift`:

```swift
@Test func projectPersistsEssayPlanAndArcTexts() async throws {
    let plan = EssayPlan(
        thesis: "Контроль — це страх",
        hookVariants: [.init(text: "Ти контролюєш усе, крім себе.")],
        ctaVariants: [.init(text: "Напиши свою відповідь.")],
        targetDuration: 660
    )
    let concept = ThematicConcept(word: "КОНТРОЛЬ", tagline: "т", philosophicalPremise: "п",
                                  suggestedTitle: "з", accentColorHex: "#FFFFFF", source: .llm)
    let analysis = ThematicAnalysisResult(primaryConcept: concept, aiReasoning: "р",
                                          selectedMoments: [], essayPlan: plan, source: .llm)
    let arc = LongformNarrativeArc(movieTitle: "Test", concept: concept, acts: [],
                                   summary: "s", hookText: plan.chosenHook,
                                   ctaText: plan.chosenCTA, thesis: plan.thesis)
    let encoded = try JSONEncoder().encode(analysis)
    let decoded = try JSONDecoder().decode(ThematicAnalysisResult.self, from: encoded)
    #expect(decoded.essayPlan == plan)
    let arcDecoded = try JSONDecoder().decode(LongformNarrativeArc.self, from: JSONEncoder().encode(arc))
    #expect(arcDecoded.hookText == plan.chosenHook)
    #expect(arcDecoded.ctaText == plan.chosenCTA)
    #expect(arcDecoded.thesis == plan.thesis)
}
```

Add to a test file that can call the generator (any test target file; use `PersistenceAndModelInjectionTests.swift`):

```swift
@Test func metadataUsesHookThesisAndCTA() {
    let concept = ThematicConcept(word: "КОНТРОЛЬ", tagline: "т", philosophicalPremise: "п",
                                  suggestedTitle: "з", accentColorHex: "#FFFFFF", source: .llm)
    let arc = LongformNarrativeArc(
        movieTitle: "Test", concept: concept, acts: [],
        summary: "s",
        hookText: "Ти контролюєш усе, крім себе.",
        ctaText: "Напиши, від чого ти не відпустив.",
        thesis: "Контроль — це страх"
    )
    let meta = LongformMetadataGenerator.generate(movieTitle: "Test", concept: concept, arc: arc)
    #expect(meta.description.contains("Ти контролюєш усе, крім себе."))
    #expect(meta.description.contains("Контроль — це страх"))
    #expect(meta.pinnedComment.contains("Напиши, від чого ти не відпустив."))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:ShortcastTests/FilmProjectTests -only-testing:ShortcastTests/PersistenceAndModelInjectionTests`
Expected: compile failure on init parameters.

- [ ] **Step 3: Protocol and coordinator**

In `LongformPipelineCoordinating` add `essayPlan: EssayPlan?` after `selectedMoments: [SelectedMoment]` in the core method. Update every convenience overload to pass `essayPlan: nil`.

In `LongformPipelineCoordinator.buildLongformVideo` add the parameter and:

```swift
        let targetDuration = essayPlan?.effectiveTargetDuration ?? 520.0
        ...
        let built = try await director.buildArc(
            from: transcript,
            concept: concept,
            selectedMoments: selectedMoments,
            movieTitle: movieTitle,
            targetDuration: targetDuration,
            essayPlan: essayPlan
        )
```

Pass `hookText: arc.hookText, ctaText: arc.ctaText` into `makeOverlayLayer` after the renderer task.

- [ ] **Step 4: WorkspaceModel threading**

- Add `var stagedEssayPlan: EssayPlan? = nil` next to `stagedAudioSettings`/`stagedArc`.
- `openLongformSubtitleEditor(_:confirmedMovieTitle:audioSettings:essayPlan:settings:)` with `essayPlan: EssayPlan? = nil`; set `stagedEssayPlan = essayPlan`; pass `targetDuration: essayPlan?.effectiveTargetDuration ?? 520` and `essayPlan: essayPlan` to `buildArc`.
- `confirmLongformConcept` both overloads: add `essayPlan: EssayPlan? = nil` and forward.
- `confirmLongformSubtitlesAndBuild`: pass `essayPlan: stagedEssayPlan`.
- `confirmLongformConceptInternal`: add `essayPlan: EssayPlan?`; before starting the task, persist:

```swift
        if let essayPlan {
            self.thematicAnalysis?.essayPlan = essayPlan
            self.currentProject?.thematicAnalysis = self.thematicAnalysis
            await? // it is sync before Task: schedule persist
        }
        self.stagedEssayPlan = essayPlan
        Task { await persistThemeState(reason: "essay-plan") }
```

(The method is synchronous; use `Task { await self.persistThemeState(reason: "essay-plan") }`.)

- Pass `essayPlan: essayPlan` into `coordinator.buildLongformVideo`.
- `regenerateLongformFromScratch`: pass `essayPlan: stagedEssayPlan ?? thematicAnalysis?.essayPlan`.
- `startLongformRebuild`: pass `essayPlan: stagedEssayPlan ?? thematicAnalysis?.essayPlan`.
- Reset `stagedEssayPlan = nil` in `resetLongform`/`startOver` where staged state is cleared.

- [ ] **Step 5: Metadata**

`generate`: compute and pass `arc.hookText`, `arc.thesis`, `arc.ctaText`:

```swift
        let desc = buildPrrodanDescription(
            movieTitle: movieTitle,
            safeMovieTitle: safeMovieTitle,
            concept: concept,
            chaptersText: chaptersText,
            hook: arc.hookText,
            thesis: arc.thesis
        )
        ...
        let pinnedComment = buildPrrodanPinnedComment(
            movieTitle: displayMovieTitle, concept: concept, cta: arc.ctaText)
```

In `buildPrrodanDescription` add optional `hook`/`thesis` params and prepend:

```swift
        let opening: String
        if let hook, !hook.isEmpty {
            opening = hook
        } else if let thesis, !thesis.isEmpty {
            opening = thesis
        } else {
            opening = "Це відео — про інший бік \(movieRef)."
        }
```

Use `opening` as the first line, and include thesis as its own paragraph when both exist:

```swift
        let thesisBlock = (thesis?.isEmpty == false && thesis != hook) ? "\n\n\(thesis!)" : ""
```

In `buildPrrodanPinnedComment` add `cta: String?`; when non-empty use it as the first paragraph, keep the question line.

- [ ] **Step 6: Run tests**

Run: `xcodebuild ... test -only-testing:ShortcastTests/FilmProjectTests -only-testing:ShortcastTests/PersistenceAndModelInjectionTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shortcast/Services/Longform/LongformPipelineCoordinating.swift Shortcast/Services/Longform/LongformPipelineCoordinator.swift Shortcast/Services/WorkspaceModel.swift Shortcast/Services/Longform/LongformMetadataGenerator.swift ShortcastTests/FilmProjectTests.swift ShortcastTests/PersistenceAndModelInjectionTests.swift
git commit -m "feat: thread essay plan through build, persistence and metadata"
```

---

### Task 5: Render hook and CTA layers

**Files:**
- Modify: `Shortcast/Services/Longform/LongformSubtitleRenderingProtocol.swift`
- Modify: `Shortcast/Services/Longform/LongformSubtitleRenderer.swift`
- Test: `ShortcastTests/ChannelLogoWatermarkTests.swift`
- Test: `ShortcastTests/LongformThumbnailGeneratorTests.swift`

**Interfaces:**
- Produces: `makeOverlayLayer(..., hookText: String?, ctaText: String?)`; nil keeps the old 4.5 s tagline behavior and the old 4/5 sublayer count.

- [ ] **Step 1: Write failing renderer tests**

Add to `ShortcastTests/ChannelLogoWatermarkTests.swift`:

```swift
@Test func hookAndCTALayersAppearOnlyWhenProvided() async {
    let renderer = LongformSubtitleRenderer()
    let concept = ThematicConcept(word: "КОНТРОЛЬ", tagline: "т", philosophicalPremise: "п",
                                  suggestedTitle: "з", accentColorHex: "#FFFFFF")
    let size = CGSize(width: 1920, height: 1080)
    let phrases = [TimedSubtitlePhrase(start: 1, end: 5, text: "Реплика под хуком")]

    let withTexts = await renderer.makeOverlayLayer(
        renderSize: size, concept: concept, timedPhrases: phrases,
        acts: [], actStartTimes: [], totalDuration: 120,
        layout: LongformOverlayLayout(channelLogo: nil),
        hookText: "Ти контролюєш усе, крім себе.",
        ctaText: "Напиши, від чого ти не відпустив."
    )
    #expect(withTexts.sublayers?.count == 5)

    let withoutTexts = await renderer.makeOverlayLayer(
        renderSize: size, concept: concept, timedPhrases: phrases,
        acts: [], actStartTimes: [], totalDuration: 120,
        layout: LongformOverlayLayout(channelLogo: nil)
    )
    #expect(withoutTexts.sublayers?.count == 4)
}

@Test func subtitlesStayHiddenUnderHookUntilSixSeconds() async {
    let renderer = LongformSubtitleRenderer()
    let concept = ThematicConcept(word: "КОНТРОЛЬ", tagline: "т", philosophicalPremise: "п",
                                  suggestedTitle: "з", accentColorHex: "#FFFFFF")
    let phrases = [TimedSubtitlePhrase(start: 1, end: 5, text: "Рання репліка")]
    let root = await renderer.makeOverlayLayer(
        renderSize: CGSize(width: 1920, height: 1080), concept: concept,
        timedPhrases: phrases, acts: [], actStartTimes: [], totalDuration: 120,
        layout: LongformOverlayLayout(channelLogo: nil),
        hookText: "Хук", ctaText: nil
    )
    let subtitleBand = try? #require(root.sublayers?[1])
    #expect(subtitleBand?.sublayers?.isEmpty ?? true)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild ... test -only-testing:ShortcastTests/ChannelLogoWatermarkTests`
Expected: compile failure on new parameters.

- [ ] **Step 3: Protocol**

Add `hookText: String? = nil, ctaText: String? = nil` to the core requirement and every overload (pass-through). Update the doc comment: layer order becomes `[0]` word, `[1]` subtitles, `[2]` intro/hook, `[3]` act cards, `[4]` CTA (only when `ctaText != nil`), logo last.

- [ ] **Step 4: Renderer**

- Compute suppression:

```swift
        let hook = hookText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHook = !(hook ?? "").isEmpty
        let introEnd = hasHook ? 6.2 : 4.5
```

Pass `introEnd` to `buildSynchronizedSubtitlesLayer` and replace the two hardcoded constants `4.5`/`4.55` with `introEnd`/`introEnd + 0.05`.

- `buildIntroTaglineLayer(..., hookText: String?)`: choose `hook ?? tagline`; when `hasHook`, animation key times `0.0 / 0.8 / 5.2 / 6.0 / 1.0`; else keep existing. Use at most 3 lines via the existing bounding rect width.
- Add CTA:

```swift
        if let cta = ctaText?.trimmingCharacters(in: .whitespacesAndNewlines), !cta.isEmpty {
            let ctaLayer = buildFinalCTALayer(
                renderSize: renderSize, k: k, concept: concept,
                ctaText: cta, totalDuration: calculatedTotalDuration
            )
            rootLayer.addSublayer(ctaLayer)
        }
        appendChannelLogoBand(...)
```

`buildFinalCTALayer` renders a centered 2-line Russo One 30·k white text with a gold rule above it, placed in the lower-middle third (use `actCardY`-style vertical placement or `H*0.34`), fades in at `total - 4.2`, holds to `total - 0.7`, fades out at `total`. Implement with `renderAttributedText` and `CAKeyframeAnimation` exactly like the intro layer.

- [ ] **Step 5: Run renderer tests + all render-related suites**

Run: `xcodebuild ... test -only-testing:ShortcastTests/ChannelLogoWatermarkTests -only-testing:ShortcastTests/LongformThumbnailGeneratorTests -only-testing:ShortcastTests/ExportLayoutTests`
Expected: PASS; legacy calls still produce 4/5 sublayers.

- [ ] **Step 6: Commit**

```bash
git add Shortcast/Services/Longform/LongformSubtitleRenderingProtocol.swift Shortcast/Services/Longform/LongformSubtitleRenderer.swift ShortcastTests/ChannelLogoWatermarkTests.swift
git commit -m "feat: render essay hook card and final CTA"
```

---

### Task 6: Hook and duration selection in the concept sheet

**Files:**
- Modify: `Shortcast/Views/Longform/ThematicConceptSelectionSheet.swift`
- Modify: `Shortcast/Views/ContentView.swift`

**Interfaces:**
- Consumes: `EssayPlan`, `EssayPlan.TextVariant`
- Produces: `onSelect: (ThematicConcept, String, LongformAudioSettings, EssayPlan) -> Void`; sheet init `essayPlan: EssayPlan?`

- [ ] **Step 1: Sheet state and init**

Add:

```swift
    @State private var selectedHookIndex: Int = 0
    @State private var customHook: String = ""
    @AppStorage("shortcast.longform.essayDurationMinutes") private var essayDurationMinutes: Int = 11
```

Init parameter `essayPlan: EssayPlan? = nil`, store `initialEssayPlan`. Change `onSelect` signature.

- [ ] **Step 2: Hook section UI**

Above the audio section add:

```swift
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Хук (0:00–0:06)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Кликните вариант или впишите свой")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                let variants = initialEssayPlan?.hookVariants ?? []
                if !variants.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                            Button {
                                selectedHookIndex = index
                                customHook = ""
                            } label: {
                                Text(variant.text)
                                    .font(.caption)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(selectedHookIndex == index && customHook.isEmpty
                                      ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedHookIndex == index && customHook.isEmpty
                                        ? Color.yellow.opacity(0.7) : Color.clear))
                        }
                    }
                }
                TextField("Свой хук (1–2 предложения)", text: $customHook, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Text("Хук задаёт обещание эссе. Модель предложила варианты из диалогов; свой текст заменит их.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
```

- [ ] **Step 3: Duration presets UI**

Next to the hook section:

```swift
            HStack(spacing: 10) {
                Text("Хронометраж:")
                    .font(.subheadline.weight(.semibold))
                Picker("", selection: $essayDurationMinutes) {
                    Text("8 мин").tag(8)
                    Text("10 мин").tag(10)
                    Text("11 мин").tag(11)
                    Text("12 мин").tag(12)
                    Text("15 мин").tag(15)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.05)))
```

- [ ] **Step 4: Confirm action builds the plan**

Replace the `onSelect(chosen, finalTitle, audioSettings)` call:

```swift
                        let variants = initialEssayPlan?.hookVariants ?? []
                        let chosenHook: String? = customHook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? (variants.indices.contains(selectedHookIndex) ? variants[selectedHookIndex].text : variants.first?.text)
                            : customHook
                        let plan = (initialEssayPlan ?? EssayPlan()).confirming(
                            hookText: chosenHook,
                            ctaText: initialEssayPlan?.chosenCTA,
                            targetDuration: Double(essayDurationMinutes) * 60.0
                        )
                        onSelect(chosen, finalTitle, audioSettings, plan)
```

- [ ] **Step 5: ContentView wiring**

Pass `essayPlan: workspace.thematicAnalysis?.essayPlan` and accept the fourth parameter:

```swift
                onSelect: { concept, confirmedTitle, audioSettings, essayPlan in
                    workspace.confirmLongformConcept(
                        concept,
                        confirmedMovieTitle: confirmedTitle,
                        audioSettings: audioSettings,
                        essayPlan: essayPlan,
                        modelManager: modelManager,
                        settings: settings
                    )
                },
```

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project "Shortcast.xcodeproj" -scheme Shortcast build`
Expected: BUILD SUCCEEDED. There is no automated UI test for this sheet; verify visually by rebuilding and launching if available.

- [ ] **Step 7: Commit**

```bash
git add Shortcast/Views/Longform/ThematicConceptSelectionSheet.swift Shortcast/Views/ContentView.swift
git commit -m "feat: choose essay hook and duration in concept sheet"
```

---

### Task 7: Full verification

**Files:** none new.

- [ ] **Step 1: Run the whole test suite**

Run: `xcodebuild -project "Shortcast.xcodeproj" -scheme Shortcast test`
Expected: every suite passes, including legacy 4-act, sanitation, titles, renderer, persistence.

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project "Shortcast.xcodeproj" -scheme Shortcast build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit any test fixes**

```bash
git add -A
git commit -m "test: cover analytic essay plan end to end"
```

---

## Self-Review

- Spec coverage:
  - 5 analytic act types, canonical order, ratios → Task 1.
  - EssayPlan model, moment roles, optional persistence → Task 1.
  - Director prompt/schema + tolerant parsing → Task 2.
  - Role-based arc, budget trim, featured, ≥3 coverage, 4-act fallback, clamp 300–900 → Task 3.
  - Dynamic act titling for \(N\) acts → Task 3.
  - Pipeline/persistence/metadata threading → Task 4.
  - Hook card 0–6 s, subtitle suppression, CTA in final 4 s → Task 5.
  - Hook + duration UI → Task 6.
  - Compatibility (old enum raw values, optional fields, legacy heuristic) → Tasks 1, 3, 7.
- Out-of-scope items from the spec are not implemented: interactive scene reassignment, form grounding via `SceneDetectionService`, Shorts/TikTok scene.
- Type consistency: `essayPlan` label, `effectiveTargetDuration`, `chosenHook`/`chosenCTA`, `canonicalAnalyticOrder`, `promptKey`, `expectedTypes`, `stagedEssayPlan` are used consistently above.
