# Fixtures

Drop real screenshots here to evaluate Gemini perception quality.

## Format

For each fixture, two files with matching stems:

- `myname.png` — the screenshot.
- `myname.expected.json` — ground truth sidecar.

The sidecar shape:

```json
{
  "expected_surface": "Slack #design composer",
  "expected_controls": ["Send", "Attach file", "Emoji"]
}
```

## Scoring

- **Surface match** is 1.0 if `expected_surface` appears (case-insensitive substring) in the model's `current_surface`, else 0.0.
- **Control recall** = |expected ∩ observed| / |expected|.
- **Control precision** = |expected ∩ observed| / |observed|.
- Label comparison is case-insensitive and trims whitespace.

## Running

```bash
# Dry mode — no API key required, prints prompt + request bodies.
swift run gemini-perception-eval \
  --fixtures fixtures \
  --variants high-min,ultra-min \
  --report /tmp/eval-report.md

# Live mode — set GEMINI_API_KEY first.
GEMINI_API_KEY=... swift run gemini-perception-eval \
  --fixtures fixtures \
  --variants high-min,ultra-min,medium-min \
  --report out/report.md
```

`example.expected.json` is a placeholder so the CLI has at least one sidecar to point at during testing.
