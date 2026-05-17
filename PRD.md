# PRD — Agent in the Notch

**Status:** Draft v0.2 (hackathon scope)
**Owner:** Wyatt (notch & UI), Sam (cursor + computer use), Ashan (long-press + context)
**Model:** Claude Sonnet (agent), Gemini multimodal (context summarizer), OpenAI Whisper API (voice)

---

## 1. Vision

A computer-use agent that **lives next to you**, not in a chat window. The agent has a physical presence on your screen — a cursor companion that walks beside your own cursor — and a home in the MacBook notch. It is your pal: it lives on your machine, it knows what you've been doing, and it does your shit.

The project is fundamentally about **agent–human connection**. We're not building a chatbot. We're building a body for the agent.

## 2. Problem We're Solving

**Context.** A computer-use agent is only useful if it knows what the user has been doing. But:

- Passing the last hour of activity directly to the model blows the context window.
- We're using Sonnet. Even so, raw screen history is too noisy to be useful.
- We need a way to compress "the past hour" into something the agent can actually consume.

## 3. Core Concept

Two surfaces:

**The Notch.** Fresh native SwiftUI app. This is the agent's home. It shows settings, live agent progress, tool capabilities, and current state.

**The Cursor Companion.** A small PNG cursor that follows the user's real cursor around the screen. This is the agent's body. Long-press activates voice input. The cursor's color is user-selectable.

The user long-presses to talk to the agent. Whisper transcribes. The agent receives: (a) the transcript, (b) a text summary of the past hour of activity, (c) user preferences and system prompt. Sonnet then acts.

## 4. The Context System (the hard part)

**Decision:** No custom embedding pipeline. Embeddings of screenshots are messy — you can't average 200 screenshot vectors into something coherent. Too much work for a hackathon.

**Approach:** Hybrid screenshot → summary pipeline.

1. **Capture trigger:** Screenshots are taken on **click events** and **app switches**, not on a 5-second timer. Time-based is stale (user watching Netflix = 720 useless screenshots/hour) and brittle. Click-based is deterministic and free of redundancy.
1. **Debounce:** ~1 second between captures to avoid spam from rapid clicks / drag selections.
1. **Cap:** Maintain a rolling buffer, max ~20 screenshots.
1. **Summarization:** One Gemini call per snapshot (not batched), gated by `ContextGeminiObservationGate` to avoid API spam. Each snapshot runs up to 4 parallel lane calls (Activity, UIMap, EntityContent, Interaction) for modular analysis.
1. **Merge:** `ContextActivationBuilder` converts the buffer into a `ContextActivationPacket` with four structured fields: `recentTimeline` (up to 5 facts), `observedTransitions` (up to 3 interactions), `learnedUIMemory` (persistent app/surface memory), and `firstActionGuidance` (suggested first actions).
1. **Inject:** The packet is rendered to a compact text block passed as system context to Sonnet alongside the live voice transcript.

**Why not embeddings:** ML self-embedding image → vectors → reconstruction is ugly. Won't ship in time. Text summary is good enough and inspectable.

**Future:** Replace click-trigger with a richer hook system — new foreground window, new tab opened, application switch. Click is the MVP floor.

## 5. Voice Input

- User **long-presses** the cursor companion to activate.
- OpenAI Whisper API transcribes the recording.
- Transcript is appended to the model's input on release.
- This is the user's intent signal. The screenshot summary is the background context.

## 6. Notch Contents

### 6.1 Live agent state ✅

- What the agent is doing right now.
- Which tool it's calling.
- Progress / status.

Implemented in `Features/Notch/AgentStateView.swift`. Reads from `AgentState.shared` — update that singleton to drive the UI.

### 6.2 Settings (kept minimal) ✅

- **Reasoning effort** — low / medium / high.
- **Preferences** — free-form plain text the user writes. ("When I say 'open Twitter,' I mean x.com, not the support page." "I prefer dark mode tools.") Stored as JSON under the hood, but the user only sees a text box. **No JSON exposed to the user.**
- **System prompt** — advanced override.
- **Cursor color** — red, green, blue, yellow. Four PNG assets, one per color.

Implemented in `Features/Notch/AgentSettingsView.swift`. Persisted via `Core/AgentSettingsStore.swift`.

### 6.3 Explicitly out of scope for v1

- MCP (too much work, too risky for a hackathon).
- Multi-model selection (Sonnet only for now).
- Any settings beyond the four above.

## 7. Architecture

