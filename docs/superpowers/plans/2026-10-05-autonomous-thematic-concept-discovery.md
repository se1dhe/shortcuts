# Autonomous Thematic Concept Discovery & Essay Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the Director LLM (Qwen 3.5 9B / Gemma 4) operates at 100% after Whisper transcription: analyzes the full stratified screenplay across all 4 acts, understands the underlying psychological and philosophical conflict, autonomously chooses and proposes ONE primary essay theme (e.g. «Эго» for *Revolver*), provides dramaturgical justification, and presents this chosen theme front-and-center in the UI.

**Architecture:**
- `ThematicConcept` & `ThematicAnalysisResult`: Expand the data model with `isPrimaryChoice`, `aiReasoning`, and a structured analysis container holding the AI's single chosen focus plus alternative lenses.
- `LongformThematicService`: Upgrade `stratifiedThematicSample` to sample rich dialogue across all 4 acts (up to 25,000 chars) without truncation; update system prompt to instruct the LLM to understand the narrative arc, formulate deep philosophical reasoning, and nominate exactly ONE primary theme. Eliminate shortcut that previously bypassed the LLM on bespoke films.
- `MomentFinderService`: Increase token limits and context slice so the full multi-act dialogue enters the prompt; parse the structured JSON into `ThematicAnalysisResult`.
- `WorkspaceModel`: Pre-select the AI's chosen theme automatically (`selectedConcept = analysisResult.primaryConcept`), store AI reasoning, and pass it to the UI.
- `ThematicConceptSelectionSheet`: Redesign the concept selection interface to feature the AI's chosen theme in a prominent Hero Card with explanation of why the AI selected it, while keeping alternative themes accessible below.

**Tech Stack:** Swift 6, SwiftUI, MLX / MLXLMCommon / Qwen 3.5 9B / Gemma 4, WhisperKit, AVFoundation.

---

## Global Constraints

- Adhere strictly to SOLID principles (Single Responsibility, Open-Closed, Liskov Substitution, Interface Segregation, Dependency Inversion).
- Never skip LLM inference when a model is available: the AI must always run on the actual Whisper transcript.
- Dialogue sampling must span all 4 acts of the film (Act I, Act II, Act III, Act IV) and not be cut off at 4500 characters.
- All user-facing UI text, prompts, and reasoning must be in Russian.
- Backward compatibility: existing `FilmProject` instances must decode cleanly without migration errors.

---

## Review Focus

1. **LLM execution on iconic films**: When running *Revolver*, the system must NOT silently fall back to hardcoded arrays; the LLM must execute on the Whisper transcript and identify «ЭГО» (or its core concept) dynamically.
2. **Dialogue coverage across all 4 acts**: Dialogue passed to the Director LLM must not truncate early (e.g. at 4500 characters), ensuring the model sees the climax and resolution.
3. **Structured single-focus extraction**: The LLM output parser must handle both new structured format (`primaryConcept` + `aiReasoning` + `alternativeConcepts`) and legacy arrays gracefully.
4. **UI auto-selection**: When the selection sheet opens, the AI's primary choice must already be selected and its reasoning displayed prominently.
5. **Project state persistence**: Saving and loading a `FilmProject` must preserve the AI analysis and reasoning without data loss.

---

## Task Decomposition

### Task 1: Expand Data Models with Single Focus & AI Reasoning
**Files:**
- Modify: `Shortcast/Models/ThematicConcept.swift`
- Modify: `Shortcast/Models/FilmProject.swift`
- Test: `ShortcastTests/ThematicConceptTests.swift`

**Interfaces:**
- Consumes: Existing `ThematicConcept` struct.
- Produces: `ThematicAnalysisResult` struct, updated `ThematicConcept` with `isPrimaryChoice` and `aiReasoning`.

