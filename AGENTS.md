# AGENTS.md

## Purpose

This repository is optimized for:
- fast iteration
- AI-assisted development
- low-context edits
- reliable shipping

Favor:
- simple code
- explicit structure
- local reasoning
- predictable patterns

Avoid:
- over-engineering
- premature abstraction
- architectural churn

---

# Structure

```txt
App/
Features/
Core/
Generated/
Tests/
```

---

# Feature Layout

Each feature owns its code.

```txt
Features/Notch/
├── NotchContentView.swift
├── AgentStateView.swift
├── AgentSettingsView.swift
└── NotchShape.swift
```

Keep related code together.

Do not create:
- global managers
- giant shared services
- generic utility dumping grounds

---

# Architecture

Preferred flow:

```txt
View
 ↕
ViewModel
 ↕
Service
```

Responsibilities:

| Layer | Responsibility |
|---|---|
| View | rendering + user interaction |
| ViewModel | UI state + orchestration |
| Service | API/storage side effects |
| Models | lightweight data types |

---

# Rules

## 1. Prefer Locality

If code is only used by one feature:
- keep it inside that feature

Do not abstract early.

---

## 2. Keep Dependencies Simple

Allowed:

```txt
Feature → Core
Feature → Generated
```

Avoid:
- Feature → Feature imports
- circular dependencies
- hidden shared state

Shared logic belongs in `Core/`.

---

## 3. Keep Files Focused

Target:
- ~100–500 LOC
- one primary responsibility

Split files when reasoning becomes difficult.

---

## 4. Use Explicit Names

Prefer:

```swift
ChatService
ProfileViewModel
AuthSession
```

Avoid:

```swift
Manager
Helper
Utils
BaseObject
```

Names should be searchable and unambiguous.

---

## 5. Prefer Modern Swift

Use:
- SwiftUI
- async/await
- structs
- value semantics
- `@MainActor` on ObservableObject singletons

Avoid:
- unnecessary protocols
- deep inheritance
- unnecessary frameworks

---

# AI Agent Guidelines

When editing:
- preserve existing patterns
- prefer minimal diffs
- avoid broad refactors
- keep changes localized

When generating:
- optimize for readability
- optimize for compile reliability
- prefer explicit control flow

Do not introduce:
- speculative abstractions
- meta-programming
- hidden side effects

---

# Proactive Development Posture

The agent should be an active engineering partner, not a passive command runner.

Default behavior:
- keep driving to the next useful layer after each result
- turn findings into concrete patches, tests, demos, or measured recommendations
- propose and implement safe next steps without waiting for repeated prompting
- benchmark performance-sensitive paths instead of guessing
- write down important learnings in repo docs or inspectable artifacts
- surface tradeoffs clearly, then choose a reasonable default when the choice is reversible

For experimental systems:
- build isolated harnesses before wiring risky ideas into the app
- create repeatable demos that show first-run vs second-run behavior
- measure latency, action count, failure rate, and memory usefulness
- inspect real model outputs and harden parsers/prompts against drift
- keep cached/model outputs local unless they are synthetic and safe to commit

Ask the user only when:
- the decision changes product direction
- the choice is hard to reverse
- credentials, privacy, or destructive actions are involved
- multiple maintainers may be editing the same owned surface

Do not ask just to continue obvious work. If the next step is clear, do it and report back with results.

---

# Collaboration Workflow

This is a shared hackathon repo with multiple maintainers and AI agents working at the same time.

Default workflow:
- work directly on `main`
- do not create branches
- do not open PRs
- fetch and fast-forward pull from `origin/main` before starting meaningful work
- fetch and fast-forward pull again before committing or pushing
- commit small, complete, verified changes directly to `main`
- push to `origin/main` after each complete change

If `git pull --ff-only origin main` cannot fast-forward:
- stop
- inspect the conflict/race
- ask before resolving or rewriting anything

Before editing:
- check `git status`
- assume unfamiliar local changes belong to another maintainer or agent
- never overwrite or revert changes you did not make unless explicitly asked

---

# Current Ownership Boundaries

Stay in the owning feature folder whenever possible.

Current work areas:
- `Features/Notch/` — notch UI and settings
- `Features/Cursor/` — cursor companion, long-press gesture plumbing, click hooks, computer-use actions
- `Features/Context/` — screenshot capture, screen understanding, recent activity memory
- `Features/Agent/` — model input assembly, tool orchestration, agent execution
- `Core/` — stable shared types and cross-feature interfaces only

For Ashan/Codex context work:
- prefer `Features/Context/` and `Features/Agent/`
- use `Core/` only for explicit contracts shared with other features
- avoid editing `Features/Notch/` or `Features/Cursor/` unless integration requires it
- treat `vendored/` as read-only reference unless explicitly told otherwise

---

# Product Constraints

This is a local macOS desktop app.

Do not add:
- backend servers
- accounts
- cloud sync
- remote databases
- browser extensions

Users bring their own API keys.

API keys and secrets must:
- stay local
- never be hardcoded
- never be committed
- be read from local settings, environment, or Keychain-style storage

For context and screen understanding:
- prefer a screenshot-first design
- use OS events as capture triggers and metadata, not as the primary source of truth
- keep Accessibility API usage optional, narrow, and isolated
- favor on-device preprocessing when it reduces model work
- keep outputs inspectable and useful to the computer-use agent
- avoid a complex graph or embedding system until a simpler artifact proves insufficient

---

# Networking

Prefer:
- URLSession
- Codable
- async/await

Keep services feature-scoped when possible.

Prefer:

```txt
Features/Chat/ChatService.swift
```

over:

```txt
Core/API/GlobalAPIManager.swift
```

---

# Generated Code

Generated files belong in:

```txt
Generated/
```

Never manually edit generated files.

---

# Priority Order

1. shipping
2. correctness
3. clarity
4. iteration speed
5. architecture purity

This is a hackathon project.
Optimize for momentum.
