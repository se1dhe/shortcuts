# Longform Cinema Essay Complete Pipeline & Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish the 16:9 Cinema Essay generator with zero-overlap typography, movie-tailored AI concept generation (specifically matching films like *Revolver*), ambient soundtrack support with sidechain ducking, cinematic 2.5s fade-to-black/audio outro, one-click YouTube Studio browser automation upload, and a seamless chain to Shorts generation & Telegram campaign.

**Architecture:** 
- `LongformSubtitleRenderer`: Eliminate subtitle/intro collisions by delaying character speech subtitles until after the 4.5s title card, with smooth crossfade and safe vertical layout. Add 2.0s fade-out at composition end.
- `LongformThematicService` & `MomentFinderService`: Run structured LLM inference on the Whisper transcript + movie title to discover bespoke philosophical themes (e.g. *Эго*, *Обман*, *Страх* for *Revolver*), backed by high-quality curated movie presets.
- `LongformAudioMasteringService` & `BackgroundMusicService`: Integrate ambient background music selection with volume controls, automatic sidechain ducking under dialogue, and a 2.5s exponential audio fade-out to zero at the end.
- `LongformPipelineCoordinator`: Add AVVideoComposition video fade-to-black ramp over the last 2.5s and connect ambient music tracks into the composite asset.
- `LongformResultsView` & `BrowserAutomationService`: Provide a prominent «Опубликовать на YouTube» button triggering Chrome browser automation to YouTube Studio, a «Сгенерировать Shorts по фильму» transition reusing existing transcripts, and a Telegram channel announcement button.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation (AVMutableComposition, AVVideoCompositionLayerInstruction, AVAudioMix, AVVideoCompositionCoreAnimationTool), MLX / Qwen 3.5 9B (`MomentFinderService`), Browser Automation (Playwright / local Chrome), AppKit.

---

## Global Constraints

- Never show dialogue subtitles during the 0.0–4.5s intro title card.
- Never hardcode third-party links (Boosty, external channels). Use the user's settings channel (`@telonyx_club`).
- Never allow audio/video to abruptly cut off: always apply a smooth 2.5s fade to black and silence at the end of the video.
- Strictly adhere to SOLID principles and keep all changes localized, modular, and testable.
- All user-facing UI text in Russian.

---

## Review Focus

1. **Subtitle / Intro overlap**: At 0.0–4.5s, dialogue lines from the film must not render or collide with the intro tagline and line.
2. **Thematic relevance**: Themes for "Револьвер" (and arbitrary films) must be generated dynamically from dialogue/script analysis, avoiding generic templates like "Семья" on gangster/ego films.
3. **Audio ducking & Outro**: When ambient music is active, dialogue must remain crisp and intelligible (ducked to ~14%), and the last 2.5s must fade smoothly to 0 dBFS and complete black.
4. **Browser upload**: YouTube Studio browser automation must populate Title, Description, Tags, and select the correct longform 16:9 file.
5. **Shorts pipeline chaining**: Clicking "Generate Shorts" must transition directly to moment finding without re-extracting audio or re-transcribing Whisper.

---

## Task Decomposition

### Task 1: Fix Subtitle Overlap & Add Cinematic Fade-Out in `LongformSubtitleRenderer`
**Files:**
- Modify: `Shortcast/Services/Longform/LongformSubtitleRenderer.swift`

- [ ] In `buildSynchronizedSubtitlesLayer`: filter out dialogue phrases that end before 4.5s (`phrase.end <= 4.5`).
- [ ] For phrases that span across 4.5s (`phrase.start < 4.5 && phrase.end > 4.5`), clamp `pStart` to `4.55` so they fade in cleanly right after the tagline disappears.
- [ ] In `buildCentralConceptLayer`: add a fade-out animation for the central concept word during the last 2.0s (`totalDuration - 2.0 ... totalDuration`).
- [ ] In `buildSynchronizedSubtitlesLayer`: add a fade-out animation for any remaining subtitles in the last 2.0s.

### Task 2: Tailored Thematic Concept Generation for Films in `LongformThematicService`
**Files:**
- Modify: `Shortcast/Services/Longform/LongformThematicService.swift`
- Modify: `Shortcast/Services/MomentFinderService.swift`

