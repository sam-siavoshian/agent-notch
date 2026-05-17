# Context System Redesign — Design Spec

**Date:** 2026-05-16
**Owner:** Ashan (Context), with handoffs to Wyatt (Notch settings UI) and Sam (Cursor) flagged as follow-ups.
**Status:** Approved — proceeding to implementation plan.

---

## 1. Problem

AgentNotch's Context subsystem was designed as a passive watcher that learns how the user works. In its current form it produces a richly worded *autobiography* of the user — markdown sections on Habits, Visits, Time-of-day, Entities In Play, semantic Affordances — but it is not a usable **manual for the agent**. Three concrete failures:

1. **No grounding for action.** The Gemini extraction prompt explicitly forbids pixel coordinates. The agent drives CGEvent and needs either coordinates or coord-free anchors (shortcuts, AX selectors, menu paths, URLs). Memory provides neither.
2. **Stale by construction.** The Gemini fan-out lands 10–20s after the activation snapshot, so the agent always sees memory derived from *previous* state.
3. **Signal-to-noise ~15%.** Of the ~600-token activation packet, most is autobiographical flavor; only a small fraction tells the agent what to *do*.

The agent module (`ComputerUseHarness`) is structurally sound (cached static system block, un-cached dynamic block, rolling cache marker on tool results, eight tools with `computer` as last-resort vision). The bottleneck is the string fed into the un-cached system block.

The product premise is correct: *watch the user passively so the agent doesn't have to discover things from scratch*. The implementation pursues that premise via the wrong artifact (long-form prose) and the wrong contract (coordinate-stripped semantic descriptions).

## 2. Goals & non-goals

### Goals
- A context blob the agent can act on without a screenshot for its first turn whenever possible.
- Memory whose primitive is **anchors** (shortcuts, AX paths, menu items, URLs, AppleScript) — never pixel coordinates.
- Continuous memory across screenshots: a structured `active_task` object Mercury maintains, not just a per-screenshot event dump.
- Multi-resolution memory (raw 60s / segments / active task / today archive) so different intents can read the right horizon.
- One LLM in the loop (Mercury 2). Gemini pipeline ripped out.
- Graceful local-only fallback when Mercury or the network fails.
- Storage and pipeline shaped to extend from a 1-hour scope (v1) to longer horizons via policy changes, not schema changes.

### Non-goals (v1)
- No embeddings / vector search.
- No long-horizon (>1 day) memory yet. The schema supports it; the rollup/decay policies are deferred.
- No automatic preference inference (L4 `per_app` reserved but unpopulated).
- No mid-turn "fetch more context" tool — the brief is generated once per long-press.
- No Onboarding flow redesign for keystroke logging consent (follow-up, called out below).
- No notch UI redesign for the new collection toggle / never-log list editor (follow-up).

## 3. Architecture overview

This spec is one cohesive design. **Decomposition into shippable phases is the job of the implementation plan** (writing-plans) that follows — see §12 for the suggested phase boundaries called out as follow-ups.

Two pipelines, one model.

