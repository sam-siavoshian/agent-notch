# Agent in the Notch

A macOS computer-use agent that lives in the notch. Voice-activated (long-press the cursor companion), context-aware (captures recent screen activity), powered by Claude Sonnet.

---

## Requirements

- macOS 14+ on an M-series MacBook (physical notch required)
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Apple ID added to Xcode → Settings → Accounts (free Personal Team works) with an Apple Development cert in the login keychain
- An Anthropic API key

---

## First-time setup

```bash
brew install xcodegen
bash scripts/setup-signing.sh   # detects your Apple Dev cert, writes Local.xcconfig
xcodegen generate
open AgentNotch.xcodeproj
```

`setup-signing.sh` is idempotent. Re-run if you switch Apple ID. Re-run `xcodegen generate` any time `Project.yml` or the source layout changes.

### Why the signing script?

Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) regenerates the binary's cdhash on every build. macOS TCC keys permission grants (Accessibility, Screen Recording) by cdhash + cert chain. Ad-hoc rebuild → TCC sees a "different app" → grant invalidated → onboarding red Xs forever.

Signing with your Apple Development cert keeps the Designated Requirement stable across rebuilds, so once you grant a permission, it sticks. Hardened runtime is also off for local dev so declared entitlements survive at runtime without a provisioning profile — otherwise stripped entitlements destabilize the effective signature each launch.

If `scripts/setup-signing.sh` complains it cannot find a cert: open Xcode → Settings → Accounts → Manage Certificates → + → Apple Development, then re-run.

---

## Setting your API keys

**Anthropic** key reads from `ANTHROPIC_API_KEY` in the Xcode scheme environment at launch.

1. In Xcode, **Product → Scheme → Edit Scheme…** (or `⌘<`)
2. Select **Run** → **Arguments** tab
3. Under **Environment Variables**, add:

| Name | Value |
|------|-------|
| `ANTHROPIC_API_KEY` | `sk-ant-...` |

The key is never written to disk — it lives only in the local scheme, which is gitignored.

**OpenAI** (Whisper) key is stored in the macOS Keychain under service `com.agentnotch.app`. `AppDelegate.seedSecrets()` bootstraps a default on first launch; rotate via `Secrets.setOpenAIAPIKey(_:)`.

---

## Permissions

On first launch the onboarding window asks for three TCC grants:

- **Accessibility** — read long-press gesture, drive clicks/keystrokes
- **Screen Recording** — capture activity for context
- **Microphone** — long-press to talk

Click Grant on each. The window auto-relaunches after you return from Settings so the in-process TCC cache flushes.

---

## Demo without a microphone

If you want to fire the agent without Whisper:

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

See `AGENTS.md` and `CLAUDE.md` for module layout and conventions.
See `PRD.md` for the product spec and `NOTES.md` for current build status.
