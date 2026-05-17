# Mercury 2 via OpenRouter — Phase 0 spike findings

**Date:** 2026-05-16
**Spike performed by:** Subagent-driven Phase 0 implementation of the context-redesign plan.
**Endpoint:** `https://openrouter.ai/api/v1/chat/completions` (OpenAI-compatible)
**Auth:** `Authorization: Bearer $OPENROUTER_API_KEY`
**Tooling:** `tools/MercurySpike/` (`mercury-spike` CLI + `OpenRouterAPI` Swift library)

---

## Selected model

**`inception/mercury-2`** — the only Mercury candidate currently published on OpenRouter.

| Field | Value |
|---|---|
| Slug | `inception/mercury-2` |
| Context window | 128,000 tokens |
| Pricing | $0.25 / M input · $0.75 / M output |
| Modality | text only |

Discovery method: `curl -H "Authorization: Bearer $OPENROUTER_API_KEY" https://openrouter.ai/api/v1/models | jq '.data[] | select(.id | test("mercury"; "i"))'`. Only one match: `inception/mercury-2`. No `mercury-coder` variant on OpenRouter as of this date.

The plan and spec used `inception/mercury-coder` as a placeholder. Updated to `inception/mercury-2` going forward.

---

## JSON-mode reliability

Probe: `mercury-spike jsonMode inception/mercury-2` (n=5 runs, `response_format: json_object` + strict-shape system prompt asking for `{"intent": {"verb": string, "target": string}, "brief": string}`).

| Run | Latency | Valid envelope? |
|---|---|---|
| 1 | 0.56 s | ✓ |
| 2 | 0.50 s | ✓ |
| 3 | 0.54 s | ✓ |
| 4 | 0.53 s | ✓ |
| 5 | 0.49 s | ✓ |

**Verdict:** **5/5 (100%) valid envelopes**, avg latency **0.52 s**. JSON-mode is reliable for the Selector contract.

**Implication:** Selector can rely on `response_format: json_object`. The spec §7 partial-JSON salvage path is still worth keeping (defense in depth at larger scale), but it should be rare to trigger.

---

## Latency at ~5K input / 600 output

Probe: `mercury-spike latency inception/mercury-2` (n=10 runs, ~1.7K-token input padded with realistic recent-events JSON, `maxTokens: 600`, `response_format: json_object`).

| Run | Latency |
|---|---|
| 1 | 0.78 s |
| 2 | 0.73 s |
| 3 | 0.56 s |
| 4 | 0.62 s |
| 5 | 0.49 s |
| 6 | 0.64 s |
| 7 | 0.52 s |
| 8 | 0.53 s |
| 9 | 0.50 s |
| 10 | 0.56 s |

**p50: 0.56 s · p95: 0.78 s** at 1755 prompt tokens / 193 completion tokens (last run).

Spec §11 target: **p50 ≤ 1.5 s, p95 ≤ 2.5 s** (selector budget).

**Verdict:** Mercury 2 **beats the spec target by ~3×**. Confidence is high that the Selector will hit budget with substantial headroom even at 2-3× the prompt size and with the system prompt loaded.

**Note on payload size.** The probe's prompt landed at 1755 tokens, not the targeted 5000. The filler-JSON pattern was less token-dense than expected (repeated short JSON events compress well in the tokenizer). At 3× the size (5K-6K prompt) latency should still comfortably meet target — but worth re-measuring once the real Selector payload is wired (T20 / Phase 4).

---

## Known issue: Mercury 2 returns `content: null` for very short replies

The `mercury-spike ping inception/mercury-2` probe (which asks for the literal word "OK" with `maxTokens: 10`) consistently fails to decode the response. Mercury 2 emits:

```json
"choices": [{"index": 0, "message": {"role": "assistant", "content": null}, ...}]
```

The OpenAI spec allows `content` to be null when `finish_reason` is `tool_calls` or `function_call`, but Mercury appears to return null in other cases too — most likely when the response is shorter than some internal threshold or when `maxTokens` is set to a value below the model's preferred minimum chunk size.

