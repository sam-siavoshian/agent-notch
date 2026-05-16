# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See `AGENTS.md` for Swift coding conventions, architecture rules, and AI agent guidelines — they apply here.

---

## Build & Run

The Xcode project lives in the vendored fork:

```bash
# Resolve SPM dependencies
cd vendored/boring.notch
xcodebuild -resolvePackageDependencies -project boringNotch.xcodeproj

# Build (no signing required)
xcodebuild build \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

To run the app, open `vendored/boring.notch/boringNotch.xcodeproj` in Xcode and hit Run. The app requires macOS with a notch (M-series MacBook) and Accessibility permissions for cursor overlay and click hooks.

---

## What We're Building

**Agent in the Notch** — a macOS computer-use agent with two surfaces:

- **Notch UI**: the agent's home, forked from [boring.notch](vendored/boring.notch). Shows live agent state and settings.
- **Cursor Companion**: a PNG sprite that follows the real cursor. Long-press activates voice. This is the agent's body.

The agent (Claude Haiku) receives: voice transcript (Whisper) + a ≤2-paragraph text summary of recent screen activity (Gemini multimodal pipeline) + user preferences. It then drives computer-use actions.

Full spec: `PRD.md`.

---

## Architecture

New feature code follows the layout in `AGENTS.md`. The three feature areas map to:

```
Features/Notch/       — notch UI, settings panel (Wyatt)
Features/Cursor/      — PNG overlay, computer use, click hooks (Sam)
Features/Context/     — long-press/voice, screenshot capture, Gemini summarizer (Ashan)
Features/Agent/       — Haiku agent wiring, assembles inputs, fires model (Ashan)
Core/                 — shared types, settings store
```

The vendored `boring.notch` source (`vendored/boring.notch/boringNotch/`) is the base for `Features/Notch/`. Key files there: `BoringViewModel.swift` (main state), `BoringViewCoordinator.swift` (window/notch lifecycle), `ContentView.swift` (root SwiftUI view).

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
| Claude Haiku | Primary agent | Tool calls / computer actions |
| Gemini multimodal | Screenshot batch summarizer | Batches of ~10, parallel, → text |
| Whisper | Voice transcription | On long-press release |

Context pipeline: click event (debounced 1 s) → screenshot → rolling buffer (cap 20) → Gemini batches → merged ≤2-paragraph string → injected into Haiku system context.