```
  ┌────────────── COLLECTION (always running) ──────────────┐
  │                                                         │
  │  Keystroke + AX monitor ─┐                              │
  │  ContextClickMonitor   ──┤─→ AnchorRecorder ─→ L3 lib   │
  │  AppSwitchMonitor      ──┘     (per-app recipes)        │
  │                                                         │
  │  ScreenCapture + OCR + AX dump ─→ event log → L5 log    │
  │  DirtyDetector gates the capture                        │
  │                                                         │
  │  Clipboard / Dwell / Search monitors ─→ event log       │
  │                                                         │
  │  App-specific adapters (Browser / Terminal / IDE)       │
  │    feed resources_index continuously and provide L2     │
  │    app_specific snapshot at long-press                  │
  │                                                         │
  │  Every ~90s (or on big context shift):                  │
  │    Mercury 2 (text): events → updated active_task       │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

  ┌────────────── SELECTION (long-press) ───────────────────┐
  │                                                         │
  │  Whisper transcript ─┐                                  │
  │  L2 fresh snapshot ──┤                                  │
  │  L3 anchors for app ─┼─→ Mercury 2 (single call) ────┐  │
  │  L4 preferences    ──┤   returns {intent, brief}     │  │
  │  L5 summary + tail ──┘                                │  │
  │                                                       ▼  │
  │                              ComputerUseHarness         │
  │                              (existing, untouched)      │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**Three rules that fall out of this:**

1. **No LLM in the per-event extraction path.** Local monitors are deterministic sources of truth for L2/L3/L5 events. Mercury appears only in three discrete synthesis roles (§3.1 below) — never on the hot path of an individual event.
2. **No coordinates in memory.** L3 stores anchors only. Coordinates are derived at runtime from fresh AX query in L2 (valid for the current turn only).
3. **One model in the context layer.** Mercury 2 has three small roles inside the context subsystem: (a) maintains the rolling `active_task` in the background (~90s cadence), (b) writes the brief at long-press, (c) names recipes once on promotion. **Scope clarification:** the action-taking computer-use model inside `ComputerUseHarness` remains Claude (`claude-haiku-4-5` today) and is out of scope for this spec. After this lands the system has two LLMs total — Mercury (context) and Claude (action). Gemini is gone entirely.

## 4. Data shapes — the five layers

### L1 — Intent (per-request, ephemeral)

Returned by the Selector call alongside the brief.

```jsonc
{
  "verb": "send",
  "target": "the draft",
  "resolved_target": "Figma file 'Onboarding v3'",
  "entities": [
    {"label": "Maya", "kind": "person", "resolved_to": "Maya Chen @maya"}
  ],
  "confidence": 0.78
}
```

### L2 — Current screen (per-turn, never cached)

Assembled synchronously at long-press.

```jsonc
{
  "app": "Slack",
  "bundle_id": "com.tinyspeck.slackmacgap",
  "pid": 6234,
  "window_title": "design — Studio HQ",
  "window_id": 142,                                // CGWindowID
  "display_id": 1,                                 // CGDirectDisplayID of display containing window
  "display_bounds": [0, 0, 1728, 1117],
  "captured_at": "2026-05-16T19:42:11Z",
  "ocr_lines": [/* up to ~10 filtered useful lines */],
  "ax_elements": [
    {
      "role": "AXButton",
      "label": "Send",                              // → tool-callable form: ax_query/ax_press by role+label
      "ax_path": "AXWindow/AXGroup[2]/AXButton[Send]",  // richer identifier for dedup; not directly tool-callable
      "bbox": [847, 612, 60, 28],
      "focused": false
    }
  ],
  "cursor": [612, 590],
  "selection": "<current text selection if any>",
  "clipboard": {
    "kind": "text",
    "preview": "https://figma.com/file/abc/Onboarding-v3",
    "bytes": 47,
    "age_s": 12,
    "source_app": "Figma",                          // taint tag from copy event (see §5 PrivacyGate)
    "source_bundle_id": "com.figma.Desktop"
  },
  "app_specific": { /* shape varies per adapter, see §6 */ }
}
```

Bboxes and pixel positions only live here, valid for the current turn only — the harness's `computer` and `ax_*` tools always re-query. **Display alignment:** `display_id` matches `CGDirectDisplayID`; `ScreenCapture` must capture the display containing the frontmost window (today it hard-codes display 1, see §10 risk #6); `ComputerUseHarness.computer` declaration must use the same `displayNumber`. **Anchor → tool-call translation:** Mercury writes briefs in terms of tool-callable forms — `ax_query` takes role+label+value, `menu_shortcut` takes a title substring. Memory may store richer `ax_path` strings for dedup/matching, but only the tool-callable fields appear in briefs.

### L3 — Operational knowledge (durable, per-app)

Coord-free recipes inferred from observation. Step kinds:
`shortcut | type | key | menu | url | shell_cmd | open_file | applescript`.

```jsonc
{
  "app_bundle_id": "com.tinyspeck.slackmacgap",
  "recipes": [
    {
      "name": "open DM with person",
      "trigger_pattern": "open DM | message <person> | DM <person>",
      "steps": [
        {"kind": "shortcut", "keys": "cmd+k"},
        {"kind": "type", "value": "<person.name>"},
        {"kind": "key", "keys": "return"}
      ],
      "seen_count": 7,
      "last_seen": "2026-05-16T19:30:00Z",
      "confidence": 0.92
    }
  ],
  "candidates": [/* same shape, seen_count < 3, not yet promoted */],
  "shortcuts": [
    {"keys": "cmd+k", "label": "Quick Switcher", "seen_count": 23}
  ],
  "menu_paths": [
    {"path": ["File", "New Message"], "seen_count": 2}
  ]
}
```

Eviction: per-app LRU cap of 50 recipes + 200 candidates. Recipes not seen in 14d drop confidence; 30d → archived. (Effective only at >24h horizons; included now so the schema doesn't need to change later.)

### L4 — Preferences

```jsonc
{
  "explicit": "I use Arc for browsing. Prefer concise messages.",
  "per_app": {}  // reserved; v1 leaves empty
}
```

`explicit` is the user-edited string from `AgentSettingsStore` (already exists).

### L5 — Narrative (multi-resolution)

The continuous-memory layer.

```jsonc
{
  "active_task": {
    "id": "t_2026-05-16_19",
    "started_at": "2026-05-16T19:02:00Z",
    "label": "Iterate onboarding v3 in Figma + coordinate with Maya",
    "kind": "design_iteration",
    "narrative": "User has been iterating on Figma's 'Onboarding v3' for 40 min...",
    "actions_taken": [
      {"t": "19:15Z", "what": "duplicated 'Step 1' frame → 'Step 2 — verify email'"}
    ],
    "resources": [
      "figma://file/abc/Onboarding-v3#frame:Step-2",
      "slack://channel/T123/C456?ts=1747422120"
    ],
    "entities": [
      {"label": "Maya Chen",       "kind": "person",  "slack_handle": "@maya"},
      {"label": "Onboarding v3",   "kind": "file",    "uri": "figma://file/abc/Onboarding-v3"},
      {"label": "#design",         "kind": "channel", "uri": "slack://channel/T123/C456"}
    ],
    "blocked_on": null,
    "likely_next_steps": ["apply Maya's copy suggestion", "post updated screenshot"]
  },
  "recent_tasks": [
    {
      "id": "t_2026-05-16_17",
      "label": "Fix TTS streaming bug",
      "ended_at": "18:50Z",
      "outcome": "merged PR #1342",
      "kind": "coding"
    }
  ],
  "recent_resources": [
    {
      "kind": "url",
      "uri": "https://figma.com/file/abc/Onboarding-v3",
      "label": "Onboarding v3",
      "app": "Figma",
      "last_seen": "19:34Z"
    }
  ],
  "event_log_tail": [/* last ~10 events, full shape */]
}
```

Read horizons (selector picks based on intent):
| Horizon | Source | Form |
|---|---|---|
| Last ~60s | `events.jsonl` tail | raw events |
| Last ~10 min | event log + per-segment one-liners | events + Mercury one-liners (generated lazily by ActiveTaskUpdater) |
| Current task | `active_task` | structured object |
| Today | `task_archive/<date>.jsonl` | list of `recent_tasks` |

### Event types (the L5 source)

**Base envelope** — every event has:

```jsonc
{
  "t":               "2026-05-16T19:42:11.123Z",   // ISO8601 UTC with ms
  "seq":             18472,                          // monotonic per session
  "kind":            "input",                        // see variants below
  "source_monitor":  "KeystrokeMonitor",             // which subsystem produced it
  "app":             "Slack",
  "bundle_id":       "com.tinyspeck.slackmacgap",
  "pid":             6234,
  "window_title":    "design — Studio HQ",
  "window_id":       142,
  "display_id":      1,
  "redacted":        false,                          // true if PrivacyGate stripped anything
  "redaction_reason": null                           // "secure_input" | "password_shape" | "never_log_paste" | null
}
```

Variants below add their own fields:

```jsonc
{"kind": "screen",      "surface": "frame: Step 2"}
{"kind": "input",       "element": "AXTextArea[Message #design]", "text": "like this?", "context": "replying to Maya", "submit_key": "return", "modifiers": []}
{"kind": "click",       "element_label": "Send", "ax_role": "AXButton", "modifiers": []}
{"kind": "copy_paste",  "from": {"app": "Figma", "selection": "frame image"}, "to": {"app": "Slack", "element": "AXTextArea[Message #design]"}, "change_count": 4192}
{"kind": "dwell",       "duration_s": 124, "signal": "deep focus"}
{"kind": "backtrack",   "from_app": "Slack", "to_app": "Figma", "interval_s": 30, "signal": "tweak-and-show loop"}
{"kind": "search",      "query": "maya step 2"}
{"kind": "app_switch",  "from_bundle": "com.figma.Desktop", "to_bundle": "com.tinyspeck.slackmacgap"}
```

`input` events include `submit_key` (the terminating key — `return`, `tab`, `cmd+return`, or `idle_timeout`) and `modifiers` for the typing burst's final keystroke.

## 5. Collection pipeline

```
                          ┌─────────────────────┐
  CGEvent tap (keys) ────▶│                     │
  AXObserver (focus,     │                     │
   press, value-change) ▶│                     │
  ContextClickMonitor ──▶│                     │
  NSPasteboard polling ─▶│   EventIngester     │──▶  EventLog
  Dwell timer           ▶│   (PrivacyGate +    │     (ring buffer
  AppSwitchMonitor     ─▶│    Normalizer)      │      + jsonl)
  ScreenCapture + OCR  ─▶│                     │
  DirtyDetector gates ──▶│                     │
                          │                     │
  App adapters ─────────▶│                     │──▶  resources_index
                          └─────────────────────┘
                                    │
                                    ├──▶  AnchorRecorder ──▶  L3 recipe candidates
                                    │
                                    └──▶  ActiveTaskUpdater (Mercury, ~90s) ──▶  L5 active_task
