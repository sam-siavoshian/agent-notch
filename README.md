# Agent Notch

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#)
[![Swift 5.10](https://img.shields.io/badge/swift-5.10-orange.svg)](#)
[![Built with Claude Haiku 4.5](https://img.shields.io/badge/computer--use-Claude%20Haiku%204.5-7c3aed.svg)](https://www.anthropic.com/)

macOS computer-use agent that lives in the notch.

Long-press the cursor companion, talk, Claude Haiku 4.5 drives the mouse. The notch shows what it is doing. Screen context (OCR + Gemini) builds a persistent UI map; Mercury 2 distills it into a brief before every agent turn.

> Requires an M-series MacBook with a physical notch. macOS 14+.

---

## Quick start

```bash
brew install xcodegen
bash scripts/setup-signing.sh
xcodegen generate
open AgentNotch.xcodeproj
```

Set `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, and `OPENROUTER_API_KEY` in the Xcode scheme env. Build, run, grant the three permissions, long-press the cursor.

---

## Keys

| Var | Used by |
|---|---|
| `ANTHROPIC_API_KEY` | Claude Haiku 4.5 computer-use agent |
| `GEMINI_API_KEY` | Continuous background screen observer (Gemini Flash Lite) |
| `OPENAI_API_KEY` | Voice transcription (Whisper) + TTS |
| `OPENROUTER_API_KEY` | Mercury 2 context selector + ActiveTaskUpdater |
| `ANTHROPIC_NOTCH_DEMO_PROMPT` | Optional. Hardcoded transcript for mic-less demos. |

Never committed. Set via Xcode scheme env or enter in the in-app Settings UI — keys are stored in the macOS Keychain (`com.agentnotch.app`). Env var wins over Keychain if both are set.

---

## Permissions

Onboarding asks for three:

- **Accessibility** — long-press detection + click/keystroke synthesis
- **Screen Recording** — context capture
- **Microphone** — voice in

---

## Controls

- Hover notch, it opens
- Drag down to open, drag up to close
- `⌘D` toggles open/closed
- Long-press cursor companion, talk, release, agent fires
- Tabs: Home (status), Settings (reasoning, color, prefs), Spotify, Calendar
- `⌘⇧I` opens the Dev Tools window

---

## Why a signing script?

Ad-hoc signing changes the cdhash every build. macOS TCC keys permission grants by cdhash, so grants vanish on every rebuild. `scripts/setup-signing.sh` wires your Apple Development cert in so grants stick.

Open Xcode → Settings → Accounts → Manage Certificates → + → Apple Development if the script cannot find one.

---

## Layout

```
App/                  app entry, entitlements
Core/                 shared types, settings, secrets
Features/Notch/       notch UI + tabs
Features/Cursor/      cursor companion + long-press
Features/Context/     screen capture, OCR, Gemini observer, Mercury selector, event pipeline
Features/Agent/       Whisper + IntentRouter + Claude Haiku 4.5 computer-use loop
Features/Calendar/    EventKit calendar tab
Features/Music/       Spotify tab
Features/Onboarding/  first-launch permissions
```

Details in [`AGENTS.md`](AGENTS.md) and [`CLAUDE.md`](CLAUDE.md). Product spec in [`PRD.md`](PRD.md). Pipeline walkthrough in [`AGENT_PIPELINE.md`](AGENT_PIPELINE.md).

---

## Stack

Swift, SwiftUI, Claude Haiku 4.5 (computer-use), Mercury 2 via OpenRouter (context selector), Gemini Flash Lite (background screen observer), OpenAI Whisper + TTS, Vision OCR, CGEvent, ScreenCaptureKit, XcodeGen.

Built at TritonHacks 2026.

---

## Contributing

PRs welcome. Conventions live in [`AGENTS.md`](AGENTS.md). Run `xcodegen generate` after pulling. Keep diffs minimal and stay out of `vendored/`.

## License

[MIT](LICENSE).
