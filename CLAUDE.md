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

The app **is not** a fork of boring.notch. The boring.notch source is checked in under `vendored/boring.notch/` as read-only reference material. Read it, learn from it — **do not modify it** and do not include any of its files in our app target.

---

## API Keys

No keys are hardcoded. Resolution order: environment variable → nil.

| Key | Used by |
|---|---|
| `ANTHROPIC_API_KEY` | `AnthropicClient` → Claude Sonnet agent |
| `GEMINI_API_KEY` | `ContextGeminiObservationService` → screenshot analysis |

Set these in your Xcode scheme's environment or your shell before launching.

**Demo without voice:** set `ANTHROPIC_NOTCH_DEMO_PROMPT` to a hardcoded prompt string. `VoiceRecordingService` will use it as the transcript when the model is still initializing or no mic input was captured.

---

## What We're Building

**Agent in the Notch** — a macOS computer-use agent with two surfaces:

- **Notch UI**: the agent's home, a fresh SwiftUI app. Shows live agent state and settings.
- **Cursor Companion**: a PNG sprite that follows the real cursor. Long-press activates voice. This is the agent's body.

The agent (Claude Sonnet) receives: voice transcript (WhisperKit, on-device) + a compact text summary of recent screen activity (OCR + Gemini pipeline) + user preferences. It then drives computer-use actions via CGEvent.

Full spec: `PRD.md`.

---

## Architecture

```
Features/Notch/       — notch UI, settings panel (Wyatt)      ✅ done
Features/Cursor/      — PNG overlay, long-press, click hooks   ✅ done
Features/Context/     — screenshot capture, OCR, Gemini, memory ✅ done
Features/Agent/       — Sonnet wiring, computer-use harness    ✅ done
Features/Onboarding/  — permission prompts at first launch     ✅ done
Core/                 — shared types, settings store, secrets  ✅ done
```

### Core/ file map

All features should use these — never duplicate them.

| File | What it is |
|---|---|
| `AgentInterfaces.swift` | Protocol stubs + static DI slots (`AgentInterfaces.cursor`, `.context`) |
| `AgentState.swift` | `AgentState.shared` — live status the Notch UI reads; call `.set()` to update |
| `AgentSettingsStore.swift` | `AgentSettingsStore.shared` — persisted user settings |
| `AgentReasoningEffort.swift` | Enum: `.low` / `.medium` / `.high` |
| `CursorColor.swift` | Enum: `.red` / `.green` / `.blue` / `.yellow` — has `.assetName` for PNG lookup |
| `ScreenCapture.swift` | `ScreenCapture.shared` — shared screenshot utility |
| `Secrets.swift` | `Secrets.anthropicAPIKey` — reads from env, never hardcoded |

---

## Feature File Maps

### Features/Notch/ (Wyatt)

| File | What it is |
|---|---|
| `NotchContentView.swift` | Root view — open/closed (420×280), Home/Settings tabs, Cmd+D + swipe gestures, tab persisted via `@AppStorage` |
| `NotchHomeView.swift` | Home tab — agent orb, last transcript, activity feed |
| `AgentSettingsView.swift` | Settings tab — 4 knobs + Advanced section (system prompt, context diagnostics) |
| `ClosedNotchView.swift` | Resting dot/waveform in the closed notch |
| `NotchShape.swift` | Custom `Shape` for the notch geometry |
| `AgentStateView.swift` | Standalone status row (available but not used in current tab layout) |

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

| File | What it is |
|---|---|
| `ContextCoordinator.swift` | Entry point; implements `RecentActivityContext`; owns click-triggered capture |
| `ContextClickMonitor.swift` | Debounced click hook via Accessibility API |
| `ContextSnapshotStore.swift` | Rolling buffer of screenshots (max 20) |
| `ContextMemoryStore.swift` | Learned UI memory persistence |
| `ContextOCRService.swift` | Native OCR via Vision framework |
| `ContextGeminiObservationService.swift` | Gemini multimodal analysis per screenshot |
| `ContextGeminiObservationModels.swift` | Input/output types for Gemini calls |
| `ContextActivationBuilder.swift` | Converts screenshot buffer → compact prompt packet |
| `ContextMemoryRenderer.swift` | Renders learned UI memory to text |
| `ContextModels.swift` | Data types: `ContextSnapshot`, `ContextDiagnostics`, etc. |
| `ContextWindowMetadataReader.swift` | Reads active app name + window title |
| `ContextTextSignalFilter.swift` | Cleans OCR output |
| `ContextAIObservationLog.swift` | In-memory log of Gemini observation events; includes `ContextGeminiObservationGate` (rate limiter) |
| `ContextDevToolsWindowController.swift` | Separate Dev Tools window for context telemetry; Cmd+Option+D toggles it |
| `ContextDebugView.swift` | Dev Tools console — pause/resume gathering, overview, injected packet, captures/OCR, Gemini I/O, learned memory, metrics |
| `ContextPerformanceReporter.swift` | Reads stored artifacts and summarizes diagnostics |

### Features/Agent/ (Ashan)

| File | What it is |
|---|---|
| `VoiceRecordingService.swift` | Records mic on longPressBegan; runs WhisperKit on longPressEnded; posts `.transcriptReady` |
| `AgentSession.swift` | Subscribes to `.transcriptReady`; fires one harness turn |
| `ComputerUseHarness.swift` | Multi-turn Claude computer-use loop (model: `claude-sonnet-4-6`) |
| `ComputerUseModels.swift` | Codable types for the Anthropic computer-use API |
| `AnthropicClient.swift` | Raw API client (URLSession + async/await) |
| `ToolDispatcher.swift` | Maps computer-use tool calls to CGEvent actions |
| `AgentRunMetrics.swift` | Records per-run metrics to `AgentMetricsStore` |

### Features/Onboarding/

| File | What it is |
|---|---|
| `OnboardingView.swift` | Three permission cards (Accessibility, Screen Recording, Microphone) |
| `OnboardingWindowController.swift` | Presents onboarding at first launch; calls `bootAgent()` on dismiss |
| `PermissionChecker.swift` | Polls permission statuses live |

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

```
AppDelegate.applicationDidFinishLaunching
  → NotchWindowController.shared.install()      // notch panel appears
  → OnboardingWindowController.presentIfNeeded  // first-launch permissions
      → bootAgent()
          → CursorCompanion.shared.start()          // registers AgentInterfaces.cursor
          → ContextCoordinator.shared.start()       // registers AgentInterfaces.context
          → ContextDevToolsWindowController.install() // optional telemetry window
          → VoiceRecordingService.shared.start()    // mic recording + WhisperKit init
          → AgentSession.shared.start()             // subscribes to .transcriptReady
```
