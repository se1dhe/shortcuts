# Browser Automation Publisher (TikTok, Instagram Reels, YouTube Shorts) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide 100% free, zero-API-key automated publishing of generated shorts to TikTok, Instagram Reels, and YouTube Shorts directly from the Mac desktop app using local browser automation (Playwright + Native Google Chrome).

**Architecture:** A decoupled, SOLID architecture consisting of:
1. A modular Node.js/Playwright automation engine (`scripts/browser-publisher`) running persistent native Google Chrome profiles with anti-bot stealth plugins.
2. Swift-side orchestration (`BrowserAutomationService`, `BrowserPublishingProtocol`) communicating asynchronously with the engine via streaming JSON-RPC/stdout events.
3. Intuitive macOS UI (`BrowserPublishSheet`, `BrowserAuthModal`) with live step-by-step progress, platform toggles, and interactive "Log in to accounts" browser flow.

**Tech Stack:** Swift 6, SwiftUI, Node.js (v24), Playwright Core (`playwright-core`), Puppeteer-Extra-Plugin-Stealth, Native Google Chrome for macOS arm64.

**Spec:** Local requirements gathered from user preferences:
- Mode: Headless by default, with automatic window surfacing upon captcha or session requirement.
- TikTok visibility: Public (direct auto-publish).
- YouTube Shorts visibility: Public (direct auto-publish).
- Instagram Reels: Direct auto-publish via web composer.
- Persistent Session: Stored in `~/Library/Application Support/Shortcast/BrowserProfile`.

---

## Global Constraints

- Swift 6 strict concurrency (`Sendable`, no data races, main actor isolation for views).
- Strict adherence to SOLID principles: Single Responsibility, Open-Closed, Liskov Substitution, Interface Segregation, Dependency Inversion.
- Zero external cloud dependencies or API keys required for this publishing pathway.
- Native Google Chrome (`/Applications/Google Chrome.app`) used as runtime browser to ensure maximum platform trust and avoid heavy external browser downloads.
- Clean JSON-stream communication between Swift and Node.js process.

## Review Focus

1. **Session Persistence**: Sessions must survive app restarts and reboots so the user only logs in once.
2. **Captcha Handling**: When TikTok or Instagram prompts for puzzle/slider captcha, the headless browser must immediately bring the window into focus so the user can solve it without failing the task.
3. **Upload Ingestion**: Files must be passed directly from local disk via `<input type="file">` without intermediate base64 or memory bloat.
4. **DOM Resiliency**: Selectors must prioritize resilient data attributes, aria labels, and fallback locator strategies rather than fragile auto-generated class names.
5. **Error Reporting**: Clear human-readable localized Russian error messages if an account is logged out or upload fails.

---

## Task Decomposition

### Task 1: Scaffolding and Playwright Automation Engine

**Files:**
- Create: `scripts/browser-publisher/package.json`
- Create: `scripts/browser-publisher/src/browser.js`
- Create: `scripts/browser-publisher/src/login.js`
- Create: `scripts/browser-publisher/src/cli.js`

**Steps:**
- [ ] Initialize `scripts/browser-publisher/package.json` with `playwright-core` and stealth plugins.
- [ ] Run `npm install` in `scripts/browser-publisher`.
- [ ] Implement `src/browser.js` with persistent context in `~/Library/Application Support/Shortcast/BrowserProfile` pointing to `/Applications/Google Chrome.app`.
- [ ] Implement `src/login.js` opening interactive tabs for TikTok, Instagram, and YouTube Studio for 1-click user authentication.
- [ ] Implement `src/cli.js` routing `--login`, `--check-auth`, and `--upload` commands with streaming JSON output.
- [ ] Verify execution via terminal command.

---

### Task 2: Platform Upload Scripts (TikTok, Instagram, YouTube)

**Files:**
- Create: `scripts/browser-publisher/src/tiktok.js`
- Create: `scripts/browser-publisher/src/instagram.js`
- Create: `scripts/browser-publisher/src/youtube.js`

**Steps:**
- [ ] Implement `src/tiktok.js`:
  - Navigate to `https://www.tiktok.com/creator-center/upload`
  - Inject video file into dropzone / file input
  - Set title, description, and hashtags
  - Select cover / privacy = Public
  - Click Post and wait for success confirmation
  - Detect captcha frame; if found, surface window and notify CLI.
- [ ] Implement `src/instagram.js`:
  - Navigate to `https://www.instagram.com`
  - Click "New Post" / "Create" -> Select file
  - Set crop/aspect to 9:16 Reels
  - Enter caption and hashtags
  - Click Share and wait for confirmation.
- [ ] Implement `src/youtube.js`:
  - Navigate to `https://studio.youtube.com`
  - Click "Create" -> "Upload videos"
  - Pass video file into input
  - Fill title, description, tags, set audience "Not made for kids"
  - Set visibility to "Public" -> Save / Publish.
- [ ] Test CLI upload dry-run with a dummy video file.

---

### Task 3: Swift Browser Automation Service & Protocols (SOLID)

**Files:**
- Create: `Shortcast/Services/BrowserPublishingProtocol.swift`
- Create: `Shortcast/Services/BrowserAutomationService.swift`
- Create: `Shortcast/Models/BrowserUploadJob.swift`
- Modify: `Shortcast/Models/ShortClip.swift`

**Steps:**
- [ ] Define `BrowserPublishingProtocol` with `checkAuthStatus()`, `openLoginSession()`, and `publish(job:)`.
- [ ] Define `BrowserUploadJob` and `BrowserUploadProgress` structs conforming to `Sendable` and `Codable`.
- [ ] Implement `BrowserAutomationService`:
  - Resolve Node.js binary path and `scripts/browser-publisher/src/cli.js`.
  - Asynchronously execute Node CLI and stream stdout JSON lines.
  - Expose Swift `AsyncThrowingStream` for live upload status events.
- [ ] Add `browserPublish` methods and state to `ShortClip.swift`.

---

### Task 4: UI Integration (Browser Publish Sheet & Account Session Manager)

**Files:**
- Create: `Shortcast/Views/BrowserPublishSheet.swift`
- Create: `Shortcast/Views/BrowserAuthView.swift`
- Modify: `Shortcast/Views/ShortClipCard.swift`
- Modify: `Shortcast/Views/SettingsView.swift`

**Steps:**
- [ ] Build `BrowserAuthView`:
  - Displays status of connected accounts (TikTok, Instagram, YouTube).
  - Button "Открыть окно авторизации (Google Chrome)".
  - Educational tip explaining that passwords and cookies are stored 100% locally on the user's Mac.
- [ ] Build `BrowserPublishSheet`:
  - Checkboxes for selecting target platforms.
  - Preview of clip, title, and hashtags.
  - "Опубликовать в 1 клик" action button.
  - Live progress bars and status indicators for each platform with error recovery.
- [ ] Add "Опубликовать через браузер (Без API)" button in `ShortClipCard.swift` next to Upload-Post.
- [ ] Add Browser Automation settings section in `SettingsView.swift`.

---

### Task 5: Compilation, Packaging & Verification

**Files:**
- Modify: `project.yml`
- Build & Verify `/Applications/Short Generator.app`

**Steps:**
- [ ] Regenerate Xcode project with `xcodegen generate`.
- [ ] Compile project with `xcodebuild -scheme Shortcast -destination 'platform=macOS' build`.
- [ ] Verify signature and installation to `/Applications/Short Generator.app`.
- [ ] Test end-to-end launch of the login session and UI sheet.
