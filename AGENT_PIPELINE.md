# Computer-Use Agent Pipeline

End-to-end breakdown of how a long-press becomes computer-use actions.

---

## 1. Trigger → transcript

**Long-press on the cursor companion**
- `LongPressDetector` (Features/Cursor/) fires `.longPressBegan` on press, `.longPressEnded` on release.
- `VoiceRecordingService` (Features/Agent/VoiceRecordingService.swift:41) hears `longPressBegan` → starts `AVAudioEngine` recording into a temp WAV at `agentnotch_voice_<ts>.wav`.
- On `longPressEnded` → uploads the WAV to **OpenAI Whisper** (`whisper-1`, multipart POST to `api.openai.com/v1/audio/transcriptions`). `language=en` (skips auto-detection); `prompt="Computer command for a Mac agent. App names, URLs, system actions."` (primes vocabulary).
- Result is written to `AgentState.shared.lastTranscript`; posts `.transcriptReady`.
- Demo fallback: if no audio captured AND `ANTHROPIC_NOTCH_DEMO_PROMPT` is set, that string is used as the transcript.

## 2. `AgentSession.fireAgentTurn`

Features/Agent/AgentSession.swift:42 wakes on `.transcriptReady`:
1. Records `longPressTranscript` to `AgentObservabilityLog` (start of the run).
2. Calls **`ContextSelector.shared.select(transcript:)`** → returns `{intent, brief, l2, initiationScreenshot, degraded, latency, model}`.
3. Maps the new `CIntent` shape back into legacy `ContextResolvedIntent` for the harness `Input`.
4. Calls `ComputerUseHarness.shared.run(input)` with `{transcript, contextSummary: brief, resolvedIntent, initiationScreenshot}`.

There is **no second context call** between the selector and the harness — the brief is authoritative.

## 3. `ContextSelector` — what builds the brief

Features/Context/Selector.swift:48. Total budget ~3.5s worst case.

### 3a. L2 snapshot (0.4s deadline, parallel)
Features/Context/L2Snapshotter.swift:38. Returns `(CL2Snapshot, screenshotJPEG)`:
- Frontmost app + bundleID + pid (`NSWorkspace`)
- Window title via AX
- Display id + bounds
- **Screenshot + OCR** (≤250ms): full-res raw image → Vision OCR (top 80 lines); downsampled JPEG (≤1568 long edge, q=0.7) kept separate for Claude
- **AX dump** (≤150ms): walks frontmost window 3 levels deep / max 50 elements, prioritized to clickable roles (Button, MenuItem, Link, TextField, etc.) with `role+label+axPath+bbox+focused`
- **Adapter blob** (200ms): per-app data via `AdapterRegistry` — Browser (URL + tab title via AppleScript, scrubs `user:pass@` + secret query params), Terminal (cwd from OSC 7 reporter or AppleScript scrape), IDE (window-title parse + `.git` walk)
- **Selection** via `AXObserverManager.shared.focusedElementDescriptor`
- **Clipboard** via `NSPasteboard.general.string(.string)` — first 200 chars + byte count
- **Cursor position** flipped to top-left origin

### 3b. Supporting state (mostly free, persisted)
- **Active task** from `L5Store` (`~/Library/Application Support/AgentNotch/ContextMemory/active_task.json`). If stale (>30s) the selector synchronously refreshes via `ActiveTaskUpdater.refresh(timeout: 2.0)`.
- **Last 10 events** from `EventLog` (ring buffer of keystrokes/clicks/copy_paste/dwell/AX events).
- **Top 20 recent resources** from `ResourceIndex` (LRU of URIs/files/channels touched, capacity 100).
- **Recipes for active app** from `AnchorRecorder.recipes(for: bundleID)` (top 8 by `seenCount`).
- **Learned surfaces** from `SurfaceMemoryStore.memories(for: app)` — top 6 surfaces × top 12 controls each, sorted by `observationCount`.
- **Recent story** from `CaptureStoryLog` — last 20 entries, filtered to last 5 minutes. Each is `{t, app, surface, narrative, current_goal_guess, content_type, artifact}` from prior **Gemini observer** captures.
- **User prefs** from `AgentSettingsStore.preferences`.

### 3c. Mercury 2 call (≤2.5s)
`MercuryClient.complete` (Features/Context/MercuryClient.swift) → `inception/mercury-2` via OpenRouter, `response_format=json_object`, `max_tokens=1200`. Text-only (no image — the JPEG is forwarded to Claude separately).