```
┌─────────────────────────────────────────────┐
│  Notch (SwiftUI) — Wyatt                    │
│  - Settings, agent state, tool readouts     │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  Cursor Companion (native Swift) — Sam      │
│  - PNG follows real cursor                  │
│  - Computer use / OS-level actions          │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  Context + Voice Pipeline — Ashan           │
│  - Long-press → Whisper transcription       │
│  - OS hook on click event (debounced 1s)    │
│  - Screenshot → rolling buffer (cap 20)     │
│  - Gemini multimodal (batches of 10, parallel) │
│  - Merge → ≤2 paragraphs of text            │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  Sonnet Agent                                │
│  Inputs:                                    │
│   - Voice transcript (Whisper)              │
│   - Activity summary (Gemini text)          │
│   - User preferences + system prompt        │
│  Output: tool calls / computer actions      │
└─────────────────────────────────────────────┘
```

## 8. Tech Stack

- **Native Swift / SwiftUI** — notch UI, cursor overlay, OS-level click hooks, screenshot capture.
- **Claude Sonnet** — primary agent.
- **Gemini multimodal** — screenshot batch summarizer.
- **OpenAI Whisper API** — voice transcription.

## 9. Team & Responsibilities

| Owner | Status | Deliverable | Notes |
|-------|--------|-------------|-------|
| **Wyatt** | ✅ done | Notch UI (fresh SwiftUI app). Four settings: reasoning effort, preferences text box, system prompt override, cursor color picker. Live agent state readout. All UI/UX polish. Music tab (Spotify now-playing + lyrics). | Settings persisted at `~/Library/Application Support/AgentNotch/agent_settings.json`. Read via `AgentSettingsStore.shared`. |
| **Sam** | ✅ done | Cursor companion — PNG overlay that follows the real cursor. Four color variants (red/green/blue/yellow). Long-press listener, listening/thinking/idle visual states. Computer use integration: Sonnet-driven OS actions (click, type, scroll). | Exposes `setCursorColor(color)` via `AgentInterfaces.cursor`. Set `AgentInterfaces.cursor = self` on init. |
| **Ashan** | ✅ done | Long-press detection → OpenAI Whisper API transcription. Context module: click + app-switch triggered screenshot capture (debounced 1s, rolling buffer of 20), OCR via Vision, modular Gemini lane pipeline per snapshot, merge to `ContextActivationPacket`. Core Sonnet agent wiring — assembles transcript + packet + preferences and fires the model. | Exposes `getRecentActivityContext() -> String` via `AgentInterfaces.context`. Set `AgentInterfaces.context = self` on init. Read settings from `AgentSettingsStore.shared`. |

**Interfaces are the contract.**
- Wyatt's settings panel calls `setCursorColor(color)` on Sam's cursor module.
- Ashan's agent wiring reads user preferences + system prompt from Wyatt's settings store.
- Ashan's context module delivers `getRecentActivityContext() -> String` to the agent — implementation is Ashan's call.

## 10. Milestones

- **v0:** ✅ Notch shell up with four settings (persisted). ✅ Cursor PNG following real cursor. ✅ Long-press records voice. ✅ Screenshot-on-click writes to disk.
- **v1 (MVP):** ✅ Click-with-debounce capture → Gemini summary → text injected into Sonnet → Sonnet acts via computer use. End-to-end loop working.
- **v2 (stretch):** ✅ App-switch capture hook (`NSWorkspace.didActivateApplicationNotification`). ✅ Cursor idle float animation. ❌ Browser tab-change hook (out of scope — requires browser extension or Accessibility crawl).

## 11. Open Questions

- ~~What's the actual click-hook API on macOS, and does it require accessibility permissions?~~ **Resolved:** `CGEvent.tapCreate` with `.listenOnly` — yes, requires Accessibility.
- ~~Gemini batch latency at 10 images?~~ **Resolved:** We run one Gemini call per snapshot, not batched; gated by `ContextGeminiObservationGate` to avoid spam.
- ~~Does the cursor PNG overlay need a transparent always-on-top window?~~ **Resolved:** Yes — `CursorCompanionWindow` is a borderless `NSPanel` at `.screenSaverWindowLevel`.
- ~~Where do user preferences live on disk?~~ **Resolved:** `~/Library/Application Support/AgentNotch/agent_settings.json` — see `Core/AgentSettingsStore.swift`.

## 12. Non-Goals

- No MCP.
- No cloud sync.
- No multi-user / accounts.
- No model picker.
- No embedding pipeline.
- No tracking pixel-level screen changes (too complex, OS-level, out of scope).
