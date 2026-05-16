# AGENT.md

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
Features/Chat/
├── ChatView.swift
├── ChatViewModel.swift
├── ChatService.swift
├── ChatModels.swift
└── Components/
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
