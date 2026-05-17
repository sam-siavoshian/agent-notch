# AGENTS.md

## Purpose

This repository is optimized for:
- fast iteration
- AI-assisted development
- low-context edits
- reliable shipping

Favor:
- simple code
- explicit structure
- local reasoning
- predictable patterns

Avoid:
- over-engineering
- premature abstraction
- architectural churn

---

# Structure

```txt
App/                  — window lifecycle, AppDelegate
Core/                 — shared types and cross-feature contracts only
Features/
  Notch/              — notch UI and settings panel
  Cursor/             — cursor companion, long-press, click hooks
  Context/            — screenshot capture, OCR, Gemini observer, Mercury selector, event pipeline
  Agent/              — Whisper, IntentRouter, Haiku 4.5 computer-use harness
  Calendar/           — EventKit calendar tab
  Music/              — Spotify tab
  Onboarding/         — first-launch permission prompts
```

---

# Feature Layout

Each feature owns its code. Keep related code together.

```txt
Features/Notch/
├── NotchContentView.swift      — root; open/closed (420×280); Home/Settings/Spotify/Calendar tabs; Cmd+D + swipe; tab persisted via @AppStorage
├── NotchHomeView.swift         — Home tab: orb, transcript, activity feed, battery row
├── NotchLiveActivityView.swift — compact live-activity bar in the closed notch during agent runs
├── AgentSettingsView.swift     — Settings tab: knobs + Advanced section (system prompt, context diagnostics)
├── ClosedNotchView.swift       — resting dot/waveform in closed notch; shows battery level
├── NotchShape.swift            — custom Shape for notch geometry
├── AgentStateView.swift        — standalone status row (available, not in current tab layout)
├── BatteryService.swift        — IOKit battery level + charging state
├── SoftPill.swift              — reusable pill-style UI component
└── ToolCallStrip.swift         — chip row of live + recent computer-use tool calls in live-activity state

Features/Cursor/
├── CursorCompanion.swift       — coordinator; implements CursorAppearanceSetting
├── CursorCompanionView.swift   — SwiftUI PNG sprite
├── CursorCompanionViewModel.swift
├── CursorCompanionWindow.swift — transparent always-on-top NSPanel
├── CursorTracker.swift         — tracks real cursor position
├── LongPressDetector.swift     — fires .longPressBegan / .longPressEnded
└── LongPressEvents.swift       — notification name constants

Features/Context/
├── ContextCoordinator.swift        — entry point; implements RecentActivityContext; fires GeminiObserver on major-change captures
├── ContextClickMonitor.swift       — debounced click hook (Accessibility API)
├── ContextAppSwitchMonitor.swift   — capture trigger on app switch
├── ContextSnapshotStore.swift      — rolling buffer of screenshots (max 20)
├── ContextOCRService.swift         — native OCR via Vision framework
├── ContextWindowMetadataReader.swift
├── ContextTextSignalFilter.swift   — cleans OCR output
├── ContextDirtyDetector.swift      — dHash + pixel-diff classifier; gates Gemini calls
├── ContextModels.swift             — ContextSnapshot, ContextDiagnostics, etc.
├── ContextSchema.swift             — CEvent envelope + variants, L2/L3/L4/L5 types
├── ContextDevToolsWindowController.swift — Dev Tools window; Cmd+Shift+I toggles it
├── GeminiObserver.swift            — continuous throttled observer; gemini-3.1-flash-lite; ≥8s between calls
├── GeminiVisionClient.swift        — single-call multimodal Gemini client
├── SurfaceObservation.swift        — structured Codable observation (app, surface, controls, narrative)
├── ScreenObservationLog.swift      — in-memory ring (100) + JSONL on disk
├── SurfaceMemoryStore.swift        — persistent per-(app, surface) UI knowledge
├── CaptureStoryLog.swift           — append-only story of observations; daily-rotated JSONL
├── Selector.swift                  — long-press entry: assembles L2+L3+L4+L5+learned_surfaces, calls Mercury 2
├── MercuryClient.swift             — OpenRouter Mercury 2 JSON-mode client (≤2.5s timeout)
├── LocalBriefRenderer.swift        — deterministic offline fallback brief renderer
├── L2Snapshotter.swift             — 0.4s-budget L2 snapshot (AX + OCR + adapters + screenshot JPEG)
├── L5Store.swift                   — persists active_task.json + resources_index.json
├── ActiveTaskUpdater.swift         — periodic Mercury synthesis of active_task (30s tick)
├── ResourceIndex.swift             — LRU index of touched URIs/files/channels (capacity 100)
├── AnchorRecorder.swift            — promotes repeated event sequences to L3 recipes at seenCount==3
├── EventLog.swift                  — append-only ring (500) + per-day JSONL
├── EventIngester.swift             — single ingest point; runs PrivacyGate; fills envelope
├── PrivacyGate.swift               — 8-step redaction; drops neverLogApps; honours collectionPaused
├── KeystrokeMonitor.swift          — CGEvent tap; burst-batches keystrokes into input events
├── AXObserver.swift                — per-PID AX observer lifecycle; 1Hz polling fallback
├── ClipboardWatcher.swift          — polls NSPasteboard; emits cross-app copy_paste events
├── DwellTimer.swift                — per-(app,window) focus accounting; emits .dwell events
├── AgentObservabilityLog.swift     — central in-memory ring capturing full user↔context↔agent timeline
└── ContextDebugView.swift + extensions — Dev Tools tabs (NewSystem, LiveL2, ScreenObs, Memory, Mercury, ModelCalls, Intent, AgentRun, Harness, Captures, Dirty, Packet, Report, PaneBridge)

Features/Context/Adapters/
├── AppContextAdapter.swift     — protocol; each adapter claims bundle IDs + returns app_specific blob
├── AdapterRegistry.swift       — bundle-ID lookup for registered adapters
├── BrowserAdapter.swift        — Arc/Chrome/Safari/Brave; AppleScript URL+tab title; strips secrets
├── TerminalAdapter.swift       — Terminal/iTerm2/Ghostty; OSC 7 cwd + AppleScript fallback
└── IDEAdapter.swift            — VSCode/Cursor/Xcode/Zed; window-title parse + .git walk

Features/Agent/
├── VoiceRecordingService.swift — records mic on .longPressBegan; Whisper API (language=en, vocab prompt) on .longPressEnded; posts .transcriptReady
├── AgentSession.swift          — subscribes to .transcriptReady; runs IntentRouter fast-path, then Selector → harness
├── IntentRouter.swift          — pre-model fast-path: open-URL, Spotify controls, Reminders — zero API calls
├── ComputerUseHarness.swift    — multi-turn Claude computer-use loop (model: claude-haiku-4-5-20251001)
├── ComputerUseModels.swift     — Codable API types
├── AnthropicClient.swift       — URLSession API client
├── ToolDispatcher.swift        — tool calls → CGEvent/AX/AppleScript actions
├── AXFastPath.swift            — AX element cache + fast-path helpers (ax_query/ax_press/ax_set_value)
├── AppleScriptBridge.swift     — async AppleScript execution wrapper
├── TextToSpeechService.swift   — streams PCM16 from OpenAI TTS; plays via AVAudioPlayerNode
├── KillSwitch.swift            — emergency stop for in-progress agent runs
└── AgentRunMetrics.swift       — AgentRunMetricsRecord + HarnessRunDetailStore for Dev Tools

Features/Calendar/
├── CalendarService.swift       — EventKit events for today + tomorrow; @ObservedObject by Calendar tab
└── NotchCalendarView.swift     — Calendar tab: upcoming events list with time + title

Features/Music/
├── NotchMusicView.swift        — Spotify tab: now-playing card + lyrics scroll
├── SpotifyController.swift     — reads Spotify state via AppleScript; subscribes to PlaybackStateChanged
├── SpotifyNowPlayingView.swift — album art, track name, artist
├── LyricsView.swift            — scrolling lyrics display
├── LyricsService.swift         — fetches lyrics for current track
└── AppleScriptHelper.swift     — thin AppleScript execution wrapper

Features/Onboarding/
├── OnboardingView.swift            — three permission cards (Accessibility, Screen Recording, Microphone)
├── OnboardingWindowController.swift
├── PermissionChecker.swift         — live permission polling
└── LucideIcons.swift               — Lucide icon name constants used by onboarding cards
```

Do not create:
- global managers
- giant shared services
- generic utility dumping grounds

---

# Architecture

Preferred flow:

```txt
View
 ↕
ViewModel (if needed)
 ↕
Service / Actor
```

| Layer | Responsibility |
|---|---|
| View | rendering + user interaction |
| ViewModel | UI state + orchestration |
| Service/Actor | API calls, storage, OS side effects |
| Models | lightweight data types |

---

# Rules

## 1. Prefer Locality

If code is only used by one feature, keep it inside that feature. Do not abstract early.

---

## 2. Keep Dependencies Simple

Allowed:

```txt
Feature → Core
```

Avoid:
- Feature → Feature imports
- circular dependencies
- hidden shared state

Shared logic belongs in `Core/`.

---

## 3. Keep Files Focused

Target: ~100–500 LOC, one primary responsibility. Split when reasoning becomes difficult.

---

## 4. Use Explicit Names

Prefer:

```swift
AgentSession
ContextCoordinator
CursorCompanion
```

Avoid:

```swift
Manager
Helper
Utils
BaseObject
```

Names should be searchable and unambiguous.

---

## 5. Prefer Modern Swift

Use:
- SwiftUI
- async/await
- `actor` for shared mutable state across async contexts
- `@MainActor` on `ObservableObject` singletons
- structs + value semantics for models

Avoid:
- unnecessary protocols
- deep inheritance
- DispatchQueue.main.async (use `await MainActor.run` or `@MainActor` instead)

---

## 6. Cross-Feature Contracts

The only legal surface between features is `AgentInterfaces` and the notification bus:

```swift
// Core/AgentInterfaces.swift
AgentInterfaces.cursor   // CursorAppearanceSetting  — set by CursorCompanion
AgentInterfaces.context  // RecentActivityContext    — set by ContextCoordinator
```

Notification contracts (defined in `Features/Cursor/LongPressEvents.swift`):

| Notification | Posted by | Observed by |
|---|---|---|
| `.longPressBegan` | `LongPressDetector` | `VoiceRecordingService` (start recording) |
| `.longPressEnded` | `LongPressDetector` | `VoiceRecordingService` (stop + transcribe), `CursorCompanion` |
| `.transcriptReady` | `VoiceRecordingService` | `AgentSession` (IntentRouter → Selector → harness) |
| `.notchToggleRequested` | `NotchWindowController` (Cmd+D) | `NotchContentView` |

Each module sets its `AgentInterfaces` slot in its `start()` method, called from `AppDelegate.bootAgent()`.

Do not import one feature module from another directly.

---

# AI Agent Guidelines

When editing:
- preserve existing patterns
- prefer minimal diffs
- avoid broad refactors
- keep changes localized

When generating:
- optimize for readability
- optimize for compile reliability
- prefer explicit control flow

Do not introduce:
- speculative abstractions
- meta-programming
- hidden side effects

---

# Proactive Development Posture

The agent should be an active engineering partner, not a passive command runner.

Default behavior:
- keep driving to the next useful layer after each result
- turn findings into concrete patches, tests, demos, or measured recommendations
- propose and implement safe next steps without waiting for repeated prompting
- benchmark performance-sensitive paths instead of guessing
- surface tradeoffs clearly, then choose a reasonable default when the choice is reversible

For experimental systems:
- build isolated harnesses before wiring risky ideas into the app
- create repeatable demos that show first-run vs second-run behavior
- measure latency, action count, failure rate, and memory usefulness
- inspect real model outputs and harden parsers/prompts against drift

Ask the user only when:
- the decision changes product direction
- the choice is hard to reverse
- credentials, privacy, or destructive actions are involved
- multiple maintainers may be editing the same owned surface

Do not ask just to continue obvious work. If the next step is clear, do it and report back.

---

# Collaboration Workflow

Shared hackathon repo — three maintainers and AI agents working simultaneously.

Default workflow:
- work directly on `main`
- do not create branches
- do not open PRs
- `git pull --ff-only origin main` before starting meaningful work
- `git pull --ff-only origin main` again before committing or pushing
- commit small, complete, verified changes directly to `main`
- push to `origin/main` after each complete change

If `git pull --ff-only origin main` cannot fast-forward:
- stop
- inspect the conflict/race
- ask before resolving or rewriting anything

Before editing:
- check `git status`
- assume unfamiliar local changes belong to another maintainer or agent
- never overwrite or revert changes you did not make unless explicitly asked

---

# Ownership Boundaries

| Area | Owner | Status |
|---|---|---|
| `Features/Notch/` | Wyatt | ✅ done |
| `Features/Cursor/` | Sam | ✅ done |
| `Features/Context/` | Ashan | ✅ done |
| `Features/Agent/` | Ashan | ✅ done |
| `Features/Calendar/` | Wyatt | ✅ done |
| `Features/Music/` | Wyatt | ✅ done |
| `Features/Onboarding/` | shared | ✅ done |
| `Core/` | shared | ✅ done |
| `App/` | shared | ✅ done |

Stay in your owning feature folder whenever possible. Touch `Core/` only for explicit contracts shared across features.

---

# Product Constraints

Local macOS desktop app. Do not add:
- backend servers
- accounts
- cloud sync
- remote databases

Users bring their own API keys. Keys must:
- stay local
- never be hardcoded
- never be committed
- be read from environment variables (see `Core/Secrets.swift`)

For context and screen understanding:
- prefer screenshot-first design
- use OS events as capture triggers, not as primary source of truth
- keep Accessibility API usage optional, narrow, and isolated
- favor on-device preprocessing (OCR via Vision) to reduce model work
- keep outputs inspectable and useful to the computer-use agent

---

# Networking

Prefer:
- `URLSession` + `Codable` + `async/await`
- Feature-scoped services (`Features/Agent/AnthropicClient.swift`)

Over:
- global API managers in `Core/`

---

# Priority Order

1. shipping
2. correctness
3. clarity
4. iteration speed
5. architecture purity

This is a hackathon project. Optimize for momentum.