- [ ] Add `discoverConceptsViaLLM(transcript: Transcript, movieTitle: String, container: ModelContainer?) async -> [ThematicConcept]` in `LongformThematicService`.
- [ ] Add bespoke movie presets for *Револьвер* (2005) in `fallbackConcepts`:
  - **Эго**: *«Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей собственной голове.»*
  - **Обман**: *«Единственный способ стать умнее — играть с более умным противником.»*
  - **Страх**: *«Страх потери контроля разрушает человека быстрее любой пули.»*
  - **Иллюзия**: *«Ты думаешь, что контролируешь ситуацию, но ситуация контролирует тебя.»*
- [ ] Add presets for *Бойцовский клуб*, *Крёстный отец*, *Тёмный рыцарь*.
- [ ] When `MomentFinderService` is ready, run LLM prompt on the first 100 dialogue segments to discover unique concepts before falling back.

### Task 3: Ambient Music Selection & Sidechain Ducking in `ThematicConceptSelectionSheet` & `LongformPipelineCoordinator`
**Files:**
- Modify: `Shortcast/Views/Longform/ThematicConceptSelectionSheet.swift`
- Modify: `Shortcast/Services/Longform/LongformPipelineCoordinator.swift`
- Modify: `Shortcast/Services/Longform/LongformAudioMasteringService.swift`
- Modify: `Shortcast/Services/BackgroundMusicSelector.swift`
- Modify: `Shortcast/Services/WorkspaceModel.swift`

- [ ] Provide bundled/curated ambient music options in `BackgroundMusicService` (Dark Cinema Ambient, Deep Philosophy, Suspense).
- [ ] Add Ambient Music section in `ThematicConceptSelectionSheet`:
  - Ambient Music Toggle (Вкл/Выкл)
  - Picker: Preset ambient tracks + «Выбрать аудиофайл с диска...» (`NSOpenPanel`)
  - Volume balance slider (default 18%).
- [ ] Update `onSelect` callback to pass `selectedMusicURL: URL?` and `musicVolume: Float`.
- [ ] In `LongformPipelineCoordinator`: attach ambient music track into `compMusicTrack` if provided.
- [ ] In `LongformAudioMasteringService`: implement audio fade-out to 0.0 in the final 2.5s for all tracks.
- [ ] In `LongformPipelineCoordinator`: add `AVVideoCompositionLayerInstruction.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0, timeRange: ...)` over the last 2.5s for a clean fade to black.

### Task 4: One-Click YouTube Studio Browser Upload in `LongformResultsView`
**Files:**
- Modify: `Shortcast/Views/Longform/LongformResultsView.swift`
- Modify: `Shortcast/Services/BrowserAutomationService.swift`

- [ ] Add primary action button: **«Опубликовать на YouTube»** with YouTube icon and prominent styling in `LongformResultsView`.
- [ ] Wire up to `BrowserAutomationService.shared.publish`:
  - Create `BrowserPublishJob` with `videoURL: result.outputURL`, `title: result.metadata.title`, `description: result.metadata.description`, `tags: result.metadata.tags`, `platform: .youtube`.
  - Present `BrowserPublishSheet` showing live browser automation logs and upload progress.

### Task 5: Chained Workflow: Generate Shorts from Current Film & Post to Telegram
**Files:**
- Modify: `Shortcast/Views/Longform/LongformResultsView.swift`
- Modify: `Shortcast/Services/WorkspaceModel.swift`
- Modify: `Shortcast/Services/TelegramPublishingService.swift`

- [ ] In `WorkspaceModel`: add `func generateShortsFromCurrentMovie(modelManager: ModelManager, settings: AppSettings)`.
  - Reuses the loaded `job` and `storedTranscript`.
  - Immediately transitions to `phase = .findingMoments` without re-transcribing.
- [ ] In `LongformResultsView`: add button **«Сгенерировать Shorts по фильму»**.
- [ ] In `LongformResultsView`: add **«Поделиться в Telegram»** button:
  - Formats a message with movie card (title, year, ratings), essay premise, and YouTube title/link.
  - Posts to `@telonyx_club` via `TelegramPublishingService`.

### Task 6: Verification & Final Build
- [ ] Run `xcodegen generate`.
- [ ] Run `SHORTCAST_SKIP_INSTALL=1 xcodebuild -project Shortcast.xcodeproj -scheme Shortcast -configuration Release -destination 'platform=macOS' build`.
- [ ] Run `./scripts/install-app.sh`.
- [ ] Verify no typography overlap, verify theme generation for *Revolver*, verify ambient audio mixing and outro fade, verify YouTube publish button.