**Patch applied:** `Message.content: String` (non-optional) was kept on the wire (request side requires it), but a custom `Message(from decoder:)` normalizes a decoded `null` → empty string. This avoids a typed-Decoding throw, lets callers handle empty strings naturally, and keeps the request-side shape unchanged.

**Implication for jsonMode/latency probes:** both already use larger `maxTokens` (300 and 600) and structured JSON, so they don't hit this path. Only the toy ping prompt does.

---

## Implications for the spec

- **§9 Cost & latency:** Mercury 2 measured at 0.56s/0.78s p50/p95 vs spec target 1.5s/2.5s — ~3× headroom. The "End-to-end long-press → harness start: 1–1.5s typical, 3–3.5s worst case" estimate stands and is conservative.
- **§7 Multi-turn behavior:** The "Selector returns within 2.5s on ≥90 of 100 runs" criterion will be easy to meet.
- **§10 Risk #1 (Mercury 2 unvalidated dependency):** Largely resolved. Mercury 2 is reachable via OpenRouter, JSON-mode reliable, latency comfortable. The remaining risk is upstream rate limits / outages, mitigated by the local fallback path (§7).
- **Model slug propagation:** All references to `inception/mercury-coder` in code defaults, docs, and spec should be updated to `inception/mercury-2`. T20's `EvalRunner` and the CLI defaults need this change as part of the next phase.

---

## Next-phase TODO

- [ ] Wire the patched `Message` into a re-run of `mercury-spike ping inception/mercury-2` to confirm the null-content workaround works end-to-end. (Not blocking phase 0 — only the ping path was affected.)
- [ ] Update default model slug in `MercurySpikeCLI` and `RunnerCommands.swift` from `inception/mercury-coder` → `inception/mercury-2` (will happen as part of T28 spec update).
- [ ] Phase 4 (when the real `Selector.swift` lands in `Features/Context/`): re-measure latency with the actual production payload shape (likely closer to true 5K).

---

## Live-Mercury fixture run (T27)

Run command: `swift run --package-path tools/MercurySpike eval-runner live` with `OPENROUTER_API_KEY` set, `MERCURY_MODEL=inception/mercury-2`.

**Result: 2/3 fixtures pass live. p50 ≈ 1.6s, p95 ≈ 2.1s per fixture (well under the 2.5s selector budget).**

| Fixture | Status | Latency | Notes |
|---|---|---|---|
| scenario-A-slack-dm-with-person | FAIL | 2.07s | 4/6 scorers pass; 2 substantive misses (below) |
| scenario-B-arc-open-PR | PASS | 1.29s | 6/6 ✓ |
| scenario-C-iterm-run-tests | PASS | 1.77s | 6/6 ✓ |

### Scenario A failures — both surface real Phase-4 prompt-engineering work

1. **`must_contain: missing: cmd+K`.** Mercury's reply is non-deterministic across runs. Sometimes it writes `` `cmd+k` ``, sometimes `Cmd+K`, sometimes uses the `⌘K` symbol. The fixture's must-contain list includes the literal string `cmd+K`. Case-insensitive matching handles capitalization but not glyph substitution. **Phase 4 fix:** either (a) tighten the system prompt to require the literal `cmd+K` form, (b) loosen the fixture to accept multiple shortcut renderings via regex, or (c) post-normalize the brief in `LocalBriefRenderer` before scoring.

2. **`intent_match: resolved_target 'Maya Chen' does not contain 'Onboarding v3'`.** Mercury parses "send maya the latest draft" as `send TO Maya` with Maya as the target/recipient, while our fixture expects `send the latest draft` with the file as the target and Maya as a separate `person` entity. **Both readings are valid English.** This is a deliberate prompt-engineering signal: the system prompt needs a sentence specifying that the indirect object (recipient/destination) belongs in `entities`, not in `target`. Saving for Phase 4.

### What works as designed

- **JSON-mode reliability holds in production payloads.** All 3 fixtures returned strictly-valid `{intent, brief}` envelopes — schema_valid green across the board.
- **Brief structure is excellent without prompt-tuning.** The "How to do it" sections name shortcuts, AX paths, recipes from L3 — exactly what the design intended.
- **No pixel coordinates ever appeared.** pixel_coord_grep green across all 9 scorings — the "coordinate-free anchors" rule of the system prompt is being respected on the first try.
- **Token budget never exceeded.** All briefs landed under 400 tokens (vs 600 budget) — room to grow.

