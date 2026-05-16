# ArshanTesting

An isolated screenshot-first UI/UX learning sandbox for the Agent in the Notch context system.

This folder is intentionally at the repo root. Do not move it under `Features/`, `Core/`, or `App/`; `Project.yml` compiles those folders into the macOS app target.

## What This Tests

The core claim:

```txt
After the agent observes a dashboard once, learned UI memory should reduce exploration on the next similar task.
```

The first demo is a synthetic deployment dashboard. The first run explores the UI. The second run uses learned app memory to find the failed deployment with fewer actions and screenshots.

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
```

## Commands

```bash
npm run generate
npm run bench:gemini
npm test
npm run demo
npm run typecheck
npm run test:live
```

## Memory Artifacts

- `memory/observations.jsonl` stores raw screen observations.
- `memory/apps/*.md` stores inspectable per-app UI memory.
- `memory/cache/` stores Gemini responses by screenshot hash.

Commit synthetic fixtures and stable test artifacts. Do not commit real private screenshots or secrets.

## Performance Notes

Live Gemini calls are for background ingestion, not long-press activation. Use `npm run bench:gemini` to compare model and media-resolution latency before changing defaults.

Recommended first knobs:

- `GEMINI_MODEL=gemini-3.1-flash-lite` for the default product path
- benchmark `gemini-2.5-flash-lite` when optimizing pure ingestion throughput
- `GEMINI_MEDIA_RESOLUTION=low` for cheap screen orientation
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

## References

- Gemini image understanding: https://ai.google.dev/gemini-api/docs/image-understanding
- Apple Vision OCR: https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- ScreenCaptureKit dirty rects: https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects
