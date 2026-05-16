# Agent Notch

macOS computer-use agent that lives in the notch.

Long-press the cursor companion, talk, Claude Sonnet drives the mouse. The notch shows what it is doing. Screen context (OCR + Gemini) gets fed in so it knows where it is.

> Requires an M-series MacBook with a physical notch. macOS 14+.

---

## Quick start

```bash
brew install xcodegen
bash scripts/setup-signing.sh
xcodegen generate
open AgentNotch.xcodeproj
```

Set `ANTHROPIC_API_KEY` and `GEMINI_API_KEY` in the Xcode scheme env. Build, run, grant the three permissions, long-press the cursor.

---

## Keys

| Var | Used by |
|---|---|
| `ANTHROPIC_API_KEY` | Claude Sonnet agent |
| `GEMINI_API_KEY` | Screen context observer |
| `ANTHROPIC_NOTCH_DEMO_PROMPT` | Optional. Hardcoded transcript for mic-less demos. |

Never committed. Scheme env only. OpenAI Whisper key lives in the macOS Keychain (`com.agentnotch.app`).

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
- Tabs: Home (status), Settings (reasoning, color, prefs), Spotify

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
Features/Context/     screen capture, OCR, Gemini
Features/Agent/       Whisper + Claude computer-use loop
Features/Music/       Spotify tab
Features/Onboarding/  first-launch permissions
```

Details in [`AGENTS.md`](AGENTS.md) and [`CLAUDE.md`](CLAUDE.md). Product spec in [`PRD.md`](PRD.md).

---

## Stack

Swift, SwiftUI, Claude Sonnet 4.6 (computer-use), Gemini, WhisperKit, Vision OCR, CGEvent, ScreenCaptureKit, XcodeGen.

Built at TritonHacks 2026.
