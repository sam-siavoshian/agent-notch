# Contributing

Thanks for considering a PR.

## Setup

```bash
brew install xcodegen
bash scripts/setup-signing.sh
xcodegen generate
open AgentNotch.xcodeproj
```

You'll need an Apple Development cert (free Apple ID is fine) so TCC grants persist across rebuilds.

## Keys

Add `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` to the Xcode scheme env, or paste them into Settings → keys after launch (Keychain-backed). Never commit `.env`.

## Conventions

- Read [AGENTS.md](AGENTS.md). It covers Swift style, the feature layout, and the cross-feature interface rules.
- Architecture map lives in [CLAUDE.md](CLAUDE.md). Product spec in [PRD.md](PRD.md).
- Keep diffs small. One concern per PR.
- Don't touch `*.xcodeproj` — regenerate via `xcodegen generate`. Changes to layout go in `Project.yml`.

## Build + run

`⌘R` in Xcode. CI builds via `xcodebuild` against the schemes from `Project.yml` — keep both green.

## Filing PRs

Open a draft PR early for non-trivial work so we can agree on the approach before the refactor. Include:

- What changed and why.
- Manual test steps (this is a computer-use agent — automated coverage only goes so far).
- Screenshots / a short clip for UI changes.

## Bugs

Use the issue templates under [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/). Include macOS version, MacBook model (notch matters), and a Console export if the agent crashed or hung.
