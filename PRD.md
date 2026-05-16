# PRD — Agent in the Notch

**Status:** Draft v0.1 (hackathon scope)
**Owner:** Sam (notch + cursor), Arshan (context + long-press), Harshal (TBD)
**Model:** Claude Haiku (agent), Gemini multimodal (context summarizer), Whisper (voice)

-----

## 1. Vision

A computer-use agent that **lives next to you**, not in a chat window. The agent has a physical presence on your screen — a cursor companion that walks beside your own cursor — and a home in the MacBook notch. It is your pal: it lives on your machine, it knows what you’ve been doing, and it does your shit.

The project is fundamentally about **agent–human connection**. We’re not building a chatbot. We’re building a body for the agent.

## 2. Problem We’re Solving

**Context.** A computer-use agent is only useful if it knows what the user has been doing. But:

- Passing the last hour of activity directly to the model blows the context window.
- We’re using Haiku (small, fast, cheap, dumb). It cannot handle raw screen history.
- We need a way to compress “the past hour” into something the agent can actually consume.

## 3. Core Concept

Two surfaces:

**The Notch.** Forked from NotchNoir, native SwiftUI. This is the agent’s home. It shows settings, live agent progress, tool capabilities, and current state.

**The Cursor Companion.** A small PNG cursor that follows the user’s real cursor around the screen. This is the agent’s body. Long-press activates voice input. The cursor’s color is user-selectable.

The user long-presses to talk to the agent. Whisper transcribes. The agent receives: (a) the transcript, (b) a text summary of the past hour of activity, (c) user preferences and system prompt. Haiku then acts.

## 4. The Context System (the hard part)

**Decision:** No custom embedding pipeline. Embeddings of screenshots are messy — you can’t average 200 screenshot vectors into something coherent. Too much work for a hackathon.

**Approach:** Hybrid screenshot → summary pipeline.

1. **Capture trigger:** Screenshots are taken on **click events**, not on a 5-second timer. Time-based is stale (user watching Netflix = 720 useless screenshots/hour) and brittle. Click-based is deterministic and free of redundancy.
1. **Debounce:** ~1 second between captures to avoid spam from rapid clicks / drag selections.
1. **Cap:** Maintain a rolling buffer, max ~20 screenshots.
1. **Summarization:** Batch the buffer (batches of ~10) into Gemini multimodal in parallel. Output: short text summaries per batch.
1. **Merge:** Concatenate / synthesize the batch summaries into **max 2 paragraphs of plain text** describing what the user has been doing. (“User has been editing a spreadsheet in Excel, then switched to Chrome and opened three tabs about Italian rentals…”)
1. **Inject:** That text is passed as system context to Haiku alongside the live voice transcript.

**Why not embeddings:** ML self-embedding image → vectors → reconstruction is ugly. Won’t ship in time. Text summary is good enough and inspectable.

**Future:** Replace click-trigger with a richer hook system — new foreground window, new tab opened, application switch. Click is the MVP floor.

## 5. Voice Input

- User **long-presses** to activate.
- Whisper transcribes locally / via API.
- Transcript is appended to the model’s input on release.
- This is the user’s intent signal. The screenshot summary is the background context.

## 6. Notch Contents

### 6.1 Live agent state

- What the agent is doing right now.
- Which tool it’s calling.
- Progress / status.

### 6.2 Settings (kept minimal)

- **Reasoning effort** — low / medium / high.
- **Preferences** — free-form plain text the user writes. (“When I say ‘open Twitter,’ I mean x.com, not the support page.” “I prefer dark mode tools.”) Stored as JSON under the hood, but the user only sees a text box. **No JSON exposed to the user.**
- **System prompt** — advanced override.
- **Cursor color** — red, green, blue, yellow. Four PNG assets, one per color.

### 6.3 Explicitly out of scope for v1

- MCP (too much work, too risky for a hackathon).
- Multi-model selection (Haiku only).
- Any settings beyond the four above.

## 7. Architecture

```
┌─────────────────────────────────────────────┐
│  Notch (SwiftUI)                            │
│  - Settings, agent state, tool readouts     │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  Cursor Companion (native Swift)            │
│  - PNG follows real cursor                  │
│  - Long-press → Whisper                     │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  Context Pipeline                           │
│  - OS hook on click event (debounced 1s)    │
│  - Screenshot → rolling buffer (cap 20)     │
│  - Gemini multimodal (batches of 10, parallel) │
│  - Merge → ≤2 paragraphs of text            │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  Haiku Agent                                │
│  Inputs:                                    │
│   - Voice transcript (Whisper)              │
│   - Activity summary (Gemini text)          │
│   - User preferences + system prompt        │
│  Output: tool calls / computer actions      │
└─────────────────────────────────────────────┘
```

## 8. Tech Stack

- **Native Swift / SwiftUI** — notch UI, cursor overlay, OS-level click hooks, screenshot capture.
- **Claude Haiku** — primary agent.
- **Gemini multimodal** — screenshot batch summarizer.
- **Whisper** — voice transcription.

## 9. Team & Responsibilities

|Owner      |Deliverable                                                                                                                                                                                                                                                  |Deadline                                  |
|-----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------|
|**Sam**    |Notch UI (forked NotchNoir). Four settings shown above. Cursor color module exposing a single API: pass me a color, I update the cursor PNG. Generate four cursor PNGs (red/green/blue/yellow).                                                              |~3 hours for first cut, ideally ~30–60 min|
|**Arshan** |Long-press → Whisper module. Context module: takes whatever input it needs and **returns a plain-text paragraph** describing recent user activity, ready to drop into Haiku’s context. Implementation free — clicks, hooks, whatever — just deliver the text.|≤2 hours                                  |
|**Harshal**|Verifying Gemini embedding feasibility (decision: probably skip in favor of the summarization path above). Then core agent wiring.                                                                                                                           |Ongoing                                   |

**Interfaces are the contract.** Sam needs a `setCursorColor(color)` API on his side and consumes nothing else. Arshan needs to expose a `getRecentActivityContext() -> String` (or equivalent) that returns ≤2 paragraphs of text. Everything else is implementation detail.

## 10. Milestones

- **v0 (next 1–3 hours):** Notch shell up with the four settings. Cursor PNG following real cursor in one color. Long-press records voice. Screenshot-on-click writes to disk.
- **v1 (MVP):** Click-with-debounce capture → Gemini summary → text injected into Haiku → Haiku acts. End-to-end loop working.
- **v2 (stretch):** Richer capture hooks beyond clicks — foreground window change, tab change, app switch. Smarter cursor behavior (idle states, signaling).

## 11. Open Questions

- What’s the actual click-hook API on macOS, and does it require accessibility permissions? (Sam to confirm.)
- Gemini batch latency at 10 images — does this stay under a few seconds? (Arshan to benchmark.)
- Does the cursor PNG overlay need a transparent always-on-top window, and does that interfere with click capture? (Sam.)
- Where do user preferences live on disk? Just a local JSON, no sync for v1.

## 12. Non-Goals

- No MCP.
- No cloud sync.
- No multi-user / accounts.
- No model picker.
- No embedding pipeline.
- No tracking pixel-level screen changes (too complex, OS-level, out of scope).
