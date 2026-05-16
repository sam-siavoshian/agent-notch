# UI Memory Assessment

## Current Read

This sandbox is a useful controlled experiment, not yet a full UI-learning brain.

What works:

- Synthetic screenshots are deterministic and safe to commit.
- Gemini can extract useful UI facts from screenshots when prompted into a structured schema.
- The memory artifact captures surfaces, landmarks, affordances, transitions, a task recipe, negative memory, and uncertainty.
- A repeated-task demo shows the intended product loop: first pass explores, second pass uses a learned route.
- Latency is now measured separately from activation, reinforcing that VLM work belongs in background ingestion.

What was too optimistic:

- Earlier tests mostly proved the fixture happy path, not robust live UI understanding.
- Live Gemini outputs varied for the same surface (`overview`, `main-dashboard`, `main-window`, `deployments_dashboard`), so exact model surface IDs cannot be trusted.
- The replay was partly scripted: second-run actions were supplied by the scenario, and metrics treated memory as helpful because it was the second run.
- Transitions were learned from action labels, not inferred from before/after screenshots.
- The current memory is a flat document. It is readable, but it has no lifecycle for stale facts beyond uncertainty notes.

## Fixes Added

- Canonical surface normalization maps unstable model surface IDs back to stable surface keys such as `overview`, `deployments`, `filters-open`, and `failed-detail`.
- Transition learning now uses canonical surface matching so evidence survives live model naming drift.
- Repeated-task metrics now count memory help only when recognition recommends the action that was taken.
- Fixture observation tests now cover every synthetic screenshot and assert required UI facts, not just valid JSON.
- Live Gemini tests are explicit, blinded, uncached, and skipped unless `ARSHAN_LIVE_GEMINI=1` is set.
- Cached observations are validated before reuse.
- Stored observations scrub absolute screenshot paths for portable committed artifacts.
- `npm run assess:memory` scores the committed memory artifact and explains missing pieces.

## What It Still Does Not Prove

- It does not yet infer a transition from visual before/after deltas plus a click location.
- It does not yet maintain a durable app memory with `lastSeen`, `supersededBy`, or contradicted stale facts.
- It does not yet test real screenshots from messy production apps and websites.
- It does not yet measure whether a live computer-use agent completes real UI tasks faster.

## Next Layer

1. Add visual transition observations: before screenshot, click/action, after screenshot, changed regions, inferred destination surface.
2. Add memory lifecycle metadata: `lastSeen`, `confidence`, `status`, `contradictedBy`, and `supersededBy`.
3. Build a blinded live eval over all synthetic screenshots with repeated Gemini trials and variance reporting.
4. Add one real-but-fake complex app fixture with modals, hidden menus, disabled controls, and ambiguous labels.
5. Replace scripted second-run transitions with a small planner that chooses from visible affordances and learned memory.
