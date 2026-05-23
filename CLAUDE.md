# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See `AGENTS.md` for Swift coding conventions, architecture rules, and AI agent guidelines — they apply here.

---

## Build & Run

Fresh macOS SwiftUI app at the repo root. `.xcodeproj` is **generated** from `Project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen) — gitignored so the three of us don't fight pbxproj merge conflicts.

First time setup on a new machine:

```bash
brew install xcodegen   # if not already installed
xcodegen generate       # creates AgentNotch.xcodeproj from Project.yml
open AgentNotch.xcodeproj
```

After pulling changes that touch `Project.yml` or source layout, re-run `xcodegen generate`.

Requires macOS 14+ with a notch (M-series MacBook). Microphone, automation, and screen capture entitlements live in `App/AgentNotch.entitlements`.

---

## CLI Tools

Prefer modern tools over POSIX fallbacks:

| Task | Use | Instead of |
|---|---|---|
| Search text in files | `rg` (ripgrep) | `grep -r` |
| Find files by name/path | `fd` | `find` |
| Search by AST / code structure | `ast-grep` | `grep` for symbol patterns |
| Interactive fuzzy selection | `fzf` | manual `grep` pipelines |
| In-place text substitution | `sd` or the Edit tool | `sed` |

```bash
rg "AgentState" --type swift                        # search Swift files for a symbol
fd -e swift ContextDebug                            # find files matching a name
ast-grep --lang swift -p 'func $NAME($_$$)'         # structural pattern search
fd -e swift | fzf                                   # interactive file picker
```

---

## API Keys

No keys are hardcoded. Resolution order: environment variable → Keychain (per-account under service `com.agentnotch.app`) → nil. See `Core/Secrets.swift`.

| Key | Used by |
|---|---|
| `ANTHROPIC_API_KEY` | `AnthropicClient` → Claude Haiku 4.5 computer-use harness |
| `OPENAI_API_KEY` | `VoiceRecordingService` → OpenAI Whisper API (`whisper-1`) transcription |
| `OPENROUTER_API_KEY` | `MercuryClient` → Mercury 2 (`inception/mercury-2`) for the long-press Selector + `ActiveTaskUpdater` |

Set these in `.env` at the repo root (gitignored, bundled as a resource at build time by `Project.yml`). `EnvLoader.swift` loads it at launch — no Xcode scheme vars needed.

**Demo without voice:** set `ANTHROPIC_NOTCH_DEMO_PROMPT` to a hardcoded prompt string. `VoiceRecordingService` will use it as the transcript when the model is still initializing or no mic input was captured.

---

## What We're Building

**Agent in the Notch** — a macOS computer-use agent with two surfaces:

- **Notch UI**: the agent's home, a fresh SwiftUI app. Shows live agent state and settings.
- **Cursor Companion**: a PNG sprite that follows the real cursor. Long-press activates voice. This is the agent's body.

Voice transcripts first hit `IntentRouter` — a zero-model fast-path that handles open-URL, Spotify controls, and Reminders without any API call. Non-trivial commands continue to Mercury 2 for context assembly and then to Claude Haiku 4.5 (`claude-haiku-4-5-20251001`) for the computer-use loop. The agent receives: voice transcript + a Mercury 2-rendered context brief (assembled from L2 live snapshot, L3 per-app recipes, L4 prefs, L5 active_task, `learned_surfaces`, and `recent_story` from `CaptureStoryLog`) + an initiation screenshot attached as the first user-message image. It then drives computer-use actions via CGEvent and speaks responses via `TextToSpeechService` (OpenAI TTS streaming).

Full spec: `PRD.md`.

---

## Architecture

```
Features/Notch/       — notch UI, settings panel (Wyatt)               ✅ done
Features/Cursor/      — PNG overlay, long-press, click hooks            ✅ done
Features/Calendar/    — EventKit calendar tab in notch (Wyatt)          ✅ done
Features/Context/     — L1-L5 monitors, Mercury selector             ✅ done
Features/Agent/       — Claude Haiku 4.5 wiring, computer-use harness   ✅ done
Features/Onboarding/  — permission prompts at first launch              ✅ done
Core/                 — shared types, settings store, secrets           ✅ done
```

The Context system runs a long-press foreground path:

**Long-press foreground (fast-path + Mercury-driven).** Long-press → `VoiceRecordingService` → Whisper → `AgentSession.fireAgentTurn(transcript:)`. First, `IntentRouter.tryHandle()` runs synchronously — if it matches (open URL, Spotify, Reminder), it executes and returns immediately without any Mercury call. Otherwise, `ContextSelector.select(transcript:)` assembles an L2 snapshot (AX walk + OCR + selection + clipboard + adapters, 0.4s deadline) + L3 recipes for the active app + L4 user prefs + L5 active_task + `learned_surfaces` (top 6 surfaces × 12 controls from `SurfaceMemoryStore`) + `recent_story` (last 20 entries from `CaptureStoryLog`, capped at 5 minutes). One Mercury 2 call returns `{intent, brief}` in ~600ms p50. The brief is handed verbatim to `ComputerUseHarness` as `contextSummary`, AND the initiation screenshot JPEG is attached as the first user-message `image` block to Claude Haiku 4.5.

The 0.4s L2 deadline keeps the foreground path sub-second. `SurfaceMemoryStore` and `CaptureStoryLog` carry across long-presses for cross-app routing and narrative continuity.

### Core/ file map

All features should use these — never duplicate them.

| File | What it is |
|---|---|
| `AgentInterfaces.swift` | Protocol stubs + static DI slots (`AgentInterfaces.cursor`, `.context`) |
| `AgentState.swift` | `AgentState.shared` — live status the Notch UI reads; call `.set()` to update |
| `AgentSettingsStore.swift` | `AgentSettingsStore.shared` — persisted user settings (includes `TTSVoice`, `ttsVoice`) |
| `AgentReasoningEffort.swift` | Enum: `.low` / `.medium` / `.high` |
| `CursorColor.swift` | Enum: `.red` / `.green` / `.blue` / `.yellow` — has `.assetName` for PNG lookup |
| `ScreenCapture.swift` | `ScreenCapture.shared` — shared screenshot utility |
| `Secrets.swift` | Key resolution — env → Keychain; exposes `anthropicAPIKey`, `openAIAPIKey`, `openRouterAPIKey` |
| `AppRelaunch.swift` | `AppRelaunch.relaunch()` — relaunches the app process (used by Settings) |
| `EnvLoader.swift` | `Env.load()` / `Env.value(_:)` — hydrates process environment from `.env` file at launch |
| `Keychain.swift` | `Keychain.get(_:)` / `Keychain.set(_:account:)` — per-account Keychain storage under service `com.agentnotch.app` |
| `Log.swift` | `Log(category:)` — os_log wrapper; use instead of `print` or `NSLog` |

---

## Feature File Maps

### Features/Notch/ (Wyatt)

| File | What it is |
|---|---|
| `NotchContentView.swift` | Root view — open/closed (420×280), Home/Settings/Spotify/Calendar tabs, Cmd+D + swipe gestures, tab persisted via `@AppStorage` |
| `NotchHomeView.swift` | Home tab — agent orb, last transcript, activity feed, battery row |
| `AgentSettingsView.swift` | Settings tab — knobs including TTS voice picker + Advanced section (system prompt, context diagnostics) |
| `ClosedNotchView.swift` | Resting dot/waveform in the closed notch; shows battery level via `BatteryService` |
| `NotchShape.swift` | Custom `Shape` for the notch geometry |
| `NotchLiveActivityView.swift` | Compact live-activity bar shown in the closed notch when agent is active |
| `AgentStateView.swift` | Standalone status row (available but not used in current tab layout) |
| `BatteryService.swift` | `BatteryService.shared` — IOKit battery level + charging state; `@ObservedObject` by Notch views |
| `SoftPill.swift` | Reusable pill-style UI component used across Notch views |

### Features/Cursor/ (Sam)

| File | What it is |
|---|---|
| `CursorCompanion.swift` | Top-level coordinator; implements `CursorAppearanceSetting` |
| `CursorCompanionView.swift` | SwiftUI PNG sprite |
| `CursorCompanionViewModel.swift` | Observable state (color, listening, thinking) |
| `CursorCompanionWindow.swift` | Transparent always-on-top `NSPanel` |
| `CursorTracker.swift` | Follows real cursor position |
| `LongPressDetector.swift` | Detects long-press; posts `.longPressBegan` / `.longPressEnded` |
| `LongPressEvents.swift` | Notification name constants |

### Features/Context/ (Ashan)

**Coordination + capture pipeline**

| File | What it is |
|---|---|
| `ContextCoordinator.swift` | Entry point; implements `RecentActivityContext`; owns click + app-switch + startup captures |
| `ContextClickMonitor.swift` | Debounced click hook via Accessibility API (drives `capture(...)`) |
| `ContextAppSwitchMonitor.swift` | Capture trigger on `NSWorkspace.didActivateApplicationNotification` |
| `ContextSnapshotStore.swift` | Rolling buffer of screenshots (max 20) |
| `ContextOCRService.swift` | Native OCR via Vision framework |
| `ContextWindowMetadataReader.swift` | Reads active app name + window title |
| `ContextTextSignalFilter.swift` | Cleans OCR output (drops chrome/junk strings) |
| `ContextDirtyDetector.swift` | dHash + downscaled pixel-diff classifier; labels each frame `unchanged`/`minorChange`/`majorChange` |
| `ContextModels.swift` | Data types: `ContextSnapshot`, `ContextDiagnostics`, etc. |
| `ContextSchema.swift` | New-system event schema (`CEvent` envelope + variants, L2/L3/L4/L5 types, recipes, resources, active_task) |
| `ContextDevToolsWindowController.swift` | Separate Dev Tools window for context telemetry; Cmd+Shift+I toggles it |

**Surface memory + story (read by the long-press Selector)**

| File | What it is |
|---|---|
| `SurfaceObservation.swift` | Structured `Codable` observation: frontmost_app, surface, controls, layout + user-layer fields (narrative, current_goal_guess, continuity_link, content_type, artifact) |
| `SurfaceMemoryStore.swift` | Persistent per-(app, surface) UI knowledge with seen_count + last_seen per control; opportunistic prune; consumed by the Selector as `learned_surfaces` |
| `CaptureStoryLog.swift` | Append-only chronological story of `SurfaceObservation`s; daily-rotated JSONL + in-memory tail; Selector reads `tail(20)` at long-press time to give Mercury narrative continuity via `recent_story` |

**Long-press foreground (Mercury 2 + L2-L5)**

| File | What it is |
|---|---|
| `Selector.swift` (`ContextSelector`) | Long-press entry point — assembles L2 + L3 + L4 + L5 + `learned_surfaces`, calls Mercury 2, returns `{intent, brief, l2, initiationScreenshot, degraded, latency, model}`; falls back to `LocalBriefRenderer` on failure |
| `MercuryClient.swift` | OpenRouter Mercury 2 (`inception/mercury-2`) text-only JSON-mode client; per-call hard timeout (default ≤2.5s) |
| `LocalBriefRenderer.swift` | Deterministic offline brief renderer — used when Mercury times out, has no key, or returns malformed JSON |
| `L2Snapshotter.swift` | 0.4s-budget L2 snapshot — frontmost + window/title + display + screenshot+OCR (≤250ms) + AX dump (≤150ms) + selection + clipboard + adapter blob (200ms); returns `(CL2Snapshot, screenshotJPEG)` so AgentSession can forward the JPEG to Claude without bloating the Mercury prompt |
| `L5Store.swift` | Persists active_task.json, resources_index.json, and per-day task_archive JSONL (atomic writes) |
| `ActiveTaskUpdater.swift` | Periodic Mercury synthesis of `active_task`; 30s tick checks triggers (≥90s + substantive event, app-switch to unknown bundle with 10s debounce, or sync refresh from Selector) |
| `ResourceIndex.swift` | LRU index of touched URIs/files/channels (capacity 100); adapters call `record(_:)`, Selector reads top-N |
| `AnchorRecorder.swift` | Polls `EventLog` every 5s, segments event sequences, promotes repeated patterns to L3 recipes at seenCount==3; persists per-bundle JSON under `ContextMemory/anchors/<bundleID>.json` |

**Event pipeline (monitors → PrivacyGate → EventLog)**

| File | What it is |
|---|---|
| `EventLog.swift` | Append-only ring buffer (500) + per-day JSONL persistence (`ContextMemory/events-YYYY-MM-DD.jsonl`); issues monotonic `seq` numbers |
| `EventIngester.swift` | Single ingest point — monitors call `ingest(...)`, ingester fills envelope (seq, sourceMonitor, frontmost-app autofill), runs PrivacyGate, forwards survivors to EventLog |
| `PrivacyGate.swift` | Single chokepoint implementing the 8-step redaction policy; drops events from `neverLogApps` (1Password, Bitwarden, Keychain, AgentNotch itself) and honours `collectionPaused` |
| `KeystrokeMonitor.swift` | CGEvent tap for key/flag changes; burst-batches keystrokes into `input` events; degrades gracefully if Input Monitoring TCC denied |
| `AXObserver.swift` (`AXObserverManager`) | Per-PID AX observer lifecycle; forwards focused-element / value / selection / menu events; 1Hz polling fallback for apps without focus notifications |
| `ClipboardWatcher.swift` | Polls `NSPasteboard`; emits cross-app `copy_paste` events; self-paste suppression hook for `ToolDispatcher`; never-log-app taint follows the clipboard |
| `DwellTimer.swift` | Per-(app, window) focus accounting; emits `.dwell` events when focus leaves and stays away ≥10s, discarding dwells <15s |
| `AgentObservabilityLog.swift` | Central in-memory ring (500) capturing the full user ↔ context ↔ agent timeline: long-press lifecycle, Mercury calls, harness turns, memory mutations — read by Dev Tools timelines |

**Per-app adapters (`Features/Context/Adapters/`)**

| File | What it is |
|---|---|
| `AppContextAdapter.swift` | Protocol — each adapter claims bundle IDs, returns `app_specific` blob for L2 (200ms hard deadline) and contributes `CResourceRef`s to `ResourceIndex` |
| `AdapterRegistry.swift` | Bundle-ID lookup for registered adapters (registered in `AppDelegate.bootAgent()`) |
| `BrowserAdapter.swift` | Arc / Chrome / Safari / Brave — AppleScript-driven URL + tab title extraction; strips `user:pass@` userinfo and secret-shaped query params before emission |
| `TerminalAdapter.swift` | Terminal.app / iTerm2 / Ghostty — OSC 7-style cwd reporter (installed by `scripts/install-cwd-reporter.sh`) read from `~/.cache/agentnotch/term-cwd-<ttyname>`; AppleScript buffer-scrape fallback |
| `IDEAdapter.swift` | VSCode / Cursor / Xcode / Zed — window-title parsing + filesystem walk for `.git`, AppleScript for Xcode |

**Dev Tools UI (separate window, Cmd+Shift+I)**

| File | What it is |
|---|---|
| `ContextDebugView.swift` | Root tab host for the Dev Tools window |
| `ContextDebugView+NewSystem.swift` | Overview / health snapshot of the new context system |
| `ContextDebugView+LiveL2.swift` | Live L2 snapshot inspector (AX + OCR + selection + clipboard + adapters) |
| `ContextDebugView+Memory.swift` | Browser of `SurfaceMemoryStore` per-app/per-surface |
| `ContextDebugView+Mercury.swift` | Per-call Mercury request/response inspector |
| `ContextDebugView+ModelCalls.swift` | Unified view over every Mercury model call |
| `ContextDebugView+Intent.swift` | History of selector intents + briefs |
| `ContextDebugView+AgentRun.swift` | Per-run harness rollup (turns, tokens, latencies) |
| `ContextDebugView+Harness.swift` | Live harness turn-by-turn trace |
| `ContextDebugView+Captures.swift` | Browse cached captures + per-frame OCR |
| `ContextDebugView+Dirty.swift` | Dirty-detector classifications + dHash visualization |
| `ContextDebugView+Packet.swift` | Final packet/brief handed to the agent |
| `ContextDebugView+Report.swift` | Aggregate diagnostics export |
| `ContextDebugView+PaneBridge.swift` | Plumbing between debug tabs and the observable stores |

### Features/Agent/ (Ashan)

| File | What it is |
|---|---|
| `VoiceRecordingService.swift` | Records mic on longPressBegan; uploads audio to OpenAI Whisper API (`whisper-1`) on longPressEnded; posts `.transcriptReady` |
| `AgentSession.swift` | Subscribes to `.transcriptReady`; runs `IntentRouter` fast-path first, then Selector → harness |
| `IntentRouter.swift` | Pre-model fast-path: handles open-URL, Spotify controls, and Reminders via pattern matching — no API call needed |
| `ComputerUseHarness.swift` | Multi-turn Claude computer-use loop (model: `claude-haiku-4-5-20251001`) |
| `ComputerUseModels.swift` | Codable types for the Anthropic computer-use API |
| `AnthropicClient.swift` | Raw API client (URLSession + async/await) |
| `ToolDispatcher.swift` | Maps computer-use tool calls to CGEvent / AX / AppleScript actions |
| `AXFastPath.swift` | AX element cache and fast-path helpers used by `ToolDispatcher` for `ax_query` / `ax_press` / `ax_set_value` |
| `AppleScriptBridge.swift` | Async AppleScript execution wrapper; used by `ToolDispatcher` and `IntentRouter` |
| `TextToSpeechService.swift` | Streams raw PCM16 from OpenAI TTS in ~100ms; plays via `AVAudioPlayerNode`; called by harness on affirmation text |
| `AgentRunMetrics.swift` | Per-run metrics (`AgentRunMetricsRecord`) + `HarnessRunDetailStore` for the DevTools harness pane |

### Features/Onboarding/

| File | What it is |
|---|---|
| `OnboardingView.swift` | Three permission cards (Accessibility, Screen Recording, Microphone) |
| `OnboardingWindowController.swift` | Presents onboarding at first launch; calls `bootAgent()` on dismiss |
| `PermissionChecker.swift` | Polls permission statuses live |
| `LucideIcons.swift` | Lucide icon name constants used by onboarding cards |

### Features/Calendar/ (Wyatt)

| File | What it is |
|---|---|
| `CalendarService.swift` | `CalendarService.shared` — reads EventKit events for today + tomorrow; `@ObservedObject` by the Calendar tab |
| `NotchCalendarView.swift` | Calendar tab in the notch — upcoming events list with time + title |

### Features/Music/ (Wyatt)

| File | What it is |
|---|---|
| `NotchMusicView.swift` | Spotify tab in the notch — now-playing card + lyrics scroll |
| `SpotifyController.swift` | Reads Spotify playback state via AppleScript; subscribes to `com.spotify.client.PlaybackStateChanged` |
| `SpotifyNowPlayingView.swift` | Now-playing row: album art, track name, artist |
| `LyricsView.swift` | Scrolling lyrics display |
| `LyricsService.swift` | Fetches lyrics for the current track |
| `AppleScriptHelper.swift` | Thin AppleScript execution wrapper |

---

## Cross-Feature Interfaces

The only contracts between features — keep them stable.

| Interface | Owner | Consumer |
|---|---|---|
| `setCursorColor(_ color: CursorColor)` | `CursorCompanion` (Sam) | Notch settings panel (Wyatt) |
| `getRecentActivityContext() async -> String` | `ContextCoordinator` (Ashan) | `AgentSession` (Ashan) |

Settings (reasoning effort, preferences text, system prompt, cursor color) are persisted as a local JSON file — no sync, no iCloud. The settings store lives in `Core/` and is the single source of truth.

---

## Boot Sequence

See `App/AppDelegate.swift`.

```
AppDelegate.applicationDidFinishLaunching
  → NSApp.setActivationPolicy(.accessory)         // no dock icon
  → Env.load()                                    // hydrate process env
  → NotchWindowController.shared.install()        // notch panel appears
  → OnboardingWindowController.presentIfNeeded    // first-launch permissions
      → bootAgent()
          → CursorCompanion.shared.start()                // AgentInterfaces.cursor
          → ContextCoordinator.shared.start()             // AgentInterfaces.context (click + app-switch + startup captures)
          → ContextDevToolsWindowController.shared.install()  // Cmd+Shift+I toggle only; window does NOT open automatically
          → VoiceRecordingService.shared.start()          // mic; flushes to OpenAI Whisper
          → AgentSession.shared.start()                   // subscribes to .transcriptReady; IntentRouter → Selector → harness
          → AdapterRegistry.register(BrowserAdapter / TerminalAdapter / IDEAdapter)
          → AXObserverManager.shared.start()              // must precede KeystrokeMonitor (provides focused-element provider)
          → KeystrokeMonitor.shared.start()               // degrades if Input Monitoring TCC denied
          → ClipboardWatcher.shared.start()
          → DwellTimer.shared.start()
          → AnchorRecorder.shared.start()                 // local sequence inference → L3 recipes
          → if AgentSettingsStore.shared.mercuryEnabled:
              ActiveTaskUpdater.shared.start()            // gated to avoid surprise OpenRouter spend
          → PermissionChecker.shared.startPolling()
          → SpotifyController.shared.startIfPreviouslyConnected()
```
