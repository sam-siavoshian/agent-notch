# UI/UX Learning System Blueprint

## Goal

Make the computer-use agent faster because it is not rediscovering the UI from scratch on every long press.

The agent should receive:

- current visual ground truth
- recent activity memory
- learned UI/UX memory for the current app
- known routes, affordances, no-ops, and stale notes

This is not dashboard-specific. Dashboards are only the first controlled fixture. The same memory model should apply to native apps, browser apps, editors, documents, settings screens, file pickers, chat tools, design tools, and internal tools.

The hot path should not wait on a fresh live VLM call unless the cached/background memory is missing or clearly stale.

## System Loop

```txt
screen stream
  -> capture gating
  -> OCR + screenshot observation
  -> transition inference
  -> app memory update
  -> activation bundle
  -> computer-use agent
  -> performance metrics
```

## 1. Capture Layer

Inputs:

- ScreenCaptureKit frames
- dirty rects
- click / gesture / keyboard event metadata
- frontmost app and window title
- cursor position and dwell

Output:

```txt
FrameEvent {
  id
  timestamp
  app
  windowTitle
  screenshotPath
  dirtyRects
  trigger
  cursorPosition
}
```

Rules:

- Keep full context for the focused window, not tiny dirty-rect crops.
- Use dirty rects for gating and localization.
- Preserve small/window-crop screenshots; only compress large captures.
- Store real user screenshots locally only, never committed.

## 2. Observation Layer

Inputs:

- screenshot
- OCR text/layout
- frame metadata

Output:

```txt
Observation {
  app
  surfaceId
  canonicalSurfaceKey
  surfaceLabel
  visibleControls
  visibleEntities
  landmarks
  likelyAffordances
  uncertainty
  confidence
}
```

Important lesson:

The model's own `surfaceId` is not stable enough to use directly. Always derive a canonical surface key from visual evidence.

## 3. Transition Learning

This is the next missing core layer.

Inputs:

```txt
beforeObservation
actionEvent
afterObservation
changedRegions
```

Output:

```txt
TransitionObservation {
  fromSurface
  action
  targetRegion
  toSurface
  outcome: success | no-op | uncertain
  learnedAffordance
  confidence
  evidenceIds
}
```

Fixture examples:

- `overview -- click Deployments in left nav --> deployments`
- `overview -- click blank center area --> overview` as a no-op
- `deployments -- click Status filter --> filters-open`
- `filters-open -- select Failed --> failed-detail`

This is the first layer that turns "screen understanding" into "the agent knows how to use the app."

## 4. App Memory

One memory file per app or web product.

The memory needs to be action-oriented, not just descriptive:

- app profile
- surfaces seen
- landmarks
- affordances
- transitions
- task recipes
- negative memory
- stale / uncertain notes

Good memory:

```txt
Open Deployments from left navigation.
Status filter narrows deployment table.
Selecting Failed leads toward the failed deployment detail.
Blank center overview card is not actionable.
```

Bad memory:

```txt
The page has a blue sidebar and some cards.
```

## 5. Activation Bundle

On long press, the computer-use agent should get a compact packet:

```txt
ActivationBundle {
  userGoal
  liveContext
  recentActivity
  currentSurfaceMemory
  relevantTransitions
  relevantTaskRecipes
  negativeMemory
  staleOrUncertainNotes
  retrievalTools
}
```

The bundle should be small enough to read immediately and specific enough to guide the first action.

Default preload:

- current screenshot / current observation
- current app memory
- current surface facts
- adjacent transitions
- task recipes matching the user goal
- negative memory for the current surface
- uncertainty/stale notes

Lazy retrieval:

- other app memories
- older screenshots
- raw observation history
- full activity log

## 6. Computer-Use Performance Testing

The key metric is not "did Gemini describe the screenshot." The key metric is:

```txt
Did UI memory reduce the computer-use agent's search/exploration cost?
```

Measure:

- time to first useful action
- actions per task
- screenshots per task
- exploratory actions per task
- repeated no-op rate
- memory hit rate
- memory helped rate
- memory misled rate
- task success rate

Test modes:

1. **No memory baseline**
   Agent receives only current screenshot / observation.

2. **Memory preload**
   Agent receives activation bundle.

3. **Memory + retrieval**
   Agent receives activation bundle and can query app memory / history.

The product wins when mode 2 or 3 reduces first-action latency and exploratory actions without increasing misled actions.

## Immediate Build Order

1. Activation bundle contract.
2. Transition inference from before/action/after.
3. Memory-driven planner that chooses next action from the bundle.
4. Synthetic computer-use benchmark: no-memory vs memory.
5. Live Gemini multi-screenshot eval.
6. Local browser app benchmark with Playwright as a computer-use stand-in.
7. Real macOS capture integration.
8. Real computer-use agent benchmark.

## Hackathon Cutline

The smallest persuasive demo:

1. User performs a task once in a synthetic app.
2. System learns surfaces, transitions, recipe, and no-op.
3. Same goal is issued again.
4. Agent chooses the right first action immediately from memory.
5. Metrics show fewer exploratory actions and no repeated no-op.

That demo proves the core product thesis without needing full macOS capture yet.
