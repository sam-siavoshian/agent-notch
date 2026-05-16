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

The app **is not** a fork of boring.notch. The boring.notch source is checked in under `vendored/boring.notch/` as read-only reference material (window plumbing, animations, tab layout, music UI). Read it, learn from it — **do not modify it** and do not include any of its files in our app target.

---

## What We're Building

**Agent in the Notch** — a macOS computer-use agent with two surfaces:

- **Notch UI**: the agent's home, a fresh SwiftUI app (inspired by, but not forked from, boring.notch). Shows live agent state and settings.
- **Cursor Companion**: a PNG sprite that follows the real cursor. Long-press activates voice. This is the agent's body.

The agent (Claude Sonnet) receives: voice transcript (Whisper) + a ≤2-paragraph text summary of recent screen activity (Gemini multimodal pipeline) + user preferences. It then drives computer-use actions.

Full spec: `PRD.md`.

---

## Architecture

New feature code follows the layout in `AGENTS.md`. The three feature areas map to:

```
Features/Notch/       — notch UI, settings panel (Wyatt)           ← exists
Features/Cursor/      — PNG overlay, computer use, click hooks (Sam)  ← create
Features/Context/     — long-press/voice, screenshot capture, Gemini summarizer (Ashan)  ← create
Features/Agent/       — Sonnet agent wiring, assembles inputs, fires model (Ashan)        ← create
Core/                 — shared types, settings store               ← exists
```

### Core/ file map

These are stable — all features should use them, not duplicate:

| File | What it is |
|---|---|
| `AgentInterfaces.swift` | Protocol stubs + static DI slots (`AgentInterfaces.cursor`, `.context`) — register your implementation here |
| `AgentState.swift` | `AgentState.shared` — live status the Notch UI reads; call `AgentState.shared.set()` to reflect what the agent is doing |
| `AgentSettingsStore.swift` | `AgentSettingsStore.shared` — persisted user settings (reasoning effort, preferences, system prompt, cursor color) |
| `AgentReasoningEffort.swift` | Enum: `.low` / `.medium` / `.high` |
| `CursorColor.swift` | Enum: `.red` / `.green` / `.blue` / `.yellow` — has `.assetName` for PNG lookup |

The boring.notch reference is at `vendored/boring.notch/`. Useful files: `boringNotch/BoringViewModel.swift` (main state), `boringNotch/BoringViewCoordinator.swift` (window/notch lifecycle), `boringNotch/ContentView.swift` (root SwiftUI view), `boringNotch/components/Notch/BoringNotchWindow.swift` (window plumbing).

---

## Cross-Feature Interfaces

These are the only contracts between features — keep them stable:

| Interface | Owner | Consumer |
|---|---|---|
| `setCursorColor(_ color: CursorColor)` | Sam (Cursor) | Wyatt (Notch settings panel) |
| `getRecentActivityContext() async -> String` | Ashan (Context) | Ashan (Agent wiring) |

Settings (reasoning effort, preferences text, system prompt, cursor color) are persisted as a local JSON file — no sync, no iCloud. The settings store lives in `Core/` and is the single source of truth read by both the Notch UI and the Agent.

---

## External Models

| Model | Purpose | Notes |
|---|---|---|
| Claude Sonnet | Primary agent | Tool calls / computer actions |
| Gemini multimodal | Screenshot batch summarizer | Batches of ~10, parallel, → text |
| Whisper | Voice transcription | On long-press release |

Context pipeline: click event (debounced 1 s) → screenshot → rolling buffer (cap 20) → Gemini batches → merged ≤2-paragraph string → injected into Sonnet system context.

---

## Adding a New Feature Module

When Sam or Ashan creates their feature directory:

1. **Register with `AgentInterfaces`** — set the static slot from your module's `install()` method called from `AppDelegate.applicationDidFinishLaunching`:
   ```swift
   AgentInterfaces.cursor = MyCursorModule()
   AgentInterfaces.context = MyContextModule()
   ```

2. **Use `@MainActor` on any `ObservableObject`** — all Core singletons are `@MainActor`; match the pattern.

3. **Read settings from `AgentSettingsStore.shared`** — don't copy settings into your own store.

4. **Update `AgentState.shared`** to reflect live agent status — the Notch UI observes it automatically.

5. **Keep networking in your feature** — e.g. `Features/Agent/AgentService.swift`, not in `Core/`.