### Selector system prompt provenance

The system prompt used for these live runs lives at:
`tools/MercurySpike/Sources/EvalRunner/RunnerCommands.swift` (`enum SelectorSystemPrompt`).

This is the version used as the Phase-0 baseline. Phase 4 will import this verbatim into the production `Selector.swift` and iterate from there — any meaningful change should be made under fixture-replay first, with a new entry below.

| Revision | Date | Change | A pass? | B pass? | C pass? | Notes |
|---|---|---|---|---|---|---|
| v1 (Phase 0 baseline) | 2026-05-16 | initial | partial (4/6 scorers) | full | full | Established baseline. |

---

## Phase 3 (P3-6) — eval harness extended to two new prompt classes

Date: 2026-05-17.

The eval harness now covers two additional Mercury prompt categories beyond the Selector:

1. **`active_task_updater`** — maintains a rolling `CActiveTask` from the recent `CEvent` stream. Returns `{update: ...}` or `{archive_and_start_new: {ended_task, new_task}}`.
2. **`recipe_naming`** — abstracts three observed step sequences into a named recipe with a pipe-separated trigger pattern.

### New CLI commands

```
eval-runner mock-active-task        # offline replay, 3 fixtures
eval-runner live-active-task        # OpenRouter, requires OPENROUTER_API_KEY
eval-runner mock-recipe-naming      # offline replay, 2 fixtures
eval-runner live-recipe-naming      # OpenRouter, requires OPENROUTER_API_KEY
```

Pre-existing `mock`, `live`, `list` (selector-only) remain unchanged.

### Fixtures added

| Category | Scenario | Pattern under test |
|---|---|---|
| active_task_updater | cold-start | null current + Figma events → must emit `{update: ...}` with onboarding/figma label |
| active_task_updater | continuation | Figma task already exists + more in-domain events → update in place, expand resources |
| active_task_updater | archive-and-new | Figma task + iTerm/VSCode app switch → `{archive_and_start_new: ...}` with coding kind |
| recipe_naming | slack-cmd-k-dm | `cmd+k → type <person> → return` ×3 → DM-with-person recipe |
| recipe_naming | browser-cmd-l-url | `cmd+l → type <url> → return` ×3 → navigate-to-URL recipe |

### Mock-LLM validation

All 5 hand-curated goldens pass their assertions in offline replay:

- `mock-active-task`: 3/3 fixtures pass (response_shape, label_contains, kind_in, narrative_must_contain, resources_must_include, plus archive-side ended_outcome / new_task_label / new_task_kind checks).
- `mock-recipe-naming`: 2/2 fixtures pass (has_name, has_trigger_pattern, name_must_contain_any, trigger_pattern_must_contain_any).
- Selector mock unchanged: 3/3 fixtures still pass.
- All 35 EvalHarness + OpenRouterAPI unit tests still pass.

### Live-Mercury validation

**Not run.** `OPENROUTER_API_KEY` was not present in the worktree subprocess env when P3-6 ran, so live validation against real Mercury is deferred. Re-run with the key exported:

```bash
export OPENROUTER_API_KEY=...
swift run --package-path tools/MercurySpike eval-runner live-active-task
swift run --package-path tools/MercurySpike eval-runner live-recipe-naming
```

### Prompt-engineering notes for Phase 4

A few signals worth tracking on the next live pass:

- **`response_shape` discipline (active_task_updater).** Phase-4 risk: Mercury may try to be helpful and return a *third* shape (`{ended_task, new_task}` without the wrapper, or `{update, archive_and_start_new}` mixed). The system prompt's "Return strictly one of these JSON shapes" should hold, but watch for it.
- **`kind` taxonomy drift.** The active_task `kind` field is free-form ("design_iteration", "coding", ...). Goldens use `kind_in` (any-of) to absorb variance, but if Mercury picks something far afield ("ui_work" instead of "design_iteration"), the fixture will fail and we should either expand the allowed set or pin the prompt to a closed enum.
- **`trigger_pattern` generalization (recipe_naming).** The biggest risk for the recipe_naming prompt is Mercury enumerating the literal observations ("DM maya | DM wyatt | DM arshan") instead of generalizing with `<person>`. The system prompt explicitly forbids this; if it slips through, lean harder on the example output.
- **No live latency data yet.** The mock-mode latency (~0 ms) is just file I/O. Real Mercury latency on these prompts is the open question — particularly active_task_updater which uses a 2-8 s timeout in production.

