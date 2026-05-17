# AgentNotch eval harness

Fixture-based offline evaluation for Mercury 2 prompts used by the context system. See spec `docs/superpowers/specs/2026-05-16-context-system-redesign-design.md` §13 for the design.

## Layout

```
fixtures/
  selector/<scenario>/
    input.json       # full selector input payload (the JSON Mercury receives as user message)
    expected.json    # scorer constraints + expected intent
    notes.md         # human description of the scenario
goldens/
  selector/<scenario>/
    <sha256-of-input.json>.json   # canned ideal Mercury response (used by Mock-LLM mode)
results/             # gitignored; written by `eval-runner live`
```

## Run

```bash
cd tools/MercurySpike
swift run eval-runner list           # show discovered fixtures
swift run eval-runner mock           # run all through MockLLMClient (no network)
swift run eval-runner live           # run all against OpenRouter (real network, costs money)
```

## Authoring a new fixture

1. Make a directory under `fixtures/selector/scenario-<short-name>/`.
2. Write `input.json` — the full selector input payload shaped per spec §7.2.
3. Write `expected.json` — must include `intent.verb` and `brief_must_contain`; optional `brief_must_not_contain`, `brief_token_budget`, `intent.resolved_target_contains`, `intent.entities`.
4. Write `notes.md` — one paragraph for humans on what this scenario tests.
5. Generate the golden: in another terminal, run the fixture against Mercury manually with the spike CLI; hand-edit the response to be ideal; save it to `goldens/selector/scenario-<short-name>/<sha256-of-input-bytes>.json`. The SHA256 must match `MockLLMClient.sha256Hex(<input.json bytes>)` exactly.

## Why sha256-keyed goldens

Mock mode replays an exact-input → exact-response mapping. Changing `input.json` invalidates the golden — that's intentional, so we can't accidentally drift the fixture without re-validating the response.