- [ ] **Step 1: Write unit tests for `ThematicConcept` and `ThematicAnalysisResult` serialization**
```swift
@Test("ThematicAnalysisResult encodes and decodes correctly")
func testThematicAnalysisSerialization() throws {
    let primary = ThematicConcept(
        word: "ЭГО",
        tagline: "Твой главный враг прячется в твоей голове.",
        philosophicalPremise: "Победа над собой — единственный истинный триумф.",
        suggestedTitle: "Этот фильм уничтожит твою гордость.",
        accentColorHex: "#F5D020",
        isPrimaryChoice: true,
        aiReasoning: "Ключевой конфликт фильма строится вокруг борьбы с внутренним голосом."
    )
    let alt = ThematicConcept(
        word: "ОБМАН",
        tagline: "Единственный способ стать умнее — играть с более умным противником.",
        philosophicalPremise: "Манипуляция как искусство контроля.",
        suggestedTitle: "Ты проиграешь, если не поймешь эту игру.",
        accentColorHex: "#F5D020"
    )
    let result = ThematicAnalysisResult(
        primaryConcept: primary,
        aiReasoning: "Глубокий анализ сценария показывает, что эго управляет каждым шагом героя.",
        alternativeConcepts: [alt]
    )
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(ThematicAnalysisResult.self, from: data)
    #expect(decoded.primaryConcept.word == "ЭГО")
    #expect(decoded.primaryConcept.isPrimaryChoice == true)
    #expect(decoded.allConcepts.count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `SHORTCAST_SKIP_INSTALL=1 xcodebuild test -project Shortcast.xcodeproj -scheme Shortcast -destination 'platform=macOS'`
Expected: FAIL ("ThematicAnalysisResult not found" or compilation error).

- [ ] **Step 3: Implement `ThematicAnalysisResult` and update `ThematicConcept`**
Add `isPrimaryChoice: Bool = false` and `aiReasoning: String? = nil` to `ThematicConcept`.
Create `ThematicAnalysisResult` struct with `primaryConcept`, `aiReasoning`, `alternativeConcepts`, and computed `allConcepts`.
Update `FilmProject` to optionally store `thematicAnalysis: ThematicAnalysisResult?`.

- [ ] **Step 4: Run test to verify it passes**
Run: `SHORTCAST_SKIP_INSTALL=1 xcodebuild test -project Shortcast.xcodeproj -scheme Shortcast -destination 'platform=macOS'`
Expected: PASS.

- [ ] **Step 5: Commit changes**
`git add Shortcast/Models/ThematicConcept.swift Shortcast/Models/FilmProject.swift ShortcastTests/ThematicConceptTests.swift`
`git commit -m "feat: add ThematicAnalysisResult and AI reasoning fields to ThematicConcept"`

---

### Task 2: Re-architect Prompt & Full-Act Dialogue Stratification in `LongformThematicService`
**Files:**
- Modify: `Shortcast/Services/Longform/LongformThematicService.swift`
- Modify: `Shortcast/Services/Longform/ThematicConceptDiscovering.swift`
- Test: `ShortcastTests/ThematicParsingTests.swift`

**Interfaces:**
- Consumes: `Transcript`, `ThematicConcept`.
- Produces: `func discoverThematicAnalysis(...) async throws -> ThematicAnalysisResult`, `static func parseThematicAnalysis(from jsonText: String) -> ThematicAnalysisResult?`.

- [ ] **Step 1: Write test for `parseThematicAnalysis`**
Test parsing of structured JSON with `primaryConcept`, `aiReasoning`, and `alternativeConcepts`, as well as fallback parsing when LLM outputs a legacy JSON array.

- [ ] **Step 2: Run test to verify it fails**
Run test suite.
Expected: FAIL.

- [ ] **Step 3: Implement deep stratification and prompt in `LongformThematicService`**
1. Increase dialogue budget in `stratifiedThematicSample` to capture ~20,000 characters across all 4 acts with timestamps.
2. Update `thematicSystemPrompt`: instruct the model to act as a master dramaturg, deeply analyze the script, choose **ОДНУ ГЛАВНУЮ ТЕМУ** (e.g. «Эго» or what it deduced), provide `aiReasoning` explaining why this is the defining core of the film, and provide 3-4 alternative angles.
3. Remove the shortcut that returned hardcoded `bespokeConcepts` without running AI when `modelManager != nil`. Use `bespokeConcepts` only as a fallback if AI is unavailable or errors.
4. Implement `parseThematicAnalysis(from jsonText: String) -> ThematicAnalysisResult?`.
5. Update `discoverConcepts` and add `discoverThematicAnalysis`.

- [ ] **Step 4: Run test to verify it passes**
Run test suite.
Expected: PASS.

- [ ] **Step 5: Commit changes**
`git commit -m "feat: implement full-act dialogue sampling and autonomous single-theme analysis in LongformThematicService"`

---

### Task 3: Uncap Dialogue Limit & Return Full Analysis in `MomentFinderService`
**Files:**
- Modify: `Shortcast/Services/MomentFinderService.swift`
- Test: `ShortcastTests/ThematicParsingTests.swift`

**Interfaces:**
- Consumes: Full stratified screenplay text, `ModelContainer`.
- Produces: `func analyzeThematicCore(transcriptSample: String, movieTitle: String, movieOverview: String?) async -> ThematicAnalysisResult?`.

- [ ] **Step 1: Write test for `analyzeThematicCore` helper logic**
Ensure parsing and parameter preparation logic handles large dialogue samples without slicing down to 4500 chars.

- [ ] **Step 2: Run test to verify it fails**
Run test suite.
Expected: FAIL.

- [ ] **Step 3: Implement `analyzeThematicCore` in `MomentFinderService`**
1. In `MomentFinderService`: add `analyzeThematicCore` (and update `generateThematicConcepts` to delegate to it).
2. Remove `sample.prefix(4500)` truncation; allow up to 25,000 characters.
3. Increase `maxTokens` to 1600.
4. Parse output using `LongformThematicService.parseThematicAnalysis`.

- [ ] **Step 4: Run test to verify it passes**
Run test suite.
Expected: PASS.

- [ ] **Step 5: Commit changes**
`git commit -m "feat: enable full-context screenplay analysis and single theme deduction in MomentFinderService"`

---

### Task 4: Connect Autonomous Theme Selection in `WorkspaceModel`
**Files:**
- Modify: `Shortcast/Services/WorkspaceModel.swift`
- Modify: `Shortcast/Views/ContentView.swift`

**Interfaces:**
- Consumes: `ThematicAnalysisResult` from `LongformThematicService`.
- Produces: `workspace.selectedConcept`, `workspace.thematicReasoning`, `workspace.discoveredConcepts`.

- [ ] **Step 1: Update `WorkspaceModel` state**
Add `thematicReasoning: String?` property.
In `startLongformPipeline`:
1. Always prepare the Director model via `modelManager.prepareDirectorIfNeeded()`.
2. Call `discoverThematicAnalysis(from: transcript, movieTitle: effectiveMovieTitle, ...)`.
3. Auto-populate `self.selectedConcept = analysis.primaryConcept` with the AI's top chosen theme!
4. Set `self.thematicReasoning = analysis.aiReasoning`.
5. Set `self.discoveredConcepts = analysis.allConcepts`.
6. Update `regenerateThematicConcepts` to re-run full analysis.

- [ ] **Step 2: Update `ContentView.swift`**
Pass `aiReasoning: workspace.thematicReasoning` to `ThematicConceptSelectionSheet`.

- [ ] **Step 3: Verify build**
Run: `SHORTCAST_SKIP_INSTALL=1 xcodebuild -project Shortcast.xcodeproj -scheme Shortcast -configuration Debug -destination 'platform=macOS' build`
Expected: Build succeeds.

- [ ] **Step 4: Commit changes**
`git commit -m "feat: wire autonomous single-theme selection and AI reasoning into WorkspaceModel"`

---

### Task 5: Redesign `ThematicConceptSelectionSheet` with AI Choice Hero Card
**Files:**
- Modify: `Shortcast/Views/Longform/ThematicConceptSelectionSheet.swift`

**Interfaces:**
- Consumes: `concepts: [ThematicConcept]`, `aiReasoning: String?`, `primaryConcept: ThematicConcept?`.
- Produces: Hero UI card for AI's single chosen theme with reasoning, plus alternative concepts list.

- [ ] **Step 1: Implement AI Choice Hero Card in `ThematicConceptSelectionSheet`**
1. Add `aiReasoning: String?` property.
2. At the top of the sheet, render a prominent golden-bordered Hero Card:
   - Badge: **«ВЫБОР ИИ • ГЛАВНАЯ ТЕМА ЭССЕ»** (sparkles icon, yellow tint).
   - Word: Large bold concept word (e.g. **«ЭГО»**).
   - Tagline & Premise.
   - Expandable / visible **«Разбор сценария от ИИ»** showing `aiReasoning`.
   - Single-click action button: **«Выбрать эту тему (Рекомендовано ИИ)»**.
3. Below the Hero Card, add a collapsible / clear section **«Другие темы, найденные в сценарии»** with the alternative concepts.
4. Auto-highlight the primary concept by default when the sheet opens.

- [ ] **Step 2: Verify UI compilation & layout**
Run `xcodebuild` build.
Expected: Build succeeds.

- [ ] **Step 3: Commit changes**
`git commit -m "feat: add AI Choice Hero Card and dramaturgical reasoning to ThematicConceptSelectionSheet"`

---

### Task 6: Full Verification & Automated Tests
- [ ] Run test suite with `xcodebuild test`.
- [ ] Verify build and install to Applications via `./scripts/install-app.sh`.
- [ ] Verify that for any movie transcript (e.g. *Revolver*), the system discovers the script, selects ONE main theme like "Эго", provides deep justification, and preselects it.
