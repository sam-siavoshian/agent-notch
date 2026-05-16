# ArshanTesting

An isolated screenshot-first UI/UX learning sandbox for the Agent in the Notch context system.

This folder is intentionally at the repo root. Do not move it under `Features/`, `Core/`, or `App/`; `Project.yml` compiles those folders into the macOS app target.

## What This Tests

The core claim:

```txt
After the agent observes an application or website once, learned UI/UX memory should reduce exploration on the next similar task.
```

The first demo uses a synthetic deployment dashboard because it is deterministic and easy to score. That fixture is not the product boundary. The target is general app knowledge: surfaces, landmarks, controls, affordances, transitions, task recipes, no-ops, stale notes, and user-specific usage patterns across native apps and browser apps.

For the larger system direction, see `SYSTEM_BLUEPRINT.md`. It lays out the path from screenshot ingestion to transition learning, activation bundles, and computer-use performance benchmarks.

## Setup

```bash
cd ArshanTesting
npm install
cp .env.example .env
```

`GEMINI_API_KEY` is optional for normal tests. Without it, the harness uses deterministic fixture observations so tests remain repeatable.

To run live Gemini image understanding, set:

```bash
GEMINI_API_KEY=...
GEMINI_MODEL=gemini-3.1-flash-lite
GEMINI_MEDIA_RESOLUTION=low
GEMINI_MAX_OUTPUT_TOKENS=1600
GEMINI_IMAGE_MODE=auto
GEMINI_IMAGE_AUTO_THRESHOLD_KB=250
GEMINI_IMAGE_MAX_SIZE=960
GEMINI_JPEG_QUALITY=70
```

## Commands

```bash
npm run generate
npm run assess:memory
npm run bench:gemini
npm test
npm run demo
npm run typecheck
npm run test:live
```

For uncached live latency checks:

```bash
ARSHAN_LIVE_GEMINI=1 ARSHAN_BYPASS_CACHE=1 npm run demo
```

## Memory Artifacts

- `memory/observations.jsonl` stores raw screen observations.
- `memory/apps/*.md` stores inspectable per-app UI memory.
- `memory/cache/` stores Gemini responses by screenshot hash.
- `npm run assess:memory` checks whether the stored app memory has the required surfaces, affordances, transitions, negative memory, uncertainty, and portable evidence.

Commit synthetic fixtures and stable test artifacts. Do not commit real private screenshots or secrets.

## Assessment

See `ASSESSMENT.md` for the current honest read.

Short version: this is now a stronger controlled harness, but the actual product-level learning problem is not solved yet. The next important layer is visual transition inference from before/after screenshots and click positions, so the system learns how the UI works without relying on scripted action labels.

## Performance Notes

Live Gemini calls are for background ingestion, not long-press activation. Use `npm run bench:gemini` to compare model and media-resolution latency before changing defaults.

Recommended first knobs:

- `GEMINI_MODEL=gemini-3.1-flash-lite` for the default product path
- benchmark `gemini-2.5-flash-lite` when optimizing pure ingestion throughput
- `GEMINI_MEDIA_RESOLUTION=low` for cheap screen orientation
- `GEMINI_IMAGE_MODE=auto` sends small/window crops as-is and optimizes large screenshots
- `GEMINI_MEDIA_RESOLUTION=medium` only when low misses text/control details
- keep activation on cached/current memory, not a fresh live VLM call

Initial live benchmark on `acme-overview.png`:

```txt
gemini-2.5-flash-lite low:    ~2.2s
gemini-2.5-flash-lite medium: ~2.7s
gemini-3.1-flash-lite low:    ~4.3-7.6s
gemini-3.1-flash-lite medium: ~4.4s
old gemini-3-flash-preview path: ~20s
```

Takeaway: use `3.1-flash-lite + low media resolution` as the default experiment path, while keeping `2.5-flash-lite` in the benchmark suite as a lower-latency comparison point.

Image preprocessing result on the small synthetic overview screenshot:

```txt
original PNG, 68KB: ~4.0-6.3s, 7 controls, 6 entities
960px JPEG, 43KB:   ~4.2-12.4s, 7 controls, 4 entities
720px JPEG, 28KB:   ~4.7-6.4s, 7 controls, 4 entities
540px JPEG, 18KB:   ~4.8-5.1s, 7 controls, 4 entities
```

Takeaway: do not blindly downsample small/window-crop screenshots. The default is `auto`: preserve small images and only resize/compress large captures.

Batching note: independent screenshot observations should run in parallel during background ingestion. Sequential live VLM calls stack latency; parallel calls make a four-frame batch feel closer to the slowest single frame instead of the sum of all frames.

Uncached live replay note: a two-pass demo with two four-frame parallel waves took about 40s wall time with `gemini-3.1-flash-lite + low + auto`. This reinforces the product rule: VLM ingestion must happen continuously in the background. Long-press activation should read already-processed observations, summaries, and UI memory.

## References

- Gemini image understanding: https://ai.google.dev/gemini-api/docs/image-understanding
- Apple Vision OCR: https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- ScreenCaptureKit dirty rects: https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects
