# MercurySpike

Throwaway developer tools for AgentNotch's context-system redesign (spec: `docs/superpowers/specs/2026-05-16-context-system-redesign-design.md`).

Two CLIs:
- `mercury-spike` — probes OpenRouter to discover Mercury 2 model slug, measure latency, validate JSON-mode.
- `eval-runner` — runs the fixture-based eval harness in Mock-LLM or Live-Mercury mode.

## Setup

```bash
export OPENROUTER_API_KEY=...
cd tools/MercurySpike
swift build
```

## Run the spike

```bash
swift run mercury-spike all
```

## Run the eval

```bash
swift run eval-runner mock          # Mock-LLM mode (no network)
swift run eval-runner live          # Live-Mercury mode (real OpenRouter calls, costs money)
```