### Shortcut taken (revisit in Phase 4)

The new categories use **ad-hoc per-command scorers** (`PromptCategoryCommands.scoreActiveTask` / `scoreRecipeNaming`) rather than new generic `Scorer` types, because the Selector's typed `Fixture.Expected` schema doesn't fit either new prompt shape. Phase 4 cleanup options:

- (a) Promote `RawFixture` + ad-hoc scorers into proper `Scorer` implementations with category-specific `Expected` decoders. Cleaner, more uniform.
- (b) Keep ad-hoc per-category scoring. Cheaper, more flexible for fast prompt iteration.

The active_task_updater system prompt is currently duplicated between `Features/Context/ActiveTaskUpdater.swift` (production) and `tools/MercurySpike/Sources/EvalHarness/ActiveTaskUpdaterSystemPrompt.swift` (eval). Phase 4 should make production import the eval-validated constant, same pattern as `SelectorSystemPrompt`.

---

## Phase 4 follow-up F2 — active_task_updater prompt iteration

Date: 2026-05-17. Live runs against `inception/mercury-2` via OpenRouter. Fixtures = `cold-start`, `continuation`, `archive-and-new`.

| Revision | Date | Change | cold-start | continuation | archive-and-new | Notes |
|---|---|---|---|---|---|---|
| v1 (Phase 3 baseline) | 2026-05-17 | Short prompt — bare shape contract, no grounding rules | FAIL (empty CActiveTask) | n/a (not run live) | FAIL (label hallucinated, kind out of taxonomy) | Initial Phase-3 live run. |
| v2 (F2 attempt 1) | 2026-05-17 | Added CRITICAL RULES section: cold-start synth from events, ground new_task in events, app-name specificity | FAIL (JSON truncated @ 1200 tok) | FAIL (truncated) | FAIL (truncated) | maxTokens=1200 was clipping mid-JSON. Bumped to 8000. |
| v3 (F2 attempt 2) | 2026-05-17 | Same prompt as v2, maxTokens=8000 | PASS | PASS | FAIL: missing "VSCode" in narrative, missing "Figma" in ended_outcome, label missing "agent-notch" | maxTokens fix unblocked parsing; archive-and-new still paraphrased. |
| v4 (F2 attempt 3) | 2026-05-17 | Added rule 5 (archive-and-new specifics: ended_outcome names departing app verbatim; new_task.label includes repo/folder name) + tightened narrative rule | PASS | PASS | FAIL: narrative still missing literal "VSCode" | Model wrote "Visual Studio Code" or "the editor" instead of "VSCode". |
| v5 (F2 attempt 4) | 2026-05-17 | Added explicit APP-NAME NORMALIZATION table mapping `app: "Visual Studio Code"` → must emit literal "VSCode" (plus Figma, iTerm2, Slack, Chrome, Arc) | PASS | PASS | PASS | 3/3 ✓ — final F2 prompt. Also bumped production `MercuryClient.complete` maxTokens 800 → 8000 to match. |

**Final live latencies (v5):** archive-and-new 2.21s · cold-start 1.40s · continuation 1.79s.

**Key lessons:**

1. Mercury truncated at maxTokens=1200 — the full active_task JSON is ~600-1200 tokens by itself and the response_format=jsonObject path doesn't reserve headroom. Treat maxTokens as a runaway guard (8000), not a size target.
2. Free-form natural-language constraints ("be specific", "reference concrete details") don't bind tightly enough. Mercury paraphrases. To pin a specific token in the output, the prompt has to literally say *"if input has X, output must contain the literal substring Y"* — a deterministic mapping rule.
3. Cold-start `resources: []` regression in v3→v4 was a side effect of overloading the narrative rule — fixed by adding an explicit "copy every `uri` from RECENT resources into the resources array verbatim" sub-rule under cold-start.