**System prompt** (Selector.swift:160) tells Mercury it's a context selector that must output `{intent, brief}` in one call:
- Resolve deictic refs ("the draft", "her", "that PR") using `active_task`/`recent_events`/`recent_resources`/`clipboard`
- Write a markdown brief ≤600 tokens with a strict template: `## What the user wants` / `## You are here` / `## How to do it on <app>` / `## What "<deictic>" means` / `## Watch out for`
- Lead with non-vision tools (`open_url` > `applescript` > `run_shortcut` > `ax_query+ax_press` > `menu_shortcut` > `computer`)
- Coordinate-free, anchors only, no invented recipes/paths
- Use `learned_surfaces` as canonical UI map; use `recent_story` for continuity

**User message**: a JSON dump of the entire `Payload` struct: transcript + L2 snapshot + user_prefs + active_task + recent_events + recent_resources + recipes_for_active_app + learned_surfaces + recent_story.

### 3d. Fallback
If Mercury times out / has no key / returns malformed JSON → `LocalBriefRenderer.render` (Features/Context/LocalBriefRenderer.swift) builds a deterministic Swift-rendered brief from the same inputs. Verb is matched against a hardcoded list (`open/send/run/close/save/find/...`), entities are pulled from active_task by string match, confidence pinned to `0.4`. Marked `degraded: true`.

## 4. `ComputerUseHarness.run` — preflight + first turn

Features/Agent/ComputerUseHarness.swift:73.

### 4a. Fast-path IntentRouter (no model call at all)
Features/Agent/IntentRouter.swift:27. Before any Anthropic call:
- **Safety blocklist**: if transcript contains `delete/erase/format/wipe/remove/uninstall/shutdown/restart/log out/purchase/buy/pay/send money` → fall through to model.
- **OpenURLIntent**: explicit `http(s)://` in transcript, or `open|go to|navigate to|visit <domain>` (with " dot " → "." normalization) → `NSWorkspace.open`.
- **SpotifyIntent**: requires "spotify" in transcript + transport verb (`pause/stop/resume/next/skip/previous`) OR `play <q> on spotify` → AppleScript or `spotify:search:` URL.
- **ReminderIntent**: `remind me to <X>` / `add a reminder to <X>` → AppleScript create reminder.

If handled → speaks the affirmation, records metrics with `modelID="fast_path"`, returns. **Zero model turns.**

### 4b. Build the model request

**System blocks** (two; cache breakpoint between them):

*Block 1 (cached server-side via `cache_control: ephemeral`)* — the static ACTOR prompt, hardcoded in `buildSystemBlocks` (Features/Agent/ComputerUseHarness.swift:567):
> "You are an on-screen macOS computer-use ACTOR — not a chatbot, not an assistant. Your only outputs are tool calls and (on turn 1) a 9-word spoken affirmation..."

Key rules in that prompt:
- Tool preference order (open_url → applescript → run_shortcut → ax_query → menu_shortcut → computer)
- Plan-then-act: one short sentence + ≤9-word spoken affirmation + tool call on turn 1; no prose after turn 1
- Screenshots are "your eyes" — initiation screenshot is in user message 1; take `computer.screenshot` first if unsure
- Don't screenshot to "verify" before fast-path tools
- Never ask clarifying questions
- Every assistant message must contain a tool call or `stop_task` declaration
- Refuse irreversible destructive actions

*Block 2 (uncached, dynamic)* — concatenation of:
1. Rendered `resolvedIntent` ("Resolved user intent: ... Verb: ... Target: ... Resolved entities: ...") — skipped if `usedFallback`
2. **The Mercury brief verbatim** (the `## What the user wants` / `## You are here` markdown)
3. `User preferences:\n<prefs>` from settings
4. User's custom `systemPrompt` from settings (if set)
5. `Reasoning effort: low|medium|high.`

**Tools** (`buildTools`, Features/Agent/ComputerUseHarness.swift:468):
- `open_url` (custom)
- `applescript` (custom, allowlist: Safari/Chrome/Spotify/Music/Messages/Mail/Notes/Reminders/Calendar/Finder)
- `run_shortcut` (custom, wraps `/usr/bin/shortcuts run`)
- `ax_query`, `ax_press`, `ax_set_value` (custom, via `AXFastPath`)
- `menu_shortcut` (custom — looks up menu item by title substring, sends its keyboard shortcut)
- `computer` (Anthropic built-in: `computer_20241022` or current beta, with `displayWidth/displayHeight` = primary display × backing scale; last tool gets `cache: true`)

