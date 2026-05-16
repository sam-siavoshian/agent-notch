# Agent in the Notch

A macOS computer-use agent that lives in the notch. Voice-activated (long-press the cursor companion), context-aware (captures recent screen activity), powered by Claude Sonnet.

---

## Requirements

- macOS 14+ on an M-series MacBook (physical notch required)
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Anthropic API key

---

## First-time setup

```bash
git clone <this repo>
cd tritonhacks2026
xcodegen generate
open AgentNotch.xcodeproj
```

Re-run `xcodegen generate` any time `Project.yml` or the source layout changes.

---

## Setting your API key

The app reads `ANTHROPIC_API_KEY` from the Xcode scheme environment at launch.

1. In Xcode, go to **Product → Scheme → Edit Scheme…** (or `⌘<`)
2. Select **Run** in the left sidebar → **Arguments** tab
3. Under **Environment Variables**, click **+** and add:

| Name | Value |
|------|-------|
| `ANTHROPIC_API_KEY` | `sk-ant-...` |

The key is never written to disk — it lives only in the local scheme, which is gitignored.

---

## Demo without a microphone

If Whisper isn't wired up yet, set a fallback prompt in the same scheme env:

| Name | Value |
|------|-------|
| `ANTHROPIC_NOTCH_DEMO_PROMPT` | `Open Safari and go to x.com` |

Any long-press on the cursor companion will fire the agent using that string as the transcript.

---

## Using the app

- **Hover** over the notch to open it
- **Drag down** on the closed notch to open; **drag up** inside to close
- **Cmd+D** toggles open/closed (grant Accessibility access when prompted; auto-closes after 3 s)
- **Long-press** the cursor companion to start a voice command (hold until the waveform appears, release to send)
- Switch between **Home** (live agent status) and **Settings** (reasoning effort, cursor color, preferences) via the tab bar

---

## Architecture

See `CLAUDE.md` for the full architecture guide and `NOTES.md` for current build status and known gaps.
