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
  Context/            — screenshot capture, OCR, Gemini, memory
  Agent/              — Sonnet wiring, computer-use harness
  Onboarding/         — first-launch permission prompts
vendored/             — read-only reference code (do not edit, do not include in target)
```

---

# Feature Layout

Each feature owns its code. Keep related code together.

```txt
Features/Notch/
├── NotchContentView.swift      — root; open/closed (420×280); Home/Settings tabs; Cmd+D + swipe; tab persisted via @AppStorage
├── NotchHomeView.swift         — Home tab: orb, transcript, activity log (logs completion entry on run done)
├── AgentSettingsView.swift     — Settings tab: 4 knobs + Advanced section (system prompt, context diagnostics)
├── ClosedNotchView.swift       — resting dot states in closed notch
├── NotchShape.swift            — custom Shape for notch geometry
└── AgentStateView.swift        — standalone status row (available, not in tabs)

Features/Cursor/
├── CursorCompanion.swift       — coordinator; implements CursorAppearanceSetting
├── CursorCompanionView.swift   — SwiftUI PNG sprite
├── CursorCompanionViewModel.swift
├── CursorCompanionWindow.swift — transparent always-on-top NSPanel
├── CursorTracker.swift         — tracks real cursor position
├── LongPressDetector.swift     — fires .longPressBegan / .longPressEnded
└── LongPressEvents.swift       — notification name constants

Features/Context/
├── ContextCoordinator.swift    — entry point; implements RecentActivityContext
├── ContextClickMonitor.swift   — debounced click hook (Accessibility API)
├── ContextSnapshotStore.swift  — rolling buffer of screenshots (max 20)
├── ContextMemoryStore.swift    — learned UI memory on disk
├── ContextOCRService.swift     — native OCR via Vision framework
├── ContextGeminiObservationService.swift
├── ContextGeminiObservationModels.swift
├── ContextActivationBuilder.swift  — buffer → compact prompt packet
├── ContextMemoryRenderer.swift
├── ContextModels.swift
├── ContextWindowMetadataReader.swift
├── ContextTextSignalFilter.swift
├── ContextAIObservationLog.swift   — in-memory Gemini event log + ContextGeminiObservationGate (rate limiter)
├── ContextDevToolsWindowController.swift — separate Dev Tools window for telemetry (Cmd+Option+D)
├── ContextDebugView.swift          — Dev Tools console: pause/resume gathering, overview, injected packet, captures/OCR, Gemini I/O, learned memory, metrics
└── ContextPerformanceReporter.swift

Features/Agent/
├── VoiceRecordingService.swift — records mic on .longPressBegan; uploads to OpenAI Whisper API (whisper-1) on .longPressEnded; posts .transcriptReady
├── AgentSession.swift          — subscribes to .transcriptReady; reads lastTranscript; fires one harness turn
├── ComputerUseHarness.swift    — multi-turn Claude computer-use loop (model: claude-sonnet-4-6)
├── ComputerUseModels.swift     — Codable API types
├── AnthropicClient.swift       — URLSession API client
├── ToolDispatcher.swift        — tool calls → CGEvent actions; handles all computer-use actions incl. F-keys + emoji
└── AgentRunMetrics.swift       — per-run metrics logging

Features/Onboarding/
├── OnboardingView.swift        — three permission cards
├── OnboardingWindowController.swift
└── PermissionChecker.swift     — live permission polling
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
| `.transcriptReady` | `VoiceRecordingService` | `AgentSession` (fire harness turn) |
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