**First user message** (Features/Agent/ComputerUseHarness.swift:165):
- Text block: the raw transcript (`input.transcript`)
- If `initiationScreenshot` non-nil: an `image` block with the base64 JPEG (same frame OCR ran on). This eliminates the throwaway `computer.screenshot` turn that used to start every run.

**Request shape** (`AnthropicMessageRequest`, Features/Agent/AnthropicClient.swift):
- `model`: `AnthropicModel.haiku45` (the harness has `modelID = haiku45`, `fallbackModelID = haiku45`)
- `max_tokens`: 4096
- `betaHeaders`: `computer-use-2025-01-24, prompt-caching-2024-07-31`
- `anthropic-version: 2023-06-01`

## 5. The turn loop

For each turn (up to `maxTurns=100`):
1. `applyRollingCacheMarker` (Features/Agent/ComputerUseHarness.swift:623) — moves `cache_control: ephemeral` to the most recent `tool_result` user message, strips it from older ones. Anthropic caps at 4 markers; this keeps the request body cacheable as the history grows.
2. POST to Anthropic. Log usage (`input/output/cache_create/cache_read` tokens).
3. Append the assistant's `content` to `messages`.
4. Extract `tool_use` blocks. If none → speak the text (capped 9 words), set state idle, record metrics, return.
5. On turn 1, if the assistant emitted text alongside tools → speak it (the affirmation).
6. For each tool_use: `ToolDispatcher.dispatch(toolUseId, name, input)`:
   - `computer.screenshot`: `ScreenCapture.shared.snapshot()` → base64 JPEG returned as `image` block
   - `computer.left_click/right_click/double_click/middle_click`: `CGEvent(mouseEventSource: nil, ...)` posted to `cghidEventTap`
   - `computer.left_click_drag`: down → drag → up
   - `computer.mouse_move`, `cursor_position`, `scroll`, `wait`, `hold_key`
   - `computer.type`: >4 chars + all-ASCII → **pasteboard path** (save pasteboard, write text, post Cmd+V via `postKeyCombo`, restore after 200ms). Else per-codepoint Unicode keystroke.
   - `computer.key`: parsed `cmd+shift+t`-style combo → `CGEvent` keyboard
   - `open_url`, `applescript` (via `AppleScriptBridge`), `run_shortcut` (`/usr/bin/shortcuts run`, stdin piped if `input` provided)
   - `ax_query/ax_press/ax_set_value`: `AXFastPath.shared` walks accessibility tree, returns ids
   - `menu_shortcut`: `AXFastPath.menuBarShortcut(forTitle:)` → posts the registered keystroke
7. All results bundled into one `user` message with `tool_result` blocks. Loop.
8. Exit conditions: `stop_reason != "tool_use"` → done; `stopRequested` → stopped; `turn > maxTurns` → error.

## 6. What gets recorded along the way

- `AgentObservabilityLog.shared` — single ring buffer of `longPressTranscript / l2Snapshot / selectorRun / mercuryCall / harnessTurn` for the Dev Tools timeline (Cmd+Shift+I).
- `HarnessRunDetailStore.shared` — per-run rollup: system block summaries, every turn's request/response timestamps, token counts, tool calls, result previews.
- `AgentRunMetricsRecord` printed at end of run (durationMs, turnCount, toolCallCount, screenshotToolCallCount, time-to-first-non-screenshot-action, finalStatus).

---

## TL;DR — what Claude actually sees on turn 1

**System** (two blocks, first cached):
1. ACTOR prompt (tool preference, plan-then-act, no clarifying questions, refuse destructives)
2. Resolved intent + **Mercury brief** + user prefs + custom prompt + reasoning effort

**Tools**: 7 custom + Anthropic `computer`

**User message**:
- Whisper transcript (text)
- Initiation screenshot JPEG (image block, no cache)

The brief itself is where ~all the "smarts" live — it's where L2 (live screen), L3 (recipes), L4 (prefs), L5 (active_task + resources), `learned_surfaces` (Gemini's accumulated UI knowledge), and `recent_story` (last 5min of Gemini observations) get distilled by Mercury 2 into ~600 tokens of grounded markdown. Long-press never calls Gemini directly — Gemini's value at long-press time is the SurfaceMemoryStore + CaptureStoryLog it built up during prior background captures.