```

### Sources

| Source | Behavior |
|---|---|
| `KeystrokeMonitor` | `CGEvent.tapCreate(.cgSessionEventTap, ...)` on `.keyDown`. **Requires the user to grant Input Monitoring TCC permission — separate from Accessibility.** Check `CGPreflightListenEventAccess()` at startup; if denied, monitor enters degraded mode (no key events; AX still works). Captures keycode, modifiers, character (only when focused element is *not* a secure-input field), focused AX element. Burst-batches into `input` events: ≥3 chars to the same focused element within 2s → buffer; finalize on focus change / 1.5s idle / submit-key. |
| `AXObserver` | Per-PID observer, **lifecycle managed via `NSWorkspace.didActivateApplicationNotification` / `didTerminateApplicationNotification`**: create observer on first activation of a PID, destroy on termination. Subscribes to `kAXFocusedUIElementChangedNotification`, `kAXValueChangedNotification`, `kAXSelectedTextChangedNotification`, `kAXMenuItemSelectedNotification`. Apps that don't support a given notification fall back to focused-element polling at 1Hz while frontmost. Used by KeystrokeMonitor for focus tagging, AnchorRecorder for press/menu candidates, L2 snapshot for `selection`. |
| `ContextClickMonitor` | Existing. Extended with a small adapter that emits `click` events to `EventLog`. |
| `ContextAppSwitchMonitor` | Existing. Extended to emit `app_switch` events. |
| `ClipboardWatcher` | Polls `NSPasteboard.general.changeCount` at 500ms (only when delta detected — no read otherwise). Captures `{kind, bytes, preview, source_app, source_bundle_id, change_count, written_by_agent}`. Text preview ≤200 chars; images encoded as `<image:WxH>`. Stores last 20. **Self-paste suppression:** the agent's `computer.type` tool writes the pasteboard internally; `ToolDispatcher` notifies `ClipboardWatcher` of these writes (via a shared self-paste registry tagged by change_count) so they don't poison `copy_paste` correlation. **Cross-app paste suppression:** if `source_bundle_id ∈ never_log_apps`, the *paste* event in any target app is dropped, even when the target is normally logged — the password follows the clipboard. |
| `DwellTimer` | Per `(app, window_title)` accumulator. Emits `dwell` when user leaves and stays away ≥10s. Discards dwells <15s (navigation noise). |
| `ScreenCapture + OCR` | Existing. `DirtyDetector` gates: unchanged → skip, minor → screenshot only, major → screenshot + emit `screen` event. |
| App adapters | Two contexts: (a) called at every L2 snapshot for `app_specific` blob (200ms hard deadline); (b) periodically (30s active app, on focus change for others) refreshing `recent_resources`. |

### EventIngester: PrivacyGate + Normalizer

Every event passes through `PrivacyGate` in this order. Each gate that fires sets `redacted: true` and the corresponding `redaction_reason`:

1. **Frontmost-app check.** If `frontmost_bundle_id` ∈ `never_log_apps` (default: `com.1password.1password7`, `com.1password.1password8`, `com.bitwarden.desktop`, `com.apple.keychainaccess`, `com.mowglii.ItsycalApp` for any user-added entries — list editable in settings), drop the event entirely. Sets nothing because the event is gone.
2. **Clipboard taint propagation.** If event is `paste` (input event with paste source) or `copy_paste` and the *source* bundle_id ∈ `never_log_apps`, drop the event. This catches "copied from 1Password → pasted into Slack."
3. **Secure-input check.** If focused AX element role is `AXSecureTextField` OR `IsSecureEventInputEnabled()` returns true, drop text content from `input` events. Keep event shell with `text: "<redacted>"`, `redaction_reason: "secure_input"`.
4. **Browser password heuristics.** When frontmost app is a browser AND BrowserAdapter reports either (a) focused element role is HTML password (role=`AXTextField` with `subrole=AXSecureTextField` or via DOM hint from JS bridge), or (b) URL path matches `/login|/signin|/password|/account/security/`, drop text content with `redaction_reason: "browser_password_context"`.
5. **URL credential stripping** (BrowserAdapter only). Strip `user:pass@` userinfo from URLs. Strip URL query params matching `(token|key|secret|password|auth|api_key|access_token|sig|signature)`. Applied at adapter emit time; never persisted raw.
6. **Clipboard sensitivity heuristic.** If preview matches password-shaped patterns (length 8–64, Shannon entropy > 3.5 bits/char, mix of character classes), drop preview, keep `{kind, bytes}`, set `redaction_reason: "password_shape"`.
7. **Pause flag.** Single boolean `AgentSettingsStore.collectionPaused`. When true, only `app_switch` and (≤1/min) `screen` events kept.
8. **Normalize.** Assigns `seq` (monotonic per session), `source_monitor`, ISO8601 UTC `t`. Concurrent monitors reconciled before append (lock around seq counter + append; per-monitor lock-free queue feeds the ingester).

`PrivacyGate.swift` is ~300 lines, single chokepoint, auditable. **Logged redaction summary:** the gate emits a daily counter `{secure_input, password_shape, never_log_paste, browser_password_context, url_credential_strip}` visible in Dev Tools, so users can see at a glance whether redaction is firing as expected.

### AnchorRecorder: events → recipes

**Sequence boundary detection.** A candidate sequence starts on the first key/AX-press after a `screen` event or after ≥3s idle. Ends on:
- a new `screen` event with `DirtyDetector` major-change, OR
- ≥2s idle, OR
- app switch.

State captured: `before = (app, window_title, focused_element_ax_path)`, sequence of action events, `after = next screen event's surface descriptor`.

