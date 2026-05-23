# Agent Notch

<p align="center">
  <img src="landing/public/hero.jpg" alt="Agent Notch" width="720">
</p>

> Your agent finally sees what's on your screen. Lives in the notch.

Long-press the cursor, say what you want, watch Claude do it. Voice in, screenshot in, mouse + keyboard out. The notch shows the live tool calls.

M-series MacBook with a physical notch. macOS 14+.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#)
[![Swift 5.10](https://img.shields.io/badge/swift-5.10-orange.svg)](#)
[![CI](https://github.com/sam-siavoshian/agent-notch/actions/workflows/ci.yml/badge.svg)](https://github.com/sam-siavoshian/agent-notch/actions)

Landing + downloads: [agent-notch.vercel.app](https://agent-notch.vercel.app)

<!-- TODO: replace hero.jpg with an 8-12s demo.gif (≤5MB) once recorded. -->

---

## quick start

```bash
brew install xcodegen
bash scripts/setup-signing.sh
xcodegen generate
open AgentNotch.xcodeproj
```

Add `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` to the Xcode scheme env (or paste them into Settings → keys after first run; stored in Keychain). Build, run, grant the three permissions, long-press the cursor.

---

## use

1. Hover the notch, it opens. `⌘D` toggles. Drag down opens, drag up closes.
2. Long-press the cursor companion (~300ms hold). It lights up.
3. Talk. Release.
4. OpenAI Whisper transcribes. `IntentRouter` handles fast-path commands (open URL, Spotify, Reminders) without touching the model.
5. Anything else goes to the Claude computer-use loop. The notch shows each tool call live.
6. The reply is spoken back via OpenAI TTS or local Piper.

`⌘⇧I` opens Dev Tools (run metrics, harness traces, captured frames).

A configurable kill-switch shortcut aborts a running agent mid-loop.

---

## providers

Pick from Settings → provider:

- **Anthropic API** (default) — direct HTTPS to Anthropic. Needs `ANTHROPIC_API_KEY`. Pay per token.
- **Claude Code** — spawns your local `claude -p` subprocess. Tools route through the bundled `AgentNotchMCP` stdio sidecar over a Unix domain socket back into the same `ToolDispatcher`. Uses your Claude Code auth, no `ANTHROPIC_API_KEY` needed.

Switch any time. Same tool surface either way.

---

## models + TTS

- **Models**: Haiku 4.5 (default, fast, cheap) or Sonnet 4.6 (smarter, slower). Picker in Settings.
- **TTS**: OpenAI TTS (default, voices `nova` / `alloy` / `echo` / `fable` / `onyx` / `shimmer`) or local Piper (offline, no key, needs the `piper` CLI + an ONNX voice model).

---

## keys

| Var | Used by | Required? |
|---|---|---|
| `ANTHROPIC_API_KEY` | Computer-use loop (Anthropic API provider) | yes, unless on Claude Code provider |
| `OPENAI_API_KEY` | Whisper voice-to-text + OpenAI TTS | yes, unless on Piper TTS + demo-prompt mode |
| `ANTHROPIC_NOTCH_DEMO_PROMPT` | Hardcoded transcript when mic is unavailable | optional |

Set via the Xcode scheme env or the in-app Settings → keys field (stored in the macOS Keychain at service `com.agentnotch.app`). Env vars win over Keychain when both are set. Never committed.

---

## permissions

Onboarding asks for three:

- **Accessibility** — long-press detection + click and keystroke synthesis
- **Screen Recording** — screenshots for the model
- **Microphone** — voice in

---

## controls + tabs

- Hover notch → opens. Drag down opens, drag up closes. `⌘D` toggles.
- Long-press cursor → talk → release → agent fires.
- `⌘⇧I` → Dev Tools window.
- Tabs in the notch: **Home** (live status + transcript), **Settings** (provider, model, TTS, prefs, Advanced), **Spotify**, **Calendar**.

Notable settings: run on boot (SMAppService), visible in lock screen, "Everywhere" mode (lifts the panel to `.screenSaver` level), kill-switch shortcut, system-prompt override.

---

## why a signing script?

Ad-hoc signing changes the cdhash on every build. macOS TCC keys permission grants by cdhash, so grants vanish every rebuild. `scripts/setup-signing.sh` wires your Apple Development cert in so grants stick across rebuilds. Hardened runtime is intentionally off in dev for the same reason.

If the script cannot find a cert: Xcode → Settings → Accounts → Manage Certificates → + → Apple Development.

---

## layout

```
App/                    app entry, AppDelegate, entitlements
Core/                   shared types, settings store, secrets, agent state, screen capture
Features/Agent/         computer-use harness, Anthropic + Claude Code clients,
                        Whisper, IntentRouter, ToolDispatcher, Piper TTS,
                        MCP bridge, kill switch
Features/Notch/         notch UI, tabs, Advanced settings, tool-call strip, battery
Features/Cursor/        cursor companion, long-press, click hooks
Features/Calendar/      EventKit calendar tab
Features/Music/         Spotify Web API tab
Features/Onboarding/    first-launch permissions
Helpers/AgentNotchMCP/  stdio MCP sidecar (embedded in AgentNotch.app,
                        spawned by `claude` in CC provider mode)
landing/                Next.js landing site (agent-notch.vercel.app)
scripts/setup-signing.sh   stable signing for persistent TCC grants
Project.yml             XcodeGen spec — no .xcodeproj is committed
```

Project conventions in [AGENTS.md](AGENTS.md). Architecture notes in [CLAUDE.md](CLAUDE.md). Product spec in [PRD.md](PRD.md). Pipeline walkthrough in [AGENT_PIPELINE.md](AGENT_PIPELINE.md).

---

## stack

Swift 5.10, SwiftUI, macOS 14+, Claude Haiku 4.5 / Sonnet 4.6 (computer-use), OpenAI Whisper, OpenAI TTS, local Piper TTS, AVFoundation, ScreenCaptureKit, CGEvent, Accessibility API, EventKit, MediaRemote, XcodeGen.

Two Xcode targets: `AgentNotch` (the app) and `AgentNotchMCP` (the stdio MCP sidecar bundled inside `AgentNotch.app`).

Built at TritonHacks 2026.

---

## contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and the conventions in [AGENTS.md](AGENTS.md). Run `xcodegen generate` after pulling changes to `Project.yml`. Open a draft PR early for non-trivial changes — easier to align before the refactor.

## license

[MIT](LICENSE).