**Normalization for matching.** Two sequences match when:
- Same app
- Same starting AX surface (fingerprint match via existing `ContextMemoryStore` consolidation logic — the one keeper from today's memory store)
- Same step kinds in same order
- Type-step values normalized via **deterministic slot typing** (does not depend on Mercury freshness):
  - `<person.name>` if typed value matches an entry in `active_task.entities` of kind `person`, OR matches a Slack `@handle` / iMessage display name from any recent `app_specific.participants` in the last hour
  - `<file.name>` if matches a known filename in `recent_resources` or `active_task.entities` of kind `file`
  - `<url>` if matches URL regex
  - `<query>` if 1–40 chars, no special chars, focused element looks search-shaped (`AXTextField` with label containing "search")
  - Otherwise keep literal
- Same outcome surface fingerprint

**Promotion.** First match → `candidate` (`seen_count: 1`). Second → `seen_count: 2`. Third → promote to `recipe`. Decay/eviction per L3 schema above.

**Candidate conflict resolution.** If two candidates share the same trigger surface + same step-kind sequence but reach *different* outcome fingerprints, both stay as separate candidates with distinct outcomes. At promotion, the higher-`seen_count` outcome wins the primary slot; the loser is preserved as a sibling `alternate_outcome` on the recipe so the selector can flag ambiguity in the brief. If slot collisions happen (same normalized template matches two slot types — e.g., `<person.name>` and `<query>` both fit), prefer the more specific (person/file/url over query) and record the choice in candidate metadata.

**Naming.** On promotion, one async background Mercury call: *"Given these three observed sequences and their before/after surfaces, return a 3-word verb-phrase name and a `trigger_pattern` (pipe-separated phrasings the user might say to invoke this)."* Returns `name` + `trigger_pattern`. This is the only Mercury call in the collection pipeline besides the task updater.

**Why 3 occurrences:** 2 is too noisy (accidental repeats). 5 takes too long inside an hour-scale session. 3 is the lowest threshold that filters one-offs. Knob exposed in Dev Tools for tuning.

### ActiveTaskUpdater: the continuous synthesis loop

**Trigger conditions** (any of):
- Time since last update ≥90s AND at least one substantive event (not just dwell)
- App switch where the new bundle_id is not in current `active_task.resources`
- Synchronous refresh requested by Selector at long-press AND `active_task.stale_since > 30s` (2s hard deadline, falls back to stale task on timeout)

**Mercury prompt shape:**

```
You maintain a structured Active Task object representing what the user is working on.

CURRENT active_task:
<JSON or null if no active task>

NEW events since last update:
<JSON array of events>

RECENT resources index (URIs touched recently):
<JSON>

Return strictly one of:
  { "update": { ...updated active_task fields... } }
  - OR -
  { "archive_and_start_new": {
       "ended_task": { ...the previous task with an "outcome" string added... },
       "new_task":   { ...complete new active_task object... }
    }
  }

Use archive_and_start_new ONLY when the user has clearly switched domains
(different apps, different resources, different topic). Otherwise update in place.
Be specific. Reference concrete actions, file names, channel names, people.
```

Input ~1–2K tokens, output ~300–500.

**Failure modes:**
- Single failure: keep last good `active_task`, mark `stale_since = now`.
- Two consecutive failures: set `AgentState.shared.contextDegraded = true` so the UI can indicate it. Selector falls back to event-log-only at long-press until recovery.

## 6. App-specific adapters

Protocol:

```swift
protocol AppContextAdapter {
    static var bundleIDs: [String] { get }
    func snapshot() async throws -> [String: Codable]
    func recentResources() async -> [ResourceRef]
}
```

200ms hard deadline on every adapter call. On timeout, L2 emits with `app_specific: null`. Adapters live in `Features/Context/Adapters/`.

### v1 adapters

**BrowserAdapter** (`com.google.Chrome`, `company.thebrowser.Browser` [Arc], `com.apple.Safari`, `com.brave.Browser`):
```jsonc
"app_specific": {
  "active_url": "https://github.com/co/repo/pull/1342",
  "active_title": "PR #1342",
  "tabs": [{"title": "...", "url": "...", "active": true}],
  "profile": "Work"
}
```
Implementation: AppleScript per browser. Each browser exposes a slightly different scripting dictionary; the adapter branches on bundle ID. **URL emission rules** (enforced before any URL leaves the adapter): strip `user:pass@` userinfo, strip query params matching `(token|key|secret|password|auth|api_key|access_token|sig|signature)`. PrivacyGate §5 step 5 is the second line of defense.

**TerminalAdapter** (`com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`):
```jsonc
"app_specific": {
  "cwd": "/Users/arshan/Desktop/tritonhacks2026",
  "git_branch": "main",
  "git_dirty": true,
  "shell": "zsh",
  "recent_commands": ["git status", "npm test"],
  "ssh_host": null
}
```
Implementation: **primary path is OSC 7** — `scripts/install-cwd-reporter.sh` (in scope for v1) prints a 6-line zsh/bash hook into `~/.zshrc` or `~/.bashrc` that writes `cwd` to `~/.cache/agentnotch/term-cwd-<ttyname>` on every prompt (preexec hook). TerminalAdapter reads that file. **Fallback** when the reporter is absent: AppleScript reads the visible buffer and runs a small heuristic (`pwd`-style prompt detection) — explicitly best-effort and acknowledged unreliable under tmux/ssh/Ghostty/custom prompts. If both fail, `cwd: null` and the brief degrades for terminal-bound intents.

**IDEAdapter** (`com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` [Cursor], `com.apple.dt.Xcode`, `dev.zed.Zed`):
```jsonc
"app_specific": {
  "open_file": "Features/Context/ContextCoordinator.swift",
  "language": "swift",
  "cursor_line": 142,
  "selection_range": [140, 155],
  "project_root": "/Users/arshan/Desktop/tritonhacks2026",
  "git_branch": "main",
  "open_tabs": ["ContextCoordinator.swift", "..."]
}
```
Implementation strategy (verify exact files/paths during implementation, fall back to window-title parsing if a strategy fails):
- **VSCode / Cursor:** read recently-opened workspace state from `~/Library/Application Support/<Code|Cursor>/User/globalStorage/` plus the window title, which both apps render as `<filename> — <project> — <app>`.
- **Xcode:** AppleScript scripting dictionary exposes `path of document of front window` and `selected file path`.
- **Zed:** window title parsing only (no scripting available as of writing).
- **Project root + git branch:** derived from the open file path by walking up to nearest `.git` directory.

**For all other apps:** fall back to generic AX + OCR. The shape supports `app_specific: null`.

## 7. Selection pipeline (long-press)

### Flow

```
LongPress end → Whisper transcript ready
  │
  ├─ Parallel sync (≤400ms each):
  │     ▸ L2 snapshot (screenshot + OCR + AX dump + selection + clipboard + adapter.snapshot())
  │     ▸ Read L3 recipes for frontmost app
  │     ▸ Read L4 prefs, L5 active_task + recent_resources + last 10 events
  │
  ├─ If active_task.stale_since > 30s:
  │     ▸ Sync ActiveTaskUpdater call (Mercury, 2s deadline)
  │     ▸ Timeout: proceed with stale task, mark "stale" in selector input
  │
  ├─ Selector call: Mercury 2 (2.5s deadline)
  │     ▸ Input: bundled JSON (see §7.2)
  │     ▸ Output: { intent, brief }
  │
  └─ intent → ContextResolvedIntent (existing struct, fed to harness)
     brief  → contextSummary in buildSystemBlocks (existing un-cached system block)
     ComputerUseHarness.run (untouched)
```

Total budget long-press end → harness start: ~3–3.5s worst case, ~1–1.5s typical.

### Selector input shape

```jsonc
{
  "transcript": "send maya the latest draft",
  "current_screen": { /* full L2 */ },
  "user_prefs": "<L4.explicit>",
  "active_task": { /* L5.active_task */ },
  "recent_events": [/* last 10, full event shape */],
  "recent_resources": [/* L5.recent_resources, capped at top 20 */],
  "recipes_for_active_app": [/* L3 recipes, top 8 ranked by trigger-pattern match + recency */]
}
```

Typical size at hour scale per-app: 5–8K tokens.

### Selector system prompt

```
You are the context selector for an on-screen macOS computer-use agent.

You receive a single JSON payload with: a voice transcript, the current screen
snapshot (AX elements, OCR, selection, clipboard, app-specific data), the user's
preferences, the user's active task and recent activity, and per-app operational
recipes the agent can use.

Your job is two things in one call:

(1) RESOLVE INTENT. Output {verb, target, resolved_target?, entities, confidence}.
    Use active_task, recent_events, recent_resources, and clipboard to resolve
    deictic references — "the draft", "her", "that PR", "this". Be specific. If
    you cannot resolve a reference with high confidence, leave resolved_target
    null and set confidence accordingly.

(2) WRITE THE BRIEF. A markdown briefing for the computer-use agent, ≤600 tokens,
    structured per the template below. The agent has these tools, in preference
    order: open_url > applescript > run_shortcut > ax_query+ax_press >
    menu_shortcut > computer (vision+click). ALWAYS lead with anchors above
    "computer". Never include pixel coordinates — they are not reliable across
    turns.

Brief template (omit any section with nothing concrete to say):

## What the user wants
<one sentence with resolved references>

## You are here
- App, window, focused element (AX path)
- Useful AX paths on this screen (≤5, role+label+ax_path)
- Active selection or recent clipboard if relevant

## How to do it on <app>
<ordered steps, leading with the fastest tool — shortcut, url, menu, applescript>

## What "<deictic>" means
<one entry per pronoun/reference that resolved to a specific resource>

## Watch out for
<only if there's a real, evidenced gotcha>

Rules:
- Coordinate-free. Anchors only.
- Never invent recipes, AX paths, or resources. If you don't have it, say
  "you'll need to look" and let the agent screenshot.
- Stay under 600 tokens. Density over completeness.

Return strictly one JSON object: { "intent": {...}, "brief": "..." }.
```

### Example brief output

For transcript `"send maya the latest draft"`:

```markdown
## What the user wants
Send Maya the Figma file "Onboarding v3" (the file the user has been editing for
the last 40 min) via Slack DM.

## You are here
- App: Slack — channel #design composer
- Focused: AXTextArea[Message #design] (empty)
- Useful AX paths:
  - AXTextArea[Message #design]
  - AXButton[Send]
  - AXButton[Open files]
- Recent clipboard (12s old): URL https://figma.com/file/abc/Onboarding-v3

## How to do it on Slack
You're in a channel, not a DM. Switch to DM with Maya first, then send.

1. **Open DM with Maya** — `cmd+K`, type `maya`, `return`.
   (User has done this 7× in the last hour — high confidence.)
2. **Send the link** — `cmd+v` (URL is already on clipboard from 12s ago), then
   `return`.

If clipboard has changed by the time you act, the URL is also in
recent_resources: `https://figma.com/file/abc/Onboarding-v3`.

## What "the latest draft" means
The Figma file "Onboarding v3". The user last edited "Step 2 — verify email"
4 min ago.

## What "Maya" means
Slack user @maya — appears as a participant in #design and is referenced by name in recent input events.
```

The example "@maya" handle is derivable from `current_screen.app_specific.participants` (which lists `["maya","wyatt","arshan"]`) plus `recent_events` (which contains an `input` event mentioning `@maya`). Claims that go beyond the selector input — e.g. *"last DM 2 hours ago"* — should not appear in the brief unless backed by a corresponding signal (e.g. a Slack DM history field added to BrowserAdapter or a SlackAdapter, which is **not in scope for v1**).

### Harness integration

Three edits in `Features/Agent/`:

1. **`AgentSession.fireAgentTurn`** — drop the existing `resolveIntent()` + `getRecentActivityContext(hint:)` pair. Replace with one `Selector.shared.select(transcript:)` call returning `(intent: ContextResolvedIntent, brief: String)`. Build `ComputerUseHarness.Input` from those.
2. **`ComputerUseHarness.buildSystemBlocks`** — drop the wrapper line *"Local activation context (recent on-screen state — treat as a hint…)"*. The brief is now authoritative and structured; emit it verbatim as the un-cached system block content.
3. **`renderResolvedIntent`** — unchanged. Continues to render `ContextResolvedIntent` as a small block prepended to the brief.

Tools, multi-turn loop, rolling cache marker, tool dispatcher: untouched.

### Multi-turn behavior

Brief is generated **once per long-press**, not per turn. Rationale:
- Mercury per turn ×3 inflates cost + adds 2–3s latency per turn.
- L2 in the brief becomes stale after turn 1, but the agent has `computer.screenshot` and `ax_query` and the system prompt already governs when to use them.
- Intent, resolved references, and recipes don't change inside one task.

Future hook (not v1): if the agent makes 3+ tool calls without detectable progress, harness may call `Selector.shared.refresh(...)` to regenerate.

### Fallback behavior

| Failure | Behavior |
|---|---|
| Mercury timeout (>2.5s) | Local-only brief via `LocalBriefRenderer`: L2 snapshot + recent_resources + top 3 recipes for app. Brief marked `degraded: true`. |
| Mercury malformed JSON | **Salvage attempt first.** Strict schema validation runs on the response. If `intent` is valid and `brief` is missing/invalid → use Mercury's intent + LocalBriefRenderer's brief, mark `partial: true`. If `brief` is valid and `intent` is missing → render intent from L2/clipboard heuristics, mark `partial: true`. If both invalid → full local fallback. Raw response logged (PII-scrubbed) to `AgentRunMetrics` for schema-drift detection. |
| Mercury refusal / empty | Full local fallback. |
| No internet | Local-only path runs directly, skipping Mercury. |
| Stale active_task + stale refresh timeout | Use stale task, prepend `**[active task is N min stale]**` to brief. |
| Brief contains pixel coordinates (validation) | Strip offending lines, ship rest, increment `brief_pixel_coord_strip` metric. |

Local fallback path is ~200 lines of Swift. The agent always receives *some* useful brief.

## 8. Cut plan — file-by-file

### `Features/Context/`

| File | Size | Action | What happens |
|---|---:|:---:|---|
| `ContextCoordinator.swift` | 51K | **R → ~10K** | Thin orchestrator: starts monitors, owns EventLog, exposes Selector entry. |
| `ContextSnapshotStore.swift` | 2.6K | **K** | L2 snapshot history. Unchanged. |
| `ContextDirtyDetector.swift` | 17K | **K** | Gates expensive work. Unchanged. |
| `ContextOCRService.swift` | 3.8K | **K** | L2 OCR. Unchanged. |
| `ContextWindowMetadataReader.swift` | 1.3K | **K** | L2 app/window. Unchanged. |
| `ContextClickMonitor.swift` | 3.3K | **K+** | + EventLog emit (≈20 lines). |
| `ContextAppSwitchMonitor.swift` | 1.1K | **K+** | + EventLog emit. |
| `ContextTextSignalFilter.swift` | 6.7K | **K** | OCR cleaning. Unchanged. |
| `ContextModels.swift` | 23K | **R → ~8K** | New types: `Event`, `ActiveTask`, `Recipe`, `ResourceRef`, `L2Snapshot`, `Brief`. Delete old Gemini-shaped types and `ContextActivationPacket`. |
| `ContextMemoryStore.swift` | 71K | **R → ~12K** | New schema. Keep surface fingerprinting/consolidation logic. |
| `ContextMemoryRenderer.swift` | 33K | **D** | Mercury writes the brief. |
| `ContextActivationBuilder.swift` | 4.7K | **D** | Brief comes from Mercury directly. |
| `ContextIntentResolver.swift` | 21K | **D** | Collapsed into Selector. |
| `ContextGeminiObservationService.swift` | 101K | **D** | Lanes gone. |
| `ContextGeminiObservationModels.swift` | 13K | **D** | Coupled to above. |
| `ContextGeminiCacheManager.swift` | 11K | **D** | No Gemini → no cache. |
| `ContextAIObservationLog.swift` | 10K | **D** | No lanes → no log. |
| `ContextDebugView.swift` | 6.7K | **K+** | Simpler tab layout. |
| `ContextDebugView+Overview.swift` | 7.4K | **K+** | Show event log tail, active_task, selector output, monitor health. |
| `ContextDebugView+Memory.swift` | 44K | **R → ~6K** | New schema → new view. |
| `ContextDebugView+Packet.swift` | 2.4K | **R → ~3K** | "Brief Inspector" — last selector input/output. |
| `ContextDebugView+Intent.swift` | 16K | **R → ~3K** | Last intent + history. |
| `ContextDebugView+Cache.swift` | 7.5K | **D** | No Gemini cache. |
| `ContextDebugView+AI.swift` | 15K | **D** | Lane visualizer. |
| `ContextDebugView+Captures.swift` | 4.5K | **K** | Screenshot review. |
| `ContextDebugView+Dirty.swift` | 10K | **K** | Dirty detector retained. |
| `ContextDebugView+Harness.swift` | 14K | **K** | Harness metrics. |
| `ContextDebugView+Report.swift` | 11K | **R → ~3K** | New metrics: events/min, mercury calls/min, recipe promotion rate. |
| `ContextDebugView+PaneBridge.swift` | 0.6K | **K** | Tiny utility. |
| `ContextDevToolsWindowController.swift` | 3K | **K** | Unchanged. |

### New files in `Features/Context/`

| File | Est size | What |
|---|---:|---|
| `EventLog.swift` | ~4K | Append-only event log, daily rotation. `append`, `tail(n)`. Thread-safe. |
| `KeystrokeMonitor.swift` | ~5K | CGEvent tap, burst-batches into `input` events. |
| `AXObserver.swift` | ~5K | Per-app AX notifications subscribe/unsubscribe. |
| `ClipboardWatcher.swift` | ~3K | `changeCount` poller + paste pairing. |
| `DwellTimer.swift` | ~2K | Per-window accumulator. |
| `PrivacyGate.swift` | ~3K | Single chokepoint for all redaction/suppression. |
| `EventIngester.swift` | ~3K | Normalize → PrivacyGate → EventLog. |
| `AnchorRecorder.swift` | ~6K | Sequence detection + 3-occurrence promotion. |
| `ActiveTaskUpdater.swift` | ~5K | Periodic + on-demand Mercury task synthesis. |
| `Selector.swift` | ~4K | Long-press entry. Mercury call + fallback. |
| `LocalBriefRenderer.swift` | ~3K | Fallback brief generator (no network/Mercury). |
| `MercuryClient.swift` | ~4K | URLSession wrapper hitting **OpenRouter** (`https://openrouter.ai/api/v1/chat/completions`) with `model: "inception/mercury-2-..."` (exact slug confirmed at spike time). OpenAI-compatible request/response shape, so the client is small. Auth via `OPENROUTER_API_KEY` env var. Mirrors `AnthropicClient` shape otherwise. |
| `Adapters/AppContextAdapter.swift` | ~1K | Protocol. |
| `Adapters/BrowserAdapter.swift` | ~5K | Arc/Chrome/Safari/Brave via AppleScript. |
| `Adapters/TerminalAdapter.swift` | ~4K | Terminal/iTerm2 + OSC 7 fallback. |
| `Adapters/IDEAdapter.swift` | ~4K | VSCode/Cursor workspace state + Xcode AppleScript. |
| `Adapters/AdapterRegistry.swift` | ~1K | Bundle ID → adapter lookup. |

### `Features/Agent/`

| File | Size | Action | What happens |
|---|---:|:---:|---|
| `AgentSession.swift` | 5.8K | **R → ~3K** | Drops `resolveIntent` + `getRecentActivityContext(hint:)`; calls Selector once. |
| `IntentRouter.swift` | 7.6K | **inspect & probably D** | Read before deciding; likely folds into Selector or deletes. Flagged TODO. |
| `ComputerUseHarness.swift` | 32K | **K+** | Drop the "Local activation context" wrapper line in `buildSystemBlocks`. |
| `ComputerUseModels.swift` | 12K | **K** | Unchanged. |
| `AnthropicClient.swift` | 6.3K | **K** | Unchanged. |
| `ToolDispatcher.swift` | 24K | **K** | Unchanged. |
| `AXFastPath.swift` | 12K | **K+** | Expose element-walker to `AXObserver` so AX traversal isn't written twice. |
| `AppleScriptBridge.swift` | 4K | **K+** | Reused by adapters; no duplicate AppleScript runner. |
| `VoiceRecordingService.swift` | 7.6K | **K** | Unchanged. |
| `TextToSpeechService.swift` | 4.3K | **K** | Unrelated. Unchanged. |
| `AgentRunMetrics.swift` | 7.4K | **K+** | + `selectorLatencyMs`, `selectorTokens`, `briefDegraded`. |

### `Core/`

| File | Action | What |
|---|:---:|---|
| `AgentInterfaces.swift` | **K+** | Add `Selector.shared` slot. |
| `AgentSettingsStore.swift` | **K+** | + `collectionPaused: Bool`, `neverLogApps: [String]`, `mercuryEnabled: Bool`. |
| `Secrets.swift` | **K+** | + `Secrets.openRouterAPIKey` (env `OPENROUTER_API_KEY`) — Mercury is accessed via OpenRouter, not directly. Drop `geminiAPIKey`. |
| `AgentState.swift` | **K+** | + `lastBriefDegraded: Bool`, `contextDegraded: Bool`. |

### Storage migration

```
~/Library/Application Support/AgentNotch/
  ContextMemory/           # SAME PATH, NEW SCHEMA
    events.jsonl
    active_task.json
    task_archive/
    resources_index.json
    anchors/<bundleID>.json
    prefs.json
    legacy/                # old per-app ContextAppMemory JSONs moved aside
  AgentMetrics/runs.jsonl  # unchanged
  IntentResolverLog.jsonl  # one-time delete on launch
  ContextAI/               # one-time delete on launch
  ContextGeminiCache/      # one-time delete on launch
  ContextDebugArtifacts/   # one-time delete on launch
```

Old per-app `ContextAppMemory` JSONs in `ContextMemory/` are moved to `ContextMemory/legacy/` on first launch of the new build (not deleted, not read). One-line user notice in Dev Tools.

### Rough net delta

- Context module: ~580K → ~120K (≈75% reduction in surface area).
- Agent module: ~120K → ~115K (slight reduction from smaller `AgentSession`).
- New code: ~60K across 16 small focused files (most <5K each).

## 9. Cost & latency

- **Local monitors:** negligible CPU (<1% on M-series). CGEvent tap is the heaviest.
- **ActiveTaskUpdater (Mercury):** ~40 calls/hour × ~2K total tokens during active sessions. ~80K tokens/hour.
- **Recipe naming (Mercury):** O(1) per promoted recipe, near-zero amortized.
- **Selector (Mercury):** ~5–8K input, ~600 output per long-press. 1–3 per active minute when user is engaging the agent.
- **L2 adapter calls:** parallel, 200ms hard deadline each, no user-visible latency.
- **DirtyDetector:** still cuts ~70–80% of click-triggered captures.

End-to-end long-press → harness start: **1–1.5s typical, 3–3.5s worst case** (with stale task refresh).

## 10. Risks & open questions

1. **Mercury 2 via OpenRouter — spike completed Phase 0.** ✓ Resolved. Model slug confirmed (`inception/mercury-2`), JSON-mode 100% reliable, latency p50/p95 = 0.56s/0.78s — well under spec budget. See `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md` for details. **Remaining residual risk:** upstream rate limits / outages — mitigated by §7's local fallback path. **Remaining action item:** propagate slug `inception/mercury-2` (replacing the `inception/mercury-coder` placeholder) into Phase 4 production code defaults.
2. **`IntentRouter.swift`.** Unread during this spec. Could be demo-prompt routing, could overlap with `ContextIntentResolver`. **Action:** first read of phase-2 implementation; fold or delete then.
3. **Input Monitoring TCC permission.** CGEvent taps for keystrokes require this permission on macOS 14+, separate from Accessibility. **Action:** add the permission card to `Features/Onboarding/OnboardingView.swift` follow-up, and `PermissionChecker.swift` needs an `inputMonitoring: Bool` field. Without it, `KeystrokeMonitor` runs in degraded mode (no `input` events; AX still works) but recipe inference loses fidelity.
4. **AppleScript Automation permissions per adapter.** Each adapter triggers one per-app prompt (Arc, Chrome, Safari, Brave, Terminal, iTerm2, Xcode, VSCode, Cursor) on first invocation. App needs `com.apple.security.automation.apple-events` entitlement (already in `AgentNotch.entitlements`). `AppleScriptBridge.swift` allowlist currently does *not* include the new adapter bundle IDs — must be extended in phase 3. Onboarding should pre-warm or explain these — **follow-up in `Features/Onboarding/`**.
5. **Keystroke logging UX.** Settings panel needs a clear toggle, never-log app list editor, status indicator in the notch closed view. Design + implementation in `Features/Notch/AgentSettingsView.swift` and `Features/Notch/ClosedNotchView.swift` — **follow-up, out of scope here**.
6. **Multi-monitor / Spaces.** `ScreenCapture.swift:65` hard-codes display 1; `ComputerUseHarness.swift:487` declares `displayNumber: 1`. L2 now carries `display_id` (§4) so the contract is clear, but the capture path and harness declaration must be updated to honor it. **Action:** in phase 1, update `ScreenCapture` to take a `CGDirectDisplayID` (defaulting to the display containing the frontmost window) and update `ComputerUseHarness.computer` tool declaration to use the same display. Full Spaces support (per-Space frontmost-app tracking) deferred to v2.
7. **Recipe promotion threshold.** Set to 3. May need tuning per app or per user. Exposed as a knob in Dev Tools.
8. **Multi-step recipe safety.** Recipes can be 2–5 steps. If the focused app/element changes mid-sequence (user clicks away, app quits, modal appears), naively replaying keystrokes can hit the wrong target. **Action:** before each step, `ToolDispatcher` (or a thin wrapper called by the brief renderer when it suggests a recipe) verifies the current focused app's bundle_id matches the recipe's `app` and aborts with a "context drifted — please screenshot" instruction in tool output. v1 ships this guard but does not yet add postcondition surface-fingerprint checks (deferred).
9. **`copy_paste` pairing latency.** Pairing relies on observing a paste event in a different app's input within ~5s of a copy. Longer gaps → missed pair. Acceptable for v1; tunable knob in Dev Tools.
10. **Adapter timeouts.** 200ms is tight. Implementation must measure p95 per adapter; if any routinely exceeds it, L2 emits `app_specific: null` for that app and the brief loses signal there.

## 11. Acceptance criteria

Each criterion below names a concrete fixture, scorer, or measurement procedure. "Coherent," "usable," and "concrete" are defined operationally.

**Latency** (measured on an M-series MacBook with active Wi-Fi, 100 long-press invocations across the scenario fixtures):
- [ ] p50 long-press end → harness first tool call ≤ 1.5s
- [ ] p95 long-press end → harness first tool call ≤ 3.5s
- [ ] When Mercury is reachable, Selector returns within 2.5s on ≥90 of 100 runs

**Brief quality** (three scripted fixture scenarios with golden inputs):
- [ ] Scenario A — *"send maya the latest draft"* with Slack frontmost, Figma URL on clipboard, Maya in `active_task.entities`: brief names `cmd+K → type "maya" → return` as step 1 with no pixel coordinates and resolves "maya" to a person entity in the intent JSON.
- [ ] Scenario B — *"open the PR"* with Arc frontmost, PR URL in `recent_resources`: brief leads with `open_url https://github.com/.../pull/N` (no AX hunt required); intent.resolved_target points to that URL.
- [ ] Scenario C — *"run the tests"* with iTerm frontmost, TerminalAdapter reporting `cwd=/Users/.../tritonhacks2026` and `git_branch=main`, plus an L3 recipe `{shell_cmd: "npm test"}`: brief includes `shell_cmd: npm test` scoped to that cwd; no coordinate hunting.

**Baseline established Phase 0** (recorded in `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`):
- Mercury 2 model slug confirmed: `inception/mercury-2` (the only Mercury candidate currently on OpenRouter).
- JSON-mode reliability: 5/5 valid envelopes against strict-shape system prompt → Selector can rely on `response_format: json_object`.
- Latency at 1755-token prompt / 193-token completion (n=10): p50 = 0.56s, p95 = 0.78s — ~3× under the spec budget (1.5s/2.5s).
- Phase 4 must re-measure with the full production payload (~5K tokens) and confirm baselines hold within 2× of Phase 0 numbers; if not, treat as a regression.

**Memory shape**:
- [ ] `grep` across `ContextMemory/**.json{,l}` for keys matching `bbox|coord|pixel|x:|y:|left|top` returns zero hits inside recipe step values or anchor fields.
- [ ] All events in `events.jsonl` carry the base envelope fields from §4: `t, seq, kind, source_monitor, bundle_id, pid, redacted, redaction_reason`.

**Privacy**:
- [ ] With 1Password frontmost for 60s of typing + one copy → paste-into-Slack flow: event log between `app_switch → 1Password` and `app_switch ← 1Password` contains zero entries; subsequent paste-into-Slack `input` event has `text: "<redacted>"` and `redaction_reason: "never_log_paste"`.
- [ ] With focus on a Safari password field (`/login` URL), 10 keystrokes produce `input` events with `text: "<redacted>"` and `redaction_reason: "browser_password_context"`.
- [ ] URL `https://x.com/api/foo?token=ABC123&keep=ok` emitted by BrowserAdapter is logged as `https://x.com/api/foo?keep=ok`.

**Continuous synthesis**:
- [ ] After replaying a 30-event fixture (alternating Figma + Slack + Linear activity over 5 minutes), `active_task.narrative` mentions at least 2 of the 3 apps and references a concrete entity (file/channel/person).
- [ ] When a 4th app (Cursor) is introduced with a different domain (TypeScript file editing), `ActiveTaskUpdater` archives the previous task and starts a new one within 90s.

**Anchor learning**:
- [ ] Replaying `cmd+K → type "alice" → return → type "hi" → return` in Slack three times in a 10-min window promotes a recipe with `name` and `trigger_pattern` populated by Mercury naming call; recipe appears in subsequent selector inputs for Slack.

**Fallback**:
- [ ] With `MERCURY_API_KEY` unset, long-press still completes and produces a brief that includes app/window, ≤3 recipes, and recent_resources; brief is marked `degraded: true` in metrics.
- [ ] When Mercury returns `{intent: <valid>, brief: <truncated>}`, system uses Mercury's intent + LocalBriefRenderer's brief; metric `selector_partial_success` increments.

**Size budget**:
- [ ] Total `Features/Context/` size after delete + new file additions: ≤ 40% of pre-redesign size (target: ~120K from ~580K).

**Stretch (nice to have, not blocking)**:
- [ ] Multi-monitor: with frontmost window on display 2, `L2.display_id == 2` and `ScreenCapture` returns display 2's pixels.

## 12. Follow-ups (out of scope for this spec)

- Notch UI for collection toggle, never-log list editor, degraded-context indicator.
- Onboarding pre-warm for adapter Automation permissions and Input Monitoring TCC.
- Long-horizon memory (>1 day): rollup, compaction, decay policies.
- Per-app preference inference into L4.`per_app`.
- Mid-turn `Selector.refresh()` hook when the agent appears stuck.
- Postcondition surface-fingerprint checks for multi-step recipes (v1 ships precondition app-bundle guard only).
- Vector / embedding-based selection if Mercury context budget becomes a constraint at multi-day horizons.
- Slack/iMessage adapter (would unlock claims like "last DM N min ago" in briefs).
- Full Spaces support (per-Space frontmost tracking).

## 13. Offline benchmark & evaluation harness

**Requirement:** every Mercury prompt (Selector, ActiveTaskUpdater, Recipe Naming) must be tested against a fixture suite with mock inputs and graded outputs **before being wired into the live path**. This is a hard precondition for shipping each phase that introduces a Mercury role.

### Structure

```
tests/eval/
  fixtures/
    selector/
      scenario-A-slack-dm-with-person/
        input.json              # full selector input payload
        expected_intent.json    # ground-truth resolved intent
        expected_brief_must_contain.json   # ["cmd+K", "maya", "return", "figma.com"]
        expected_brief_must_not_contain.json  # ["bbox", "pixel", "[0-9]{3}, [0-9]{3}"]
        notes.md
      scenario-B-arc-open-PR/
        ...
      scenario-C-iterm-run-tests/
        ...
    active_task_updater/
      task-from-cold-start/         # empty active_task + 8 events → new active_task
      task-continuation/            # existing task + 5 new in-domain events → updated
      task-archive-and-new/         # existing task + 5 out-of-domain events → archive + new
    recipe_naming/
      slack-cmd-k-dm/               # 3 sequences → expected name "open DM with person"
      browser-cmd-l-url/            # 3 sequences → expected name "navigate to URL"
  goldens/
    selector/<scenario>/golden_output.json   # snapshot of a known-good run, updated manually
  harness/
    EvalHarness.swift               # loads fixtures, runs prompts, computes scores
    Scorers.swift                   # the actual scorers (see below)
    OfflineRunner.swift             # CLI entry point, no network mode + mock-LLM mode
```

### Scorers (deterministic, no LLM-as-judge for v1)

| Scorer | What it checks |
|---|---|
| `must_contain` | All strings in `expected_brief_must_contain` appear in the generated brief (case-insensitive) |
| `must_not_contain` | None of the strings/regexes in `expected_brief_must_not_contain` appear |
| `intent_match` | Intent JSON matches expected on: `verb` (exact), `resolved_target` (substring), `entities[].resolved_to` (set match) |
| `pixel_coord_grep` | Regex scan of brief for `\b\d{2,4}\s*,\s*\d{2,4}\b` — fails on any hit |
| `token_budget` | Brief ≤ 600 tokens (tokenized via a Swift tiktoken port or character heuristic for v1) |
| `schema_valid` | Strict JSON schema validation of the response |
| `latency_p95` | Aggregated across the run, asserted against §11 targets |

### Two modes

- **Mock-LLM mode.** `MercuryClient` swapped for a fixture-replay client that returns pre-recorded responses keyed by input hash. Lets the rest of the pipeline (Selector input assembly, brief parsing, harness integration) be tested without network calls. Used in CI and during the Phase 1–3 buildout.
- **Live-Mercury mode.** Real OpenRouter calls against fixture inputs, with results stored to `tests/eval/results/<run-id>/`. Run manually before each phase rollout and on prompt changes. Compares against `goldens/` to detect regressions; new responses appended to a review queue if they differ meaningfully (Levenshtein/cosine on brief text).

### Acceptance gate

A Mercury role does not go live until:
1. All `must_contain` / `must_not_contain` / `intent_match` / `pixel_coord_grep` / `schema_valid` scorers pass on all fixtures.
2. p95 latency in `Live-Mercury` mode meets §11 targets.
3. Mock-LLM mode passes in CI on the integration tests that consume the role's output.

### When to update fixtures

- **Add a fixture** when a new failure mode is observed in dev or with real users — capture the input + the desired brief.
- **Update goldens** only after manual review of why the output drifted (prompt change, model change, data shape change). Never auto-update.
- **Retire a fixture** when its scenario is covered by another and the scorers are redundant.

## 14. Suggested phase breakdown for the implementation plan

Decomposition is the writing-plans skill's job, but as guidance to whoever picks that up:

**Phase 0 — Mercury spike + eval harness foundation.** Throwaway `MercuryClient.swift` against OpenRouter validates model slug, JSON-mode reliability, latency, cost. Findings drop into §9 and §11. **Also in phase 0:** scaffold `tests/eval/` per §13 with the EvalHarness, Scorers, and OfflineRunner. Write the first 3 selector fixtures (Slack DM, Arc URL, iTerm tests). Record initial Mock-LLM goldens from manual ideal-output construction.

**Phase 1 — Foundation: events + privacy + storage.** New `ContextModels.swift`, `EventLog.swift`, `EventIngester.swift`, `PrivacyGate.swift`, `KeystrokeMonitor.swift`, `AXObserver.swift`, `ClipboardWatcher.swift`, `DwellTimer.swift`. Rewrite `ContextMemoryStore.swift` schema. Onboarding card for Input Monitoring TCC. **Verifiable independently** via PrivacyGate fixtures from §11.

**Phase 2 — One adapter end-to-end.** `BrowserAdapter` (highest leverage) + `AdapterRegistry` + `AppContextAdapter` protocol. Plumbs `app_specific` into L2 and `recent_resources` into L5. Verifies the adapter abstraction.

**Phase 3 — Synthesis: anchors + active_task.** `AnchorRecorder.swift`, `ActiveTaskUpdater.swift`. Now memory is continuous. Add ActiveTaskUpdater + Recipe Naming fixtures to `tests/eval/`; both Mercury roles must pass scorers in Mock-LLM mode and Live-Mercury mode before going live. Local-only at this point (no Selector yet).

**Phase 4 — Selection.** `Selector.swift`, `LocalBriefRenderer.swift`, plus `AgentSession.swift` rewrite and the small `ComputerUseHarness` system-block edit. Selector prompt must pass §13 fixture suite in Live-Mercury mode before this phase flips the harness path. **First end-to-end demo possible at end of phase 4.**

**Phase 5 — Remaining adapters + cuts.** `TerminalAdapter` (with OSC 7 script), `IDEAdapter`. Delete the Gemini service, intent resolver, memory renderer, activation builder, debug+AI/Cache views. Final size budget check from §11.

**Phase 6 — Dev Tools update.** Rewrite Memory, Packet, Intent, Report tabs. Add redaction counter view. Polish.

Phases 1 and 2 are independently shippable (they don't change agent behavior — just collect data). Phase 4 is the user-visible flip. Phase 5 is the cleanup. Phase 6 is operability.
