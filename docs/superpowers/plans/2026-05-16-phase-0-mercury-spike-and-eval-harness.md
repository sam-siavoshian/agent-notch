# Phase 0 — Mercury Spike + Eval Harness Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate Mercury 2 via OpenRouter is viable for the three Mercury roles defined in the spec, and stand up the offline eval harness with the first three selector fixtures so all subsequent Mercury work can be validated before going live.

**Architecture:** A throwaway `tools/MercurySpike` Swift Package contains (1) an `OpenRouterClient`, (2) a CLI `MercurySpike` that probes the API to discover the Mercury 2 model slug and measure latency/cost, and (3) an `EvalHarness` library + `EvalRunner` CLI that loads JSON fixtures, sends them through either a `MockLLMClient` or the `OpenRouterClient`, and runs deterministic scorers (must_contain, must_not_contain, intent_match, pixel_coord_grep, token_budget, schema_valid). Fixtures live in `tests/eval/` so later phases reuse the same harness. The whole package is **out-of-target** for AgentNotch.app — it ships nothing to end users; it's purely a developer tool that the production `MercuryClient` (built later in phase 4) will defer to for prompt validation.

**Tech Stack:** Swift 5.10 (`swift-tools-version: 5.10`), Foundation `URLSession` + `async/await`, XCTest, SwiftPM. OpenRouter `/api/v1/chat/completions` endpoint (OpenAI-compatible request/response shape). JSON fixtures via Codable. No third-party dependencies — Foundation only.

---

## Spec coverage

This plan implements **spec §13 (eval harness)** end-to-end and **spec §10 risk #1 (Mercury spike)** entirely. It also produces the first three §11 acceptance fixtures (Scenario A/B/C). It does **not** implement any production context code — Phases 1+ do that.

## File structure

All paths are relative to the repo root `/Users/arshan/Desktop/tritonhacks2026/`.

```
tools/MercurySpike/                          # NEW SwiftPM package, throwaway
  Package.swift                              # Package manifest: 3 products, 1 dep (none external)
  README.md                                  # How to run the spike + eval CLIs
  Sources/
    OpenRouterAPI/                           # Library: client + Codable models
      OpenRouterClient.swift                 # URLSession wrapper, async/await
      ChatCompletionsModels.swift            # Codable request/response types
      OpenRouterError.swift                  # Typed errors
    EvalHarness/                             # Library: fixtures + scorers + runner core
      Fixture.swift                          # Fixture model
      Scorer.swift                           # Scorer protocol + ScoreResult
      Scorers/                               # one scorer per file
        MustContainScorer.swift
        MustNotContainScorer.swift
        IntentMatchScorer.swift
        PixelCoordGrepScorer.swift
        TokenBudgetScorer.swift
        SchemaValidScorer.swift
      Harness.swift                          # Orchestrator: loads fixtures, runs scorers
      LLMClientProtocol.swift                # Abstracts Mock + Live clients
      MockLLMClient.swift                    # Replays canned responses by input hash
      LiveMercuryClient.swift                # Wraps OpenRouterClient for harness use
    MercurySpike/                            # Executable: CLI to probe Mercury via OpenRouter
      MercurySpikeCLI.swift                  # @main entry (NOT named main.swift — Swift 5.5+ rule)
      ProbeCommands.swift                    # listModels, ping, jsonMode, latency, all
    EvalRunner/                              # Executable: runs fixtures through harness
      EvalRunnerCLI.swift                    # @main entry (NOT named main.swift)
      RunnerCommands.swift                   # mock, live, list, score
  Tests/
    OpenRouterAPITests/
      OpenRouterClientTests.swift
      ChatCompletionsModelsTests.swift
    EvalHarnessTests/
      MustContainScorerTests.swift
      MustNotContainScorerTests.swift
      IntentMatchScorerTests.swift
      PixelCoordGrepScorerTests.swift
      TokenBudgetScorerTests.swift
      SchemaValidScorerTests.swift
      HarnessTests.swift
      MockLLMClientTests.swift
      FixtureLoadingTests.swift

tests/eval/                                  # NEW; lives at repo root so later phases share it
  fixtures/
    selector/
      scenario-A-slack-dm-with-person/
        input.json                           # full selector input payload
        expected.json                        # expected intent + brief constraints
        notes.md                             # human-readable scenario description
      scenario-B-arc-open-PR/
        input.json
        expected.json
        notes.md
      scenario-C-iterm-run-tests/
        input.json
        expected.json
        notes.md
  goldens/                                   # Hand-curated ideal responses for Mock-LLM mode
    selector/
      scenario-A-slack-dm-with-person/
        golden.json
      scenario-B-arc-open-PR/
        golden.json
      scenario-C-iterm-run-tests/
        golden.json
  results/                                   # Gitignored; written by live runs
    .gitkeep
  README.md                                  # Fixture authoring conventions

docs/superpowers/spikes/                     # NEW; spike findings live here
  2026-05-16-mercury-via-openrouter-findings.md   # populated by Task 9 and Task 27

.gitignore                                   # MODIFIED — add tests/eval/results/* + tools/MercurySpike/.build
```

**Why a separate SwiftPM package** rather than wiring into `AgentNotch.xcodeproj`: the spike is throwaway and the eval harness should be runnable in CI without launching the macOS UI. A standalone package builds with `swift build` on the command line — no XcodeGen regen required. The production `MercuryClient.swift` (Phase 4) will live in `Features/Context/` inside the AgentNotch app target; nothing in this package gets shipped to users.

---

## Section A — Mercury via OpenRouter spike

### Task 1: Scaffold the SwiftPM package

**Files:**
- Create: `tools/MercurySpike/Package.swift`
- Create: `tools/MercurySpike/README.md`
- Create: `tools/MercurySpike/.gitignore`

- [ ] **Step 1: Create the package directory + Package.swift**

Run: `mkdir -p tools/MercurySpike/Sources/{OpenRouterAPI,EvalHarness,EvalHarness/Scorers,MercurySpike,EvalRunner} tools/MercurySpike/Tests/{OpenRouterAPITests,EvalHarnessTests}`

Then create `tools/MercurySpike/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MercurySpike",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenRouterAPI", targets: ["OpenRouterAPI"]),
        .library(name: "EvalHarness", targets: ["EvalHarness"]),
        .executable(name: "mercury-spike", targets: ["MercurySpike"]),
        .executable(name: "eval-runner", targets: ["EvalRunner"]),
    ],
    targets: [
        .target(name: "OpenRouterAPI"),
        .target(name: "EvalHarness", dependencies: ["OpenRouterAPI"]),
        .executableTarget(name: "MercurySpike", dependencies: ["OpenRouterAPI"]),
        .executableTarget(name: "EvalRunner", dependencies: ["EvalHarness"]),
        .testTarget(name: "OpenRouterAPITests", dependencies: ["OpenRouterAPI"]),
        .testTarget(name: "EvalHarnessTests", dependencies: ["EvalHarness"]),
    ]
)
```

- [ ] **Step 2: Create README + .gitignore**

`tools/MercurySpike/README.md`:

````markdown
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
````

`tools/MercurySpike/.gitignore`:

```
.build/
.swiftpm/
*.xcodeproj
Package.resolved
```

- [ ] **Step 3: Confirm package builds**

Run: `cd tools/MercurySpike && swift build`
Expected: builds, exits 0. Some targets will be empty (no .swift files yet) but `swift build` succeeds for empty targets.

If you get `no rule to process file ...`, ensure each target dir has at least one placeholder `.swift` file. Quick fix: `for d in Sources/OpenRouterAPI Sources/EvalHarness Sources/MercurySpike Sources/EvalRunner Tests/OpenRouterAPITests Tests/EvalHarnessTests; do touch "$d/Placeholder.swift"; done` then `swift build` again. Placeholders are replaced by real code in later tasks.

- [ ] **Step 4: Commit**

```bash
git add tools/MercurySpike/
git commit -m "Phase 0: scaffold MercurySpike SwiftPM package"
```

### Task 2: ChatCompletions Codable models

OpenRouter is OpenAI-compatible: requests are `chat/completions` shape. We need request + response types matching their schema.

**Files:**
- Create: `tools/MercurySpike/Sources/OpenRouterAPI/ChatCompletionsModels.swift`
- Create: `tools/MercurySpike/Tests/OpenRouterAPITests/ChatCompletionsModelsTests.swift`
- Modify: delete `tools/MercurySpike/Sources/OpenRouterAPI/Placeholder.swift`

- [ ] **Step 1: Write the failing test**

`Tests/OpenRouterAPITests/ChatCompletionsModelsTests.swift`:

```swift
import XCTest
@testable import OpenRouterAPI

final class ChatCompletionsModelsTests: XCTestCase {

    func testRequestEncodesMinimalShape() throws {
        let req = ChatCompletionRequest(
            model: "inception/mercury-2",
            messages: [.init(role: "user", content: "hello")]
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "inception/mercury-2")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hello")
    }

    func testRequestEncodesResponseFormat() throws {
        let req = ChatCompletionRequest(
            model: "x/y",
            messages: [.init(role: "user", content: "hi")],
            responseFormat: .jsonObject
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rf = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(rf["type"] as? String, "json_object")
    }

    func testResponseDecodesOpenRouterShape() throws {
        let json = """
        {
          "id": "gen-123",
          "model": "inception/mercury-2",
          "choices": [
            { "index": 0,
              "message": { "role": "assistant", "content": "hi back" },
              "finish_reason": "stop" }
          ],
          "usage": { "prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16 }
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ChatCompletion.self, from: json)
        XCTAssertEqual(resp.id, "gen-123")
        XCTAssertEqual(resp.choices.first?.message.content, "hi back")
        XCTAssertEqual(resp.usage?.totalTokens, 16)
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter ChatCompletionsModelsTests`
Expected: FAIL (`cannot find 'ChatCompletionRequest' in scope`).

- [ ] **Step 3: Implement models**

Delete the placeholder: `rm tools/MercurySpike/Sources/OpenRouterAPI/Placeholder.swift`

Create `Sources/OpenRouterAPI/ChatCompletionsModels.swift`:

```swift
import Foundation

public struct ChatCompletionRequest: Encodable {
    public let model: String
    public let messages: [Message]
    public let responseFormat: ResponseFormat?
    public let temperature: Double?
    public let maxTokens: Int?

    public init(
        model: String,
        messages: [Message],
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.messages = messages
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

public struct Message: Codable {
    public let role: String  // "system" | "user" | "assistant"
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum ResponseFormat: Encodable {
    case jsonObject

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .jsonObject:
            try container.encode("json_object", forKey: .type)
        }
    }
    private enum CodingKeys: String, CodingKey { case type }
}

public struct ChatCompletion: Decodable {
    public let id: String
    public let model: String
    public let choices: [Choice]
    public let usage: Usage?

    public struct Choice: Decodable {
        public let index: Int
        public let message: Message
        public let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Decodable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter ChatCompletionsModelsTests`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/OpenRouterAPI/ChatCompletionsModels.swift \
        tools/MercurySpike/Tests/OpenRouterAPITests/ChatCompletionsModelsTests.swift
git rm tools/MercurySpike/Sources/OpenRouterAPI/Placeholder.swift 2>/dev/null || true
git commit -m "Phase 0: ChatCompletions Codable models"
```

### Task 3: OpenRouterClient with URLProtocol-mockable transport

**Files:**
- Create: `tools/MercurySpike/Sources/OpenRouterAPI/OpenRouterError.swift`
- Create: `tools/MercurySpike/Sources/OpenRouterAPI/OpenRouterClient.swift`
- Create: `tools/MercurySpike/Tests/OpenRouterAPITests/OpenRouterClientTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/OpenRouterAPITests/OpenRouterClientTests.swift`:

```swift
import XCTest
@testable import OpenRouterAPI

final class OpenRouterClientTests: XCTestCase {

    override class func setUp() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
    }
    override func setUp() {
        MockURLProtocol.requestHandler = nil
    }

    func testClientPostsToCorrectEndpointWithAuth() async throws {
        let captured = ExpectationBox<URLRequest>()
        MockURLProtocol.requestHandler = { req in
            captured.value = req
            let body = """
            {"id":"x","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let client = OpenRouterClient(apiKey: "sk-test", session: Self.mockSession())
        _ = try await client.chatCompletion(request: ChatCompletionRequest(
            model: "inception/mercury-2",
            messages: [.init(role: "user", content: "hi")]
        ))
        let req = try XCTUnwrap(captured.value)
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "AgentNotch")
    }

    func testClientThrowsOnNon2xx() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
             Data("rate limited".utf8))
        }
        let client = OpenRouterClient(apiKey: "sk", session: Self.mockSession())
        do {
            _ = try await client.chatCompletion(request: ChatCompletionRequest(
                model: "m", messages: [.init(role: "user", content: "x")]))
            XCTFail("expected throw")
        } catch let error as OpenRouterError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // helpers
    static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Test infra (kept inside the test target)

final class ExpectationBox<T> {
    var value: T?
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter OpenRouterClientTests`
Expected: FAIL (no `OpenRouterClient`, no `OpenRouterError`).

- [ ] **Step 3: Implement OpenRouterError**

`Sources/OpenRouterAPI/OpenRouterError.swift`:

```swift
import Foundation

public enum OpenRouterError: Error, CustomStringConvertible {
    case httpStatus(Int, Data)
    case missingAPIKey
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .httpStatus(let code, let data):
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
            return "OpenRouter HTTP \(code): \(preview)"
        case .missingAPIKey:
            return "OPENROUTER_API_KEY not set"
        case .malformedResponse(let s):
            return "Malformed OpenRouter response: \(s)"
        }
    }
}
```

- [ ] **Step 4: Implement OpenRouterClient**

`Sources/OpenRouterAPI/OpenRouterClient.swift`:

```swift
import Foundation

public struct OpenRouterClient {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func chatCompletion(request: ChatCompletionRequest) async throws -> ChatCompletion {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenRouter best-practice headers; harmless if omitted.
        req.addValue("AgentNotch", forHTTPHeaderField: "X-Title")
        req.addValue("https://github.com/wyattgill01/AgentNotch", forHTTPHeaderField: "HTTP-Referer")

        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.httpStatus(http.statusCode, data)
        }
        return try JSONDecoder().decode(ChatCompletion.self, from: data)
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter OpenRouterClientTests`
Expected: both tests PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/MercurySpike/Sources/OpenRouterAPI/OpenRouterError.swift \
        tools/MercurySpike/Sources/OpenRouterAPI/OpenRouterClient.swift \
        tools/MercurySpike/Tests/OpenRouterAPITests/OpenRouterClientTests.swift
git commit -m "Phase 0: OpenRouterClient with URLProtocol-mockable transport"
```

### Task 4: MercurySpike CLI — `ping` command

The CLI's first command does a minimal round-trip against a known model to confirm auth + connectivity work before we probe Mercury specifically.

**Files:**
- Create: `tools/MercurySpike/Sources/MercurySpike/MercurySpikeCLI.swift`
- Create: `tools/MercurySpike/Sources/MercurySpike/ProbeCommands.swift`
- Modify: delete `tools/MercurySpike/Sources/MercurySpike/Placeholder.swift`

- [ ] **Step 1: Implement CLI entry point**

`Sources/MercurySpike/MercurySpikeCLI.swift` (note: NOT `main.swift` — Swift's `@main` attribute conflicts with files named `main.swift`):

```swift
import Foundation
import OpenRouterAPI

@main
struct MercurySpikeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            FileHandle.standardError.write(Data("ERROR: OPENROUTER_API_KEY not set\n".utf8))
            exit(2)
        }
        let client = OpenRouterClient(apiKey: apiKey)

        do {
            switch command {
            case "ping":
                try await ProbeCommands.ping(client: client, model: args.dropFirst().first ?? "inception/mercury-2")
            case "help", "--help", "-h":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                printUsage()
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage: mercury-spike <command> [args]

        Commands:
          ping [model]       Send a tiny round-trip; default model: inception/mercury-2
          jsonMode [model]   Validate response_format=json_object behavior
          latency [model]    Measure p50/p95 at representative payload sizes (10 runs)
          all                Run ping, jsonMode, latency in sequence
        """)
    }
}
```

`Sources/MercurySpike/ProbeCommands.swift`:

```swift
import Foundation
import OpenRouterAPI

enum ProbeCommands {

    static func ping(client: OpenRouterClient, model: String) async throws {
        print("→ ping model=\(model)")
        let start = Date()
        let resp = try await client.chatCompletion(request: .init(
            model: model,
            messages: [.init(role: "user", content: "Reply with exactly the word OK and nothing else.")],
            maxTokens: 10
        ))
        let elapsed = Date().timeIntervalSince(start)
        let content = resp.choices.first?.message.content ?? "<none>"
        print("  latency: \(String(format: "%.2f", elapsed))s")
        print("  content: \(content.prefix(120))")
        if let usage = resp.usage {
            print("  tokens:  prompt=\(usage.promptTokens) completion=\(usage.completionTokens)")
        }
    }
}
```

- [ ] **Step 2: Delete placeholder, build**

Run:
```bash
rm tools/MercurySpike/Sources/MercurySpike/Placeholder.swift
cd tools/MercurySpike && swift build
```
Expected: build succeeds. (No tests for CLI entry points — they require network.)

- [ ] **Step 3: Verify CLI works against a known-good model**

Run (replace `<key>` with your OpenRouter API key, or just `export OPENROUTER_API_KEY=...` first):
```bash
cd tools/MercurySpike && swift run mercury-spike ping openai/gpt-4o-mini
```

Expected output (within ~3s):
```
→ ping model=openai/gpt-4o-mini
  latency: 0.XXs
  content: OK
  tokens:  prompt=XX completion=X
```

This proves auth + transport + model wiring all work. If this fails, debug here before moving on — every later task depends on this round-trip working.

- [ ] **Step 4: Commit**

```bash
git add tools/MercurySpike/Sources/MercurySpike/MercurySpikeCLI.swift \
        tools/MercurySpike/Sources/MercurySpike/ProbeCommands.swift
git rm tools/MercurySpike/Sources/MercurySpike/Placeholder.swift 2>/dev/null || true
git commit -m "Phase 0: mercury-spike CLI with ping command"
```

### Task 5: Discover Mercury 2 model slug on OpenRouter

This is an exploratory task — no TDD here. The goal is to figure out what string to pass as `model:` to get Mercury 2.

- [ ] **Step 1: List Mercury-related models on OpenRouter**

Run:
```bash
curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" \
     https://openrouter.ai/api/v1/models \
  | grep -iE '"id"[^,]*mercury' | head -20
```

Expected: a JSON-ish list of strings like `"id": "inception/mercury-2"`. If you see multiple Mercury variants (e.g. `mercury-coder`, `mercury-coder-small`), note all of them.

If `grep` returns nothing, the slug doesn't include the literal word "mercury" — broaden the search:
```bash
curl -s -H "Authorization: Bearer $OPENROUTER_API_KEY" \
     https://openrouter.ai/api/v1/models \
  | python3 -m json.tool | grep -iE '"id"|inception' | head -40
```

- [ ] **Step 2: Ping each candidate slug**

For each Mercury slug discovered, run:
```bash
cd tools/MercurySpike && swift run mercury-spike ping <slug>
```

Record: which slug returns 200 with sensible content. If multiple work, prefer the largest/most-capable Mercury variant unless cost/latency is significantly worse.

- [ ] **Step 3: Record findings**

Create `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`:

```markdown
# Mercury via OpenRouter — Findings

**Date:** 2026-05-16

## Discovered model slugs

| Slug | Works? | Sample latency | Notes |
|---|---|---|---|
| `inception/mercury-2` | ✓/✗ | XX s | ... |
| `inception/...` | ... | ... | ... |

## Selected slug for AgentNotch context pipeline

`inception/<slug>` — rationale: ...

## Notes / caveats

- ...
```

Fill in the table from your runs in Step 2.

- [ ] **Step 4: Commit findings**

```bash
git add docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md
git commit -m "Phase 0: record Mercury 2 model slug discovery on OpenRouter"
```

### Task 6: JSON-mode validation command

The spec's Selector and ActiveTaskUpdater both require structured JSON output. If OpenRouter's `response_format: json_object` doesn't reliably hold for Mercury, the whole design changes (we'd need to parse free-form text). This task validates JSON-mode reliability.

**Files:**
- Modify: `tools/MercurySpike/Sources/MercurySpike/ProbeCommands.swift`
- Modify: `tools/MercurySpike/Sources/MercurySpike/main.swift`

- [ ] **Step 1: Add jsonMode probe**

Append to `Sources/MercurySpike/ProbeCommands.swift`:

```swift
extension ProbeCommands {
    static func jsonMode(client: OpenRouterClient, model: String, runs: Int = 5) async throws {
        print("→ jsonMode model=\(model) runs=\(runs)")
        let systemPrompt = """
        Return strictly one JSON object with this shape:
        {"intent": {"verb": string, "target": string}, "brief": string}
        No prose outside the JSON.
        """
        let userPrompt = "Transcript: \"open the latest PR\"\nReturn the JSON object only."

        var validCount = 0
        var totalLatency: TimeInterval = 0
        for i in 1...runs {
            let start = Date()
            let resp = try await client.chatCompletion(request: .init(
                model: model,
                messages: [
                    .init(role: "system", content: systemPrompt),
                    .init(role: "user", content: userPrompt)
                ],
                responseFormat: .jsonObject,
                maxTokens: 300
            ))
            let elapsed = Date().timeIntervalSince(start)
            totalLatency += elapsed
            let content = resp.choices.first?.message.content ?? ""
            let isValid = isStrictJSON(content)
            validCount += isValid ? 1 : 0
            let status = isValid ? "✓" : "✗"
            print("  run \(i): \(String(format: "%.2f", elapsed))s \(status)")
            if !isValid {
                print("    raw: \(content.prefix(200))")
            }
        }
        let avg = totalLatency / Double(runs)
        let rate = Double(validCount) / Double(runs) * 100
        print("  json valid: \(validCount)/\(runs) (\(String(format: "%.0f", rate))%)")
        print("  avg latency: \(String(format: "%.2f", avg))s")
    }

    private static func isStrictJSON(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return obj["intent"] != nil && obj["brief"] != nil
    }
}
```

- [ ] **Step 2: Wire into main.swift**

In `Sources/MercurySpike/main.swift`, find the `switch command` block and add a case after `"ping"`:

```swift
            case "jsonMode":
                try await ProbeCommands.jsonMode(client: client, model: args.dropFirst().first ?? "inception/mercury-2")
```

- [ ] **Step 3: Build + run**

Run:
```bash
cd tools/MercurySpike && swift build
swift run mercury-spike jsonMode <slug-from-task-5>
```

Expected output (target — actual numbers will vary):
```
→ jsonMode model=inception/mercury-2 runs=5
  run 1: 1.XXs ✓
  run 2: 1.XXs ✓
  ...
  json valid: 5/5 (100%)
  avg latency: X.XXs
```

If `json valid` is < 5/5: re-run a few times. If consistently below ~4/5, JSON-mode is unreliable for Mercury on OpenRouter — flag this in the findings doc and the spec's risk register. The Selector might need to parse free-form responses with a salvage path (already designed in spec §7).

- [ ] **Step 4: Update findings doc**

Append to `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`:

```markdown
## JSON-mode reliability

Tested via `mercury-spike jsonMode <slug>` (5 runs):

| Slug | Valid JSON | Avg latency |
|---|---|---|
| `inception/<slug>` | X/5 | X.XX s |

**Verdict:** [reliable | sometimes-malformed | unreliable]

**Implication:** [Selector can rely on json_object response_format | Selector needs salvage parser per spec §7]
```

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/MercurySpike/ \
        docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md
git commit -m "Phase 0: jsonMode probe + JSON-mode reliability findings"
```

### Task 7: Latency probe at representative payload sizes

The spec assumes Mercury can hit 2.5s p95 on a 5K-input / 600-output call. Validate.

**Files:**
- Modify: `tools/MercurySpike/Sources/MercurySpike/ProbeCommands.swift`
- Modify: `tools/MercurySpike/Sources/MercurySpike/main.swift`

- [ ] **Step 1: Add latency probe**

Append to `Sources/MercurySpike/ProbeCommands.swift`:

```swift
extension ProbeCommands {
    static func latency(client: OpenRouterClient, model: String, runs: Int = 10) async throws {
        print("→ latency model=\(model) runs=\(runs) (~5K input target)")
        // Build a ~5K-token-ish prompt by padding with realistic context-like JSON
        let fillerJSON = String(repeating: "{\"t\":\"2026-05-16T19:42:11Z\",\"kind\":\"input\",\"app\":\"Slack\",\"text\":\"like this?\"},", count: 60)
        let userPrompt = """
        Recent events from the user:
        [\(fillerJSON.dropLast())]

        Transcript: "send maya the latest draft"

        Return JSON: {"intent": {"verb": string, "target": string, "confidence": number}, "brief": string}
        """

        var latencies: [TimeInterval] = []
        var promptTokens = 0
        var completionTokens = 0
        for i in 1...runs {
            let start = Date()
            let resp = try await client.chatCompletion(request: .init(
                model: model,
                messages: [.init(role: "user", content: userPrompt)],
                responseFormat: .jsonObject,
                maxTokens: 600
            ))
            let elapsed = Date().timeIntervalSince(start)
            latencies.append(elapsed)
            if let u = resp.usage {
                promptTokens = u.promptTokens
                completionTokens = u.completionTokens
            }
            print("  run \(i): \(String(format: "%.2f", elapsed))s")
        }
        latencies.sort()
        let p50 = latencies[latencies.count / 2]
        let p95 = latencies[min(Int(Double(latencies.count) * 0.95), latencies.count - 1)]
        print("  prompt tokens (last run): \(promptTokens)")
        print("  completion tokens (last run): \(completionTokens)")
        print("  p50: \(String(format: "%.2f", p50))s")
        print("  p95: \(String(format: "%.2f", p95))s")
        print("  spec target: p50 ≤ 1.5s, p95 ≤ 2.5s (selector budget)")
    }
}
```

- [ ] **Step 2: Wire into main.swift**

Add a `case "latency":` next to `jsonMode`:

```swift
            case "latency":
                try await ProbeCommands.latency(client: client, model: args.dropFirst().first ?? "inception/mercury-2")
```

Also add `case "all":` that runs all three:

```swift
            case "all":
                let model = args.dropFirst().first ?? "inception/mercury-2"
                try await ProbeCommands.ping(client: client, model: model)
                print()
                try await ProbeCommands.jsonMode(client: client, model: model)
                print()
                try await ProbeCommands.latency(client: client, model: model)
```

- [ ] **Step 3: Build + run**

Run:
```bash
cd tools/MercurySpike && swift build
swift run mercury-spike latency <slug>
```

- [ ] **Step 4: Update findings doc with latency results**

Append to `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`:

```markdown
## Latency at ~5K input / 600 output (n=10)

| Slug | p50 | p95 | tokens (in/out) |
|---|---|---|---|
| `inception/<slug>` | X.XX s | X.XX s | XXXX / XXX |

**Spec targets:** Selector p50 ≤ 1.5s, p95 ≤ 2.5s (per §11)

**Verdict:** [meets | misses by X | misses badly] spec budget

**Implication:** [proceed as designed | budget reduction needed | fallback path will fire often]
```

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/MercurySpike/ \
        docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md
git commit -m "Phase 0: latency probe + findings"
```

### Task 8: Update spec §9 cost/latency table from findings

The spec §9 "Cost & latency napkin" was written from assumptions. Replace with measured numbers.

**Files:**
- Modify: `docs/superpowers/specs/2026-05-16-context-system-redesign-design.md` (§9 block)

- [ ] **Step 1: Read §9 in the spec**

```bash
grep -n "## 9. Cost & latency" docs/superpowers/specs/2026-05-16-context-system-redesign-design.md
```

Note the line numbers. Read the section to recall the current text.

- [ ] **Step 2: Edit §9 to reference measured values**

In the §9 block, after the "End-to-end long-press → harness start" line, append:

```markdown

**Measured values (per `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`):**
- Mercury 2 on OpenRouter (`inception/<slug>`): p50 = X.XXs, p95 = X.XXs at 5K input / 600 output
- JSON-mode reliability: X/5 strict valid (see findings doc for context)
- Verdict: [matches the spec's 1.5s/2.5s selector budget | requires fallback-heavy path | requires model change]
```

Use the actual numbers from your findings doc. If Mercury misses the spec budget badly, also add a paragraph noting that the Selector's hard deadline (currently 2.5s in §7.1) may need to relax — and propagate that to §11 acceptance criteria.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-16-context-system-redesign-design.md
git commit -m "Phase 0: update spec §9 with measured Mercury latency from spike"
```

---

## Section B — Eval harness core

### Task 9: Fixture model

The harness loads fixtures from disk. Each fixture is a directory with `input.json` + `expected.json` + optional `notes.md`.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Fixture.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/FixtureLoadingTests.swift`
- Modify: delete `tools/MercurySpike/Sources/EvalHarness/Placeholder.swift`

- [ ] **Step 1: Write the failing test**

`Tests/EvalHarnessTests/FixtureLoadingTests.swift`:

```swift
import XCTest
@testable import EvalHarness

final class FixtureLoadingTests: XCTestCase {

    func testLoadsFromTempDirectory() throws {
        let tmp = try TempDir()
        let fxDir = tmp.url.appendingPathComponent("scenario-x")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)

        let input = """
        {"transcript": "hello", "current_screen": {"app": "Test"}}
        """
        let expected = """
        {
          "intent": {"verb": "greet", "target": "world"},
          "brief_must_contain": ["hello"],
          "brief_must_not_contain": ["\\\\d{3}\\\\s*,\\\\s*\\\\d{3}"],
          "brief_token_budget": 600
        }
        """
        try input.write(to: fxDir.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
        try expected.write(to: fxDir.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)

        let fixture = try Fixture.load(from: fxDir)
        XCTAssertEqual(fixture.name, "scenario-x")
        let inputAny = try XCTUnwrap(fixture.input as? [String: Any])
        XCTAssertEqual(inputAny["transcript"] as? String, "hello")
        XCTAssertEqual(fixture.expected.brief_must_contain, ["hello"])
        XCTAssertEqual(fixture.expected.brief_must_not_contain, ["\\d{3}\\s*,\\s*\\d{3}"])
        XCTAssertEqual(fixture.expected.brief_token_budget, 600)
        XCTAssertEqual(fixture.expected.intent.verb, "greet")
    }

    func testLoadsMultipleFromDirectory() throws {
        let tmp = try TempDir()
        for name in ["a", "b"] {
            let d = tmp.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "{\"transcript\":\"\(name)\"}".write(to: d.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
            try "{\"intent\":{\"verb\":\"x\"},\"brief_must_contain\":[]}".write(to: d.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)
        }
        let fixtures = try Fixture.loadAll(from: tmp.url)
        XCTAssertEqual(fixtures.map(\.name).sorted(), ["a", "b"])
    }
}

// helper
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("evalharness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter FixtureLoadingTests`
Expected: FAIL (`cannot find 'Fixture' in scope`).

- [ ] **Step 3: Implement Fixture**

Delete placeholder, then create `Sources/EvalHarness/Fixture.swift`:

```swift
import Foundation

public struct Fixture {
    public let name: String
    public let directory: URL
    public let input: Any            // raw JSON object — the selector input payload
    public let inputRaw: Data        // for hashing / replay
    public let expected: Expected
    public let notes: String?

    public struct Expected: Decodable {
        public let intent: IntentExpectation
        public let brief_must_contain: [String]
        public let brief_must_not_contain: [String]?
        public let brief_token_budget: Int?

        public struct IntentExpectation: Decodable {
            public let verb: String
            public let target: String?
            public let resolved_target_contains: String?
            public let entities: [Entity]?

            public struct Entity: Decodable {
                public let label: String
                public let kind: String
            }
        }
    }

    public static func load(from dir: URL) throws -> Fixture {
        let inputURL = dir.appendingPathComponent("input.json")
        let expectedURL = dir.appendingPathComponent("expected.json")
        let notesURL = dir.appendingPathComponent("notes.md")

        let inputRaw = try Data(contentsOf: inputURL)
        let inputAny = try JSONSerialization.jsonObject(with: inputRaw)

        let expectedRaw = try Data(contentsOf: expectedURL)
        let expected = try JSONDecoder().decode(Expected.self, from: expectedRaw)

        let notes = (try? String(contentsOf: notesURL, encoding: .utf8))

        return Fixture(
            name: dir.lastPathComponent,
            directory: dir,
            input: inputAny,
            inputRaw: inputRaw,
            expected: expected,
            notes: notes
        )
    }

    public static func loadAll(from parentDir: URL) throws -> [Fixture] {
        let contents = try FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: [.isDirectoryKey])
        var results: [Fixture] = []
        for child in contents {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            results.append(try Fixture.load(from: child))
        }
        return results.sorted { $0.name < $1.name }
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter FixtureLoadingTests`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Fixture.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/FixtureLoadingTests.swift
git rm tools/MercurySpike/Sources/EvalHarness/Placeholder.swift 2>/dev/null || true
git commit -m "Phase 0: Fixture model + loader"
```

### Task 10: Scorer protocol + ScoreResult

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorer.swift`

- [ ] **Step 1: Define the protocol (no test yet — protocol-only file)**

`Sources/EvalHarness/Scorer.swift`:

```swift
import Foundation

public struct ScoreResult {
    public let scorerName: String
    public let passed: Bool
    public let details: String

    public init(scorerName: String, passed: Bool, details: String) {
        self.scorerName = scorerName
        self.passed = passed
        self.details = details
    }
}

/// A Scorer evaluates a model response against fixture expectations.
public protocol Scorer {
    var name: String { get }
    func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult
}

/// The Selector's structured output. Wraps the raw JSON returned by Mercury.
public struct ModelOutput {
    public let intent: Intent?
    public let brief: String
    public let rawJSON: String   // for grep-style scorers

    public struct Intent: Decodable {
        public let verb: String
        public let target: String?
        public let resolved_target: String?
        public let confidence: Double?
        public let entities: [Entity]?

        public struct Entity: Decodable {
            public let label: String
            public let kind: String
            public let resolved_to: String?
        }
    }

    public init(intent: Intent?, brief: String, rawJSON: String) {
        self.intent = intent
        self.brief = brief
        self.rawJSON = rawJSON
    }

    /// Parse a Mercury response shaped `{"intent": {...}, "brief": "..."}`.
    public static func parse(_ raw: String) throws -> ModelOutput {
        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "ModelOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: "non-utf8"])
        }
        struct Envelope: Decodable {
            let intent: Intent?
            let brief: String?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return ModelOutput(intent: env.intent, brief: env.brief ?? "", rawJSON: raw)
    }
}
```

- [ ] **Step 2: Build**

Run: `cd tools/MercurySpike && swift build`
Expected: builds (no tests for a protocol-only file; scorer-implementation tests cover this transitively).

- [ ] **Step 3: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Scorer.swift
git commit -m "Phase 0: Scorer protocol + ModelOutput"
```

### Task 11: MustContainScorer

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorers/MustContainScorer.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/MustContainScorerTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/EvalHarnessTests/MustContainScorerTests.swift`:

```swift
import XCTest
@testable import EvalHarness

final class MustContainScorerTests: XCTestCase {

    func testPassesWhenAllStringsPresentCaseInsensitive() {
        let output = ModelOutput(intent: nil, brief: "Press CMD+K, type 'maya', return.", rawJSON: "")
        let expected = makeExpected(must: ["cmd+k", "maya", "return"])
        let result = MustContainScorer().score(modelOutput: output, expected: expected)
        XCTAssertTrue(result.passed, result.details)
    }

    func testFailsWhenAnyStringMissing() {
        let output = ModelOutput(intent: nil, brief: "Press CMD+K, type 'maya'.", rawJSON: "")
        let expected = makeExpected(must: ["cmd+k", "maya", "return"])
        let result = MustContainScorer().score(modelOutput: output, expected: expected)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.details.contains("return"), "details should name the missing string")
    }

    func testEmptyMustContainPassesVacuously() {
        let output = ModelOutput(intent: nil, brief: "", rawJSON: "")
        let expected = makeExpected(must: [])
        XCTAssertTrue(MustContainScorer().score(modelOutput: output, expected: expected).passed)
    }

    private func makeExpected(must: [String]) -> Fixture.Expected {
        Fixture.Expected(
            intent: .init(verb: "x", target: nil, resolved_target_contains: nil, entities: nil),
            brief_must_contain: must,
            brief_must_not_contain: nil,
            brief_token_budget: nil
        )
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter MustContainScorerTests`
Expected: FAIL (`cannot find 'MustContainScorer'`).

Note: `Fixture.Expected.init` synthesized by Codable's `init(from:)` isn't usable directly — we need an explicit memberwise init. The test will also fail to compile because of that. Step 3 adds the init.

- [ ] **Step 3: Add memberwise init to Fixture.Expected**

In `Sources/EvalHarness/Fixture.swift`, add a memberwise `public init` to `Fixture.Expected`:

```swift
        public init(
            intent: IntentExpectation,
            brief_must_contain: [String],
            brief_must_not_contain: [String]?,
            brief_token_budget: Int?
        ) {
            self.intent = intent
            self.brief_must_contain = brief_must_contain
            self.brief_must_not_contain = brief_must_not_contain
            self.brief_token_budget = brief_token_budget
        }
```

And to `Fixture.Expected.IntentExpectation`:

```swift
            public init(
                verb: String,
                target: String?,
                resolved_target_contains: String?,
                entities: [Entity]?
            ) {
                self.verb = verb
                self.target = target
                self.resolved_target_contains = resolved_target_contains
                self.entities = entities
            }
```

- [ ] **Step 4: Implement MustContainScorer**

`Sources/EvalHarness/Scorers/MustContainScorer.swift`:

```swift
import Foundation

public struct MustContainScorer: Scorer {
    public let name = "must_contain"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        let needles = expected.brief_must_contain
        let haystack = modelOutput.brief.lowercased()
        let missing = needles.filter { !haystack.contains($0.lowercased()) }
        if missing.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "all \(needles.count) strings present")
        } else {
            return ScoreResult(scorerName: name, passed: false, details: "missing: \(missing.joined(separator: ", "))")
        }
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter MustContainScorerTests`
Expected: all 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Fixture.swift \
        tools/MercurySpike/Sources/EvalHarness/Scorers/MustContainScorer.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/MustContainScorerTests.swift
git commit -m "Phase 0: MustContainScorer + Fixture.Expected memberwise inits"
```

### Task 12: MustNotContainScorer (regex)

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorers/MustNotContainScorer.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/MustNotContainScorerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class MustNotContainScorerTests: XCTestCase {

    func testPassesWhenNoForbiddenPatternMatches() {
        let output = ModelOutput(intent: nil, brief: "Click Send to send the message.", rawJSON: "")
        let expected = makeExpected(forbidden: ["\\d{3}\\s*,\\s*\\d{3}"])
        XCTAssertTrue(MustNotContainScorer().score(modelOutput: output, expected: expected).passed)
    }

    func testFailsWhenForbiddenPatternMatches() {
        let output = ModelOutput(intent: nil, brief: "Click at 847, 612 to send.", rawJSON: "")
        let expected = makeExpected(forbidden: ["\\d{3}\\s*,\\s*\\d{3}"])
        let result = MustNotContainScorer().score(modelOutput: output, expected: expected)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.details.contains("847, 612") || result.details.contains("\\d{3}"), result.details)
    }

    func testNilForbiddenListPassesVacuously() {
        let output = ModelOutput(intent: nil, brief: "anything goes", rawJSON: "")
        let expected = makeExpected(forbidden: nil)
        XCTAssertTrue(MustNotContainScorer().score(modelOutput: output, expected: expected).passed)
    }

    func testInvalidRegexProducesFailDetails() {
        let output = ModelOutput(intent: nil, brief: "x", rawJSON: "")
        let expected = makeExpected(forbidden: ["[unclosed"])
        let r = MustNotContainScorer().score(modelOutput: output, expected: expected)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.details.lowercased().contains("invalid"))
    }

    private func makeExpected(forbidden: [String]?) -> Fixture.Expected {
        Fixture.Expected(
            intent: .init(verb: "x", target: nil, resolved_target_contains: nil, entities: nil),
            brief_must_contain: [],
            brief_must_not_contain: forbidden,
            brief_token_budget: nil
        )
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter MustNotContainScorerTests`
Expected: FAIL (`MustNotContainScorer` missing).

- [ ] **Step 3: Implement scorer**

`Sources/EvalHarness/Scorers/MustNotContainScorer.swift`:

```swift
import Foundation

public struct MustNotContainScorer: Scorer {
    public let name = "must_not_contain"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let patterns = expected.brief_must_not_contain, !patterns.isEmpty else {
            return ScoreResult(scorerName: name, passed: true, details: "no forbidden patterns")
        }
        var matches: [String] = []
        var invalid: [String] = []
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let range = NSRange(modelOutput.brief.startIndex..., in: modelOutput.brief)
                if regex.firstMatch(in: modelOutput.brief, range: range) != nil {
                    matches.append(pattern)
                }
            } catch {
                invalid.append(pattern)
            }
        }
        if !invalid.isEmpty {
            return ScoreResult(scorerName: name, passed: false, details: "invalid regex(es): \(invalid.joined(separator: ", "))")
        }
        if matches.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "none of \(patterns.count) forbidden patterns matched")
        }
        return ScoreResult(scorerName: name, passed: false, details: "forbidden pattern(s) matched: \(matches.joined(separator: ", "))")
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter MustNotContainScorerTests`
Expected: all 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Scorers/MustNotContainScorer.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/MustNotContainScorerTests.swift
git commit -m "Phase 0: MustNotContainScorer (regex)"
```

### Task 13: IntentMatchScorer

Checks intent JSON matches the expected on `verb` (exact), `target` (substring if expected provides one), `resolved_target` (substring), and entity-set membership.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorers/IntentMatchScorer.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/IntentMatchScorerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class IntentMatchScorerTests: XCTestCase {

    func testExactVerbMatchPasses() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: "the draft", resolved_target: nil, confidence: 0.8, entities: nil),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil, entities: nil)
        XCTAssertTrue(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testVerbMismatchFails() {
        let out = ModelOutput(
            intent: .init(verb: "open", target: nil, resolved_target: nil, confidence: nil, entities: nil),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil, entities: nil)
        let r = IntentMatchScorer().score(modelOutput: out, expected: expected)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.details.contains("verb"))
    }

    func testResolvedTargetSubstringMatch() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: "the draft", resolved_target: "Figma file 'Onboarding v3'", confidence: nil, entities: nil),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: "Onboarding v3", entities: nil)
        XCTAssertTrue(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testEntityKindSetMatch() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: nil, resolved_target: nil, confidence: nil,
                          entities: [.init(label: "Maya Chen", kind: "person", resolved_to: "@maya")]),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil,
                                    entities: [("Maya", "person")])
        XCTAssertTrue(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testEntityMissingFails() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: nil, resolved_target: nil, confidence: nil, entities: []),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil,
                                    entities: [("Maya", "person")])
        XCTAssertFalse(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testNoIntentInOutputFails() {
        let out = ModelOutput(intent: nil, brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil, entities: nil)
        XCTAssertFalse(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    // helper
    private func makeExpected(
        verb: String,
        target: String?,
        resolvedContains: String?,
        entities: [(String, String)]?  // (label, kind)
    ) -> Fixture.Expected {
        let ents = entities?.map { Fixture.Expected.IntentExpectation.Entity(label: $0.0, kind: $0.1) }
        return Fixture.Expected(
            intent: .init(verb: verb, target: target, resolved_target_contains: resolvedContains, entities: ents),
            brief_must_contain: [],
            brief_must_not_contain: nil,
            brief_token_budget: nil
        )
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter IntentMatchScorerTests`
Expected: FAIL (`IntentMatchScorer` missing). Also `Fixture.Expected.IntentExpectation.Entity` needs a memberwise init — fix in Step 3.

- [ ] **Step 3: Add memberwise init for Entity**

In `Sources/EvalHarness/Fixture.swift`, add to `Fixture.Expected.IntentExpectation.Entity`:

```swift
                public init(label: String, kind: String) {
                    self.label = label
                    self.kind = kind
                }
```

- [ ] **Step 4: Implement IntentMatchScorer**

`Sources/EvalHarness/Scorers/IntentMatchScorer.swift`:

```swift
import Foundation

public struct IntentMatchScorer: Scorer {
    public let name = "intent_match"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let intent = modelOutput.intent else {
            return ScoreResult(scorerName: name, passed: false, details: "model output has no intent block")
        }
        var failures: [String] = []

        if intent.verb.lowercased() != expected.intent.verb.lowercased() {
            failures.append("verb: got '\(intent.verb)' expected '\(expected.intent.verb)'")
        }
        if let expectedSubstring = expected.intent.resolved_target_contains {
            let actual = (intent.resolved_target ?? "").lowercased()
            if !actual.contains(expectedSubstring.lowercased()) {
                failures.append("resolved_target: '\(intent.resolved_target ?? "<nil>")' does not contain '\(expectedSubstring)'")
            }
        }
        if let expectedEntities = expected.intent.entities {
            let actualLabels = Set((intent.entities ?? []).map { $0.label.lowercased() })
            let expectedLabels = Set(expectedEntities.map { $0.label.lowercased() })
            // require expected ⊆ actual on label substring
            for ex in expectedEntities {
                let found = actualLabels.contains { $0.contains(ex.label.lowercased()) }
                if !found {
                    failures.append("entity '\(ex.label)' (\(ex.kind)) missing from intent.entities")
                }
            }
            _ = expectedLabels  // silence unused warning if any
        }

        if failures.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "intent matches expected")
        }
        return ScoreResult(scorerName: name, passed: false, details: failures.joined(separator: "; "))
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter IntentMatchScorerTests`
Expected: all 6 PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Fixture.swift \
        tools/MercurySpike/Sources/EvalHarness/Scorers/IntentMatchScorer.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/IntentMatchScorerTests.swift
git commit -m "Phase 0: IntentMatchScorer"
```

### Task 14: PixelCoordGrepScorer

A specialized must-not-contain that's always active. Catches `\b\d{2,4}\s*,\s*\d{2,4}\b` (matches `847, 612`) anywhere in the brief.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorers/PixelCoordGrepScorer.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/PixelCoordGrepScorerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class PixelCoordGrepScorerTests: XCTestCase {
    private let expected = Fixture.Expected(
        intent: .init(verb: "x", target: nil, resolved_target_contains: nil, entities: nil),
        brief_must_contain: [], brief_must_not_contain: nil, brief_token_budget: nil
    )

    func testPassesWhenNoPixelCoordsPresent() {
        let out = ModelOutput(intent: nil, brief: "Press cmd+K then type maya.", rawJSON: "")
        XCTAssertTrue(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnObviousPixelCoords() {
        let out = ModelOutput(intent: nil, brief: "Click at 847, 612 to send.", rawJSON: "")
        XCTAssertFalse(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnBracketedCoords() {
        let out = ModelOutput(intent: nil, brief: "Bbox: 100,200,60,28", rawJSON: "")
        XCTAssertFalse(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testAllowsShortNumbersThatArentCoords() {
        // Times, percentages, port numbers, etc. should not trip the pattern unless paired with comma+number
        let out = ModelOutput(intent: nil, brief: "Took 12 seconds. Use port 8080. 5 of 10 done.", rawJSON: "")
        XCTAssertTrue(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter PixelCoordGrepScorerTests`
Expected: FAIL.

- [ ] **Step 3: Implement scorer**

`Sources/EvalHarness/Scorers/PixelCoordGrepScorer.swift`:

```swift
import Foundation

public struct PixelCoordGrepScorer: Scorer {
    public let name = "pixel_coord_grep"
    public init() {}

    // Matches: `847, 612` or `100,200` or `100,200,60,28`
    private static let pattern = "\\b\\d{2,4}\\s*,\\s*\\d{2,4}\\b"

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: Self.pattern) } catch {
            return ScoreResult(scorerName: name, passed: false, details: "internal: bad regex")
        }
        let range = NSRange(modelOutput.brief.startIndex..., in: modelOutput.brief)
        let matches = regex.matches(in: modelOutput.brief, range: range)
        if matches.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "no pixel-coord-shaped substrings")
        }
        let snippets = matches.prefix(3).map { String(modelOutput.brief[Range($0.range, in: modelOutput.brief)!]) }
        return ScoreResult(scorerName: name, passed: false, details: "found pixel-coord-shaped substring(s): \(snippets.joined(separator: ", "))")
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter PixelCoordGrepScorerTests`
Expected: all 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Scorers/PixelCoordGrepScorer.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/PixelCoordGrepScorerTests.swift
git commit -m "Phase 0: PixelCoordGrepScorer"
```

### Task 15: TokenBudgetScorer

Counts approximate tokens (chars/4 heuristic) and checks against `expected.brief_token_budget` if present.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorers/TokenBudgetScorer.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/TokenBudgetScorerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class TokenBudgetScorerTests: XCTestCase {
    func testPassesUnderBudget() {
        let out = ModelOutput(intent: nil, brief: String(repeating: "x", count: 100), rawJSON: "")
        let expected = makeExpected(budget: 600)  // 100/4 = 25 tokens, well under
        XCTAssertTrue(TokenBudgetScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOverBudget() {
        let out = ModelOutput(intent: nil, brief: String(repeating: "x", count: 3000), rawJSON: "")
        let expected = makeExpected(budget: 600)  // 3000/4 = 750 tokens, over
        let r = TokenBudgetScorer().score(modelOutput: out, expected: expected)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.details.contains("budget"))
    }

    func testNoBudgetSetPassesVacuously() {
        let out = ModelOutput(intent: nil, brief: String(repeating: "x", count: 10_000), rawJSON: "")
        let expected = makeExpected(budget: nil)
        XCTAssertTrue(TokenBudgetScorer().score(modelOutput: out, expected: expected).passed)
    }

    private func makeExpected(budget: Int?) -> Fixture.Expected {
        Fixture.Expected(
            intent: .init(verb: "x", target: nil, resolved_target_contains: nil, entities: nil),
            brief_must_contain: [], brief_must_not_contain: nil,
            brief_token_budget: budget
        )
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter TokenBudgetScorerTests`
Expected: FAIL.

- [ ] **Step 3: Implement scorer**

`Sources/EvalHarness/Scorers/TokenBudgetScorer.swift`:

```swift
import Foundation

public struct TokenBudgetScorer: Scorer {
    public let name = "token_budget"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let budget = expected.brief_token_budget else {
            return ScoreResult(scorerName: name, passed: true, details: "no budget set")
        }
        // chars/4 is a rough heuristic; close enough for the soft budget per spec §7.3.
        let approxTokens = (modelOutput.brief.count + 3) / 4
        if approxTokens <= budget {
            return ScoreResult(scorerName: name, passed: true, details: "\(approxTokens) ≤ budget \(budget)")
        }
        return ScoreResult(scorerName: name, passed: false, details: "\(approxTokens) > budget \(budget)")
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter TokenBudgetScorerTests`
Expected: all 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Scorers/TokenBudgetScorer.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/TokenBudgetScorerTests.swift
git commit -m "Phase 0: TokenBudgetScorer"
```

### Task 16: SchemaValidScorer

Checks the raw JSON response decodes into the expected `{intent: {...}, brief: ...}` envelope.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Scorers/SchemaValidScorer.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/SchemaValidScorerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class SchemaValidScorerTests: XCTestCase {
    private let expected = Fixture.Expected(
        intent: .init(verb: "x", target: nil, resolved_target_contains: nil, entities: nil),
        brief_must_contain: [], brief_must_not_contain: nil, brief_token_budget: nil
    )

    func testPassesOnValidEnvelope() {
        let raw = """
        {"intent": {"verb": "send", "target": "draft"}, "brief": "Press cmd+K"}
        """
        let out = ModelOutput(intent: .init(verb: "send", target: "draft", resolved_target: nil, confidence: nil, entities: nil),
                              brief: "Press cmd+K", rawJSON: raw)
        XCTAssertTrue(SchemaValidScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnMissingIntent() {
        let raw = """
        {"brief": "..."}
        """
        let out = ModelOutput(intent: nil, brief: "...", rawJSON: raw)
        XCTAssertFalse(SchemaValidScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnMissingBrief() {
        let raw = """
        {"intent": {"verb": "send"}}
        """
        let out = ModelOutput(intent: .init(verb: "send", target: nil, resolved_target: nil, confidence: nil, entities: nil),
                              brief: "", rawJSON: raw)
        XCTAssertFalse(SchemaValidScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnNonJSON() {
        let raw = "Here is the answer: send the draft."
        let out = ModelOutput(intent: nil, brief: raw, rawJSON: raw)
        XCTAssertFalse(SchemaValidScorer().score(modelOutput: out, expected: expected).passed)
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter SchemaValidScorerTests`
Expected: FAIL.

- [ ] **Step 3: Implement scorer**

`Sources/EvalHarness/Scorers/SchemaValidScorer.swift`:

```swift
import Foundation

public struct SchemaValidScorer: Scorer {
    public let name = "schema_valid"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let data = modelOutput.rawJSON.data(using: .utf8) else {
            return ScoreResult(scorerName: name, passed: false, details: "rawJSON is non-utf8")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScoreResult(scorerName: name, passed: false, details: "rawJSON is not a JSON object")
        }
        guard let intent = obj["intent"] as? [String: Any] else {
            return ScoreResult(scorerName: name, passed: false, details: "missing 'intent' object")
        }
        guard intent["verb"] is String else {
            return ScoreResult(scorerName: name, passed: false, details: "intent.verb missing or not a string")
        }
        guard let brief = obj["brief"] as? String, !brief.isEmpty else {
            return ScoreResult(scorerName: name, passed: false, details: "missing 'brief' string")
        }
        return ScoreResult(scorerName: name, passed: true, details: "valid envelope")
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter SchemaValidScorerTests`
Expected: all 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Scorers/SchemaValidScorer.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/SchemaValidScorerTests.swift
git commit -m "Phase 0: SchemaValidScorer"
```

### Task 17: LLMClientProtocol + MockLLMClient

Mock client replays canned responses keyed by input hash.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/LLMClientProtocol.swift`
- Create: `tools/MercurySpike/Sources/EvalHarness/MockLLMClient.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/MockLLMClientTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class MockLLMClientTests: XCTestCase {

    func testReplaysGoldenForKnownInputHash() async throws {
        let tmp = try TempDir()
        // Create a golden file keyed by SHA256 of the input bytes
        let input = Data("{\"x\":1}".utf8)
        let hash = sha256Hex(input)
        let goldenURL = tmp.url.appendingPathComponent("\(hash).json")
        let golden = """
        {"intent": {"verb": "send"}, "brief": "do the thing"}
        """
        try golden.write(to: goldenURL, atomically: true, encoding: .utf8)

        let client = MockLLMClient(goldensDirectory: tmp.url)
        let raw = try await client.complete(rawInput: input)
        XCTAssertTrue(raw.contains("\"verb\": \"send\""))
        XCTAssertTrue(raw.contains("do the thing"))
    }

    func testThrowsForUnknownInput() async {
        let tmp = try! TempDir()
        let client = MockLLMClient(goldensDirectory: tmp.url)
        do {
            _ = try await client.complete(rawInput: Data("{\"unknown\":true}".utf8))
            XCTFail("expected throw")
        } catch {
            // pass
        }
    }
}

// helper
import CryptoKit
func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter MockLLMClientTests`
Expected: FAIL (`MockLLMClient` missing).

- [ ] **Step 3: Implement protocol + mock**

`Sources/EvalHarness/LLMClientProtocol.swift`:

```swift
import Foundation

public protocol LLMClientProtocol {
    /// Completes a request and returns the raw response text (typically JSON).
    /// `rawInput` is the canonical bytes for the request body — used both as the
    /// HTTP body in live mode and as the hash key in mock mode.
    func complete(rawInput: Data) async throws -> String
}

public enum LLMClientError: Error, CustomStringConvertible {
    case mockMiss(hash: String)
    public var description: String {
        switch self {
        case .mockMiss(let h): return "Mock-LLM has no golden for input hash \(h)"
        }
    }
}
```

`Sources/EvalHarness/MockLLMClient.swift`:

```swift
import Foundation
import CryptoKit

public struct MockLLMClient: LLMClientProtocol {
    public let goldensDirectory: URL

    public init(goldensDirectory: URL) {
        self.goldensDirectory = goldensDirectory
    }

    public func complete(rawInput: Data) async throws -> String {
        let hash = Self.sha256Hex(rawInput)
        let goldenURL = goldensDirectory.appendingPathComponent("\(hash).json")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            throw LLMClientError.mockMiss(hash: hash)
        }
        return try String(contentsOf: goldenURL, encoding: .utf8)
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter MockLLMClientTests`
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/LLMClientProtocol.swift \
        tools/MercurySpike/Sources/EvalHarness/MockLLMClient.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/MockLLMClientTests.swift
git commit -m "Phase 0: LLMClientProtocol + MockLLMClient (sha256-keyed replay)"
```

### Task 18: LiveMercuryClient

Wraps `OpenRouterClient` to satisfy `LLMClientProtocol`.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/LiveMercuryClient.swift`

(No unit test — depends on real network. Integration tested via the runner in Task 24.)

- [ ] **Step 1: Implement**

`Sources/EvalHarness/LiveMercuryClient.swift`:

```swift
import Foundation
import OpenRouterAPI

public struct LiveMercuryClient: LLMClientProtocol {
    public let openRouter: OpenRouterClient
    public let model: String
    public let selectorSystemPrompt: String

    public init(openRouter: OpenRouterClient, model: String, selectorSystemPrompt: String) {
        self.openRouter = openRouter
        self.model = model
        self.selectorSystemPrompt = selectorSystemPrompt
    }

    public func complete(rawInput: Data) async throws -> String {
        let userContent = String(data: rawInput, encoding: .utf8) ?? "<non-utf8>"
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: selectorSystemPrompt),
                .init(role: "user", content: userContent)
            ],
            responseFormat: .jsonObject,
            maxTokens: 1200
        )
        let response = try await openRouter.chatCompletion(request: request)
        return response.choices.first?.message.content ?? ""
    }
}
```

- [ ] **Step 2: Build**

Run: `cd tools/MercurySpike && swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/LiveMercuryClient.swift
git commit -m "Phase 0: LiveMercuryClient adapter"
```

### Task 19: Harness orchestrator

Loads fixtures, runs an `LLMClientProtocol` against each, scores each response with all six scorers, returns a structured result.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalHarness/Harness.swift`
- Create: `tools/MercurySpike/Tests/EvalHarnessTests/HarnessTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import EvalHarness

final class HarnessTests: XCTestCase {

    func testRunsAllScorersOnSingleFixture() async throws {
        let tmp = try TempDir()
        let fxDir = tmp.url.appendingPathComponent("scenario-1")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try "{\"transcript\":\"hi\"}".write(to: fxDir.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
        try """
        {"intent": {"verb": "greet"},
         "brief_must_contain": ["hello"],
         "brief_must_not_contain": ["bbox"],
         "brief_token_budget": 600}
        """.write(to: fxDir.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)

        let mockClient = StubClient(response: """
        {"intent": {"verb": "greet"}, "brief": "say hello to the user"}
        """)
        let harness = Harness(client: mockClient)
        let fixtures = try Fixture.loadAll(from: tmp.url)
        let runResult = try await harness.run(fixtures: fixtures)

        XCTAssertEqual(runResult.fixtureResults.count, 1)
        let scores = runResult.fixtureResults[0].scoreResults
        XCTAssertEqual(scores.count, 6, "expected 6 scorers: \(scores.map(\.scorerName))")
        XCTAssertTrue(scores.allSatisfy { $0.passed }, "all should pass: \(scores.filter{!$0.passed}.map{$0.details})")
    }

    func testReportsFailingScorers() async throws {
        let tmp = try TempDir()
        let fxDir = tmp.url.appendingPathComponent("scenario-fail")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try "{\"x\":1}".write(to: fxDir.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
        try """
        {"intent": {"verb": "send"}, "brief_must_contain": ["this string is not in the response"]}
        """.write(to: fxDir.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)

        let mockClient = StubClient(response: """
        {"intent": {"verb": "open"}, "brief": "different content"}
        """)
        let runResult = try await Harness(client: mockClient).run(fixtures: try Fixture.loadAll(from: tmp.url))
        let fixtureResult = runResult.fixtureResults[0]
        XCTAssertFalse(fixtureResult.allPassed)
        XCTAssertTrue(fixtureResult.scoreResults.contains { $0.scorerName == "must_contain" && !$0.passed })
        XCTAssertTrue(fixtureResult.scoreResults.contains { $0.scorerName == "intent_match" && !$0.passed })
    }
}

// stub client for tests
struct StubClient: LLMClientProtocol {
    let response: String
    func complete(rawInput: Data) async throws -> String { response }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `cd tools/MercurySpike && swift test --filter HarnessTests`
Expected: FAIL.

- [ ] **Step 3: Implement Harness**

`Sources/EvalHarness/Harness.swift`:

```swift
import Foundation

public struct Harness {
    public let client: LLMClientProtocol
    public let scorers: [Scorer]

    public init(client: LLMClientProtocol, scorers: [Scorer]? = nil) {
        self.client = client
        self.scorers = scorers ?? [
            SchemaValidScorer(),
            MustContainScorer(),
            MustNotContainScorer(),
            IntentMatchScorer(),
            PixelCoordGrepScorer(),
            TokenBudgetScorer()
        ]
    }

    public struct FixtureResult {
        public let fixtureName: String
        public let modelOutputRaw: String
        public let latencySeconds: Double
        public let scoreResults: [ScoreResult]
        public var allPassed: Bool { scoreResults.allSatisfy(\.passed) }
    }

    public struct RunResult {
        public let fixtureResults: [FixtureResult]
        public var totalFixtures: Int { fixtureResults.count }
        public var passedFixtures: Int { fixtureResults.filter(\.allPassed).count }
        public var allPassed: Bool { fixtureResults.allSatisfy(\.allPassed) }
    }

    public func run(fixtures: [Fixture]) async throws -> RunResult {
        var results: [FixtureResult] = []
        for fixture in fixtures {
            let start = Date()
            let raw = try await client.complete(rawInput: fixture.inputRaw)
            let elapsed = Date().timeIntervalSince(start)

            let modelOutput: ModelOutput
            do {
                modelOutput = try ModelOutput.parse(raw)
            } catch {
                modelOutput = ModelOutput(intent: nil, brief: "", rawJSON: raw)
            }
            let scoreResults = scorers.map { $0.score(modelOutput: modelOutput, expected: fixture.expected) }
            results.append(FixtureResult(
                fixtureName: fixture.name,
                modelOutputRaw: raw,
                latencySeconds: elapsed,
                scoreResults: scoreResults
            ))
        }
        return RunResult(fixtureResults: results)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd tools/MercurySpike && swift test --filter HarnessTests`
Expected: both PASS. Also run all tests once: `swift test` — everything should be green.

- [ ] **Step 5: Commit**

```bash
git add tools/MercurySpike/Sources/EvalHarness/Harness.swift \
        tools/MercurySpike/Tests/EvalHarnessTests/HarnessTests.swift
git commit -m "Phase 0: Harness orchestrator with all 6 scorers"
```

### Task 20: EvalRunner CLI

Wires Fixture loading → MockLLMClient or LiveMercuryClient → Harness → console output.

**Files:**
- Create: `tools/MercurySpike/Sources/EvalRunner/EvalRunnerCLI.swift`
- Create: `tools/MercurySpike/Sources/EvalRunner/RunnerCommands.swift`
- Modify: delete `tools/MercurySpike/Sources/EvalRunner/Placeholder.swift`

- [ ] **Step 1: Implement CLI**

`Sources/EvalRunner/EvalRunnerCLI.swift` (NOT `main.swift`):

```swift
import Foundation
import EvalHarness
import OpenRouterAPI

@main
struct EvalRunnerCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"

        do {
            switch command {
            case "mock":
                try await RunnerCommands.mock()
            case "live":
                try await RunnerCommands.live()
            case "list":
                try RunnerCommands.list()
            case "help", "--help", "-h":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                printUsage()
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage: eval-runner <command>

        Commands:
          mock       Run all selector fixtures through MockLLMClient (no network)
          live       Run all selector fixtures through LiveMercuryClient (OpenRouter)
          list       List discovered fixtures
        """)
    }
}
```

`Sources/EvalRunner/RunnerCommands.swift`:

```swift
import Foundation
import EvalHarness
import OpenRouterAPI

enum RunnerCommands {

    static func selectorFixtureDir() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/eval/fixtures/selector")
    }

    static func selectorGoldensDir() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/eval/goldens/selector")
    }

    static func list() throws {
        let dir = selectorFixtureDir()
        let fixtures = try Fixture.loadAll(from: dir)
        print("\(fixtures.count) selector fixture(s) under \(dir.path):")
        for f in fixtures { print("  - \(f.name)") }
    }

    static func mock() async throws {
        let fixturesDir = selectorFixtureDir()
        let goldensRoot = selectorGoldensDir()
        let fixtures = try Fixture.loadAll(from: fixturesDir)
        print("Mock-LLM mode: \(fixtures.count) fixture(s)\n")

        // One MockLLMClient per fixture (each has its own goldens dir).
        // Run each separately, then print one aggregated summary.
        var passedCount = 0
        for fixture in fixtures {
            let goldenForFixture = goldensRoot.appendingPathComponent(fixture.name)
            let client = MockLLMClient(goldensDirectory: goldenForFixture)
            let result = try await Harness(client: client).run(fixtures: [fixture])
            printResult(result, includeSummary: false)
            passedCount += result.passedFixtures
        }
        print("\nTotal: \(passedCount)/\(fixtures.count) passed")
        if passedCount != fixtures.count { exit(1) }
    }

    static func live() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        let model = ProcessInfo.processInfo.environment["MERCURY_MODEL"] ?? "inception/mercury-2"
        let systemPrompt = SelectorSystemPrompt.text

        let liveClient = LiveMercuryClient(
            openRouter: OpenRouterClient(apiKey: apiKey),
            model: model,
            selectorSystemPrompt: systemPrompt
        )
        let fixtures = try Fixture.loadAll(from: selectorFixtureDir())
        print("Live-Mercury mode (model=\(model)): \(fixtures.count) fixture(s)\n")
        let result = try await Harness(client: liveClient).run(fixtures: fixtures)
        printResult(result, includeSummary: true)

        let resultsDir = URL(fileURLWithPath: "tests/eval/results")
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        try writeResultsJSON(result, to: resultsDir.appendingPathComponent("results.json"))
        print("Results written to \(resultsDir.path)")

        if !result.allPassed { exit(1) }
    }

    private static func printResult(_ result: Harness.RunResult, includeSummary: Bool) {
        for fr in result.fixtureResults {
            let status = fr.allPassed ? "PASS" : "FAIL"
            print("[\(status)] \(fr.fixtureName)  (\(String(format: "%.2f", fr.latencySeconds))s)")
            for s in fr.scoreResults {
                let mark = s.passed ? "  ✓" : "  ✗"
                print("\(mark) \(s.scorerName): \(s.details)")
            }
        }
        if includeSummary {
            print("\nTotal: \(result.passedFixtures)/\(result.totalFixtures) passed")
        }
    }

    private static func writeResultsJSON(_ result: Harness.RunResult, to url: URL) throws {
        // Simple flattened JSON for diffing across runs.
        var rows: [[String: Any]] = []
        for fr in result.fixtureResults {
            for s in fr.scoreResults {
                rows.append([
                    "fixture": fr.fixtureName,
                    "scorer": s.scorerName,
                    "passed": s.passed,
                    "details": s.details,
                    "latency_s": fr.latencySeconds
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
        try data.write(to: url)
    }
}

/// The Selector's system prompt — kept here as a Swift string for now;
/// when production Selector.swift exists in Phase 4, it imports from here.
enum SelectorSystemPrompt {
    static let text = """
    You are the context selector for an on-screen macOS computer-use agent.

    You receive a single JSON payload with: a voice transcript, the current screen
    snapshot (AX elements, OCR, selection, clipboard, app-specific data), the user's
    preferences, the user's active task and recent activity, and per-app operational
    recipes the agent can use.

    Your job is two things in one call:

    (1) RESOLVE INTENT. Output {verb, target, resolved_target?, entities, confidence}.
        Use active_task, recent_events, recent_resources, and clipboard to resolve
        deictic references — "the draft", "her", "that PR", "this". Be specific. If
        you cannot resolve a reference with high confidence, leave resolved_target
        null and set confidence accordingly.

    (2) WRITE THE BRIEF. A markdown briefing for the computer-use agent, ≤600 tokens,
        structured per the template below. The agent has these tools, in preference
        order: open_url > applescript > run_shortcut > ax_query+ax_press >
        menu_shortcut > computer (vision+click). ALWAYS lead with anchors above
        "computer". Never include pixel coordinates — they are not reliable across
        turns.

    Brief template (omit any section with nothing concrete to say):

    ## What the user wants
    <one sentence with resolved references>

    ## You are here
    - App, window, focused element (AX path)
    - Useful AX paths on this screen (≤5, role+label+ax_path)
    - Active selection or recent clipboard if relevant

    ## How to do it on <app>
    <ordered steps, leading with the fastest tool — shortcut, url, menu, applescript>

    ## What "<deictic>" means
    <one entry per pronoun/reference that resolved to a specific resource>

    ## Watch out for
    <only if there's a real, evidenced gotcha>

    Rules:
    - Coordinate-free. Anchors only.
    - Never invent recipes, AX paths, or resources. If you don't have it, say
      "you'll need to look" and let the agent screenshot.
    - Stay under 600 tokens. Density over completeness.

    Return strictly one JSON object: { "intent": {...}, "brief": "..." }.
    """
}
```

- [ ] **Step 2: Delete placeholder, build**

Run:
```bash
rm tools/MercurySpike/Sources/EvalRunner/Placeholder.swift
cd tools/MercurySpike && swift build
```
Expected: builds.

- [ ] **Step 3: Verify CLI usage**

Run from the repo root (one level above `tools/MercurySpike/`):
```bash
cd /Users/arshan/Desktop/tritonhacks2026
cd tools/MercurySpike && swift run eval-runner help
```

Expected: usage message prints.

- [ ] **Step 4: Commit**

```bash
git add tools/MercurySpike/Sources/EvalRunner/EvalRunnerCLI.swift \
        tools/MercurySpike/Sources/EvalRunner/RunnerCommands.swift
git rm tools/MercurySpike/Sources/EvalRunner/Placeholder.swift 2>/dev/null || true
git commit -m "Phase 0: EvalRunner CLI (mock + live + list)"
```

---

## Section C — First three selector fixtures

### Task 21: Create fixture directory scaffolding

**Files:**
- Create: `tests/eval/README.md`
- Create: `tests/eval/fixtures/.gitkeep`
- Create: `tests/eval/goldens/.gitkeep`
- Create: `tests/eval/results/.gitkeep`
- Modify: `.gitignore`

- [ ] **Step 1: Create directories**

Run:
```bash
cd /Users/arshan/Desktop/tritonhacks2026
mkdir -p tests/eval/fixtures/selector tests/eval/goldens/selector tests/eval/results
touch tests/eval/fixtures/.gitkeep tests/eval/goldens/.gitkeep tests/eval/results/.gitkeep
```

- [ ] **Step 2: Add gitignore entry for results**

Append to `/Users/arshan/Desktop/tritonhacks2026/.gitignore`:

```
# Eval harness runtime outputs
tests/eval/results/*
!tests/eval/results/.gitkeep
tools/MercurySpike/.build/
tools/MercurySpike/.swiftpm/
tools/MercurySpike/Package.resolved
```

(Confirm `.gitignore` exists at repo root first via `ls -la .gitignore`. If it doesn't, create it with the lines above.)

- [ ] **Step 3: Write README**

`tests/eval/README.md`:

````markdown
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

````

- [ ] **Step 4: Commit**

```bash
cd /Users/arshan/Desktop/tritonhacks2026
git add tests/eval/ .gitignore
git commit -m "Phase 0: scaffold tests/eval/ with README + gitignore"
```

### Task 22: Fixture A — Slack DM with person (input + expected + notes)

**Files:**
- Create: `tests/eval/fixtures/selector/scenario-A-slack-dm-with-person/input.json`
- Create: `tests/eval/fixtures/selector/scenario-A-slack-dm-with-person/expected.json`
- Create: `tests/eval/fixtures/selector/scenario-A-slack-dm-with-person/notes.md`

- [ ] **Step 1: Write `input.json`**

```json
{
  "transcript": "send maya the latest draft",
  "current_screen": {
    "app": "Slack",
    "bundle_id": "com.tinyspeck.slackmacgap",
    "pid": 6234,
    "window_title": "design — Studio HQ",
    "window_id": 142,
    "display_id": 1,
    "display_bounds": [0, 0, 1728, 1117],
    "captured_at": "2026-05-16T19:42:11Z",
    "ocr_lines": ["#design", "Maya Chen 2:34 PM", "love the step 1 copy!", "Message #design"],
    "ax_elements": [
      {"role": "AXTextArea", "label": "Message #design", "ax_path": "AXWindow/AXGroup[1]/AXTextArea", "focused": true},
      {"role": "AXButton", "label": "Send", "ax_path": "AXWindow/AXGroup[2]/AXButton[Send]", "focused": false},
      {"role": "AXButton", "label": "Open files", "ax_path": "AXWindow/AXGroup[2]/AXButton[Open files]", "focused": false}
    ],
    "cursor": [612, 590],
    "selection": null,
    "clipboard": {
      "kind": "text",
      "preview": "https://figma.com/file/abc/Onboarding-v3",
      "bytes": 47,
      "age_s": 12,
      "source_app": "Figma",
      "source_bundle_id": "com.figma.Desktop"
    },
    "app_specific": {
      "workspace": "Studio HQ",
      "channel": "#design",
      "channel_kind": "channel",
      "participants": ["maya", "wyatt", "arshan"]
    }
  },
  "user_prefs": "I use Arc for browsing. Prefer concise messages.",
  "active_task": {
    "id": "t_2026-05-16_19",
    "started_at": "2026-05-16T19:02:00Z",
    "label": "Iterate onboarding v3 in Figma + coordinate with Maya",
    "kind": "design_iteration",
    "narrative": "User has been iterating on Figma's 'Onboarding v3' for 40 min, bouncing to Slack #design to discuss with Maya.",
    "actions_taken": [
      {"t": "2026-05-16T19:34:00Z", "what": "edited verify code instruction text"}
    ],
    "resources": [
      "figma://file/abc/Onboarding-v3#frame:Step-2",
      "slack://channel/T123/C456?ts=1747422120"
    ],
    "entities": [
      {"label": "Maya Chen", "kind": "person", "slack_handle": "@maya"},
      {"label": "Onboarding v3", "kind": "file", "uri": "figma://file/abc/Onboarding-v3"},
      {"label": "#design", "kind": "channel", "uri": "slack://channel/T123/C456"}
    ],
    "blocked_on": null,
    "likely_next_steps": ["apply Maya's copy suggestion", "post updated screenshot"]
  },
  "recent_events": [
    {"t": "2026-05-16T19:38:42Z", "kind": "screen", "app": "Figma", "surface": "Onboarding v3 / Step 2"},
    {"t": "2026-05-16T19:39:10Z", "kind": "screen", "app": "Slack", "surface": "#design"},
    {"t": "2026-05-16T19:39:18Z", "kind": "input", "app": "Slack", "text": "asking maya about copy", "context": "drafting message"}
  ],
  "recent_resources": [
    {"kind": "url", "uri": "https://figma.com/file/abc/Onboarding-v3", "label": "Onboarding v3", "app": "Figma", "last_seen": "2026-05-16T19:34:00Z"},
    {"kind": "channel", "uri": "slack://channel/T123/C456", "label": "#design", "app": "Slack", "last_seen": "2026-05-16T19:39:10Z"}
  ],
  "recipes_for_active_app": [
    {
      "name": "open DM with person",
      "trigger_pattern": "open DM | message <person> | DM <person>",
      "steps": [
        {"kind": "shortcut", "keys": "cmd+k"},
        {"kind": "type", "value": "<person.name>"},
        {"kind": "key", "keys": "return"}
      ],
      "seen_count": 7,
      "confidence": 0.92
    },
    {
      "name": "post in current channel",
      "trigger_pattern": "post in channel | send in channel",
      "steps": [
        {"kind": "type", "value": "<message>"},
        {"kind": "key", "keys": "return"}
      ],
      "seen_count": 12,
      "confidence": 0.95
    }
  ]
}
```

- [ ] **Step 2: Write `expected.json`**

```json
{
  "intent": {
    "verb": "send",
    "target": "the latest draft",
    "resolved_target_contains": "Onboarding v3",
    "entities": [
      {"label": "Maya", "kind": "person"}
    ]
  },
  "brief_must_contain": ["cmd+K", "maya", "return", "figma.com/file/abc/Onboarding-v3"],
  "brief_must_not_contain": ["\\b\\d{3}\\s*,\\s*\\d{3}\\b", "AXButton.*\\d+,\\s*\\d+"],
  "brief_token_budget": 600
}
```

- [ ] **Step 3: Write `notes.md`**

```markdown
# Scenario A — Send Slack DM with person from L5

**Tests:**
- Resolution of "the latest draft" → the Figma file in active_task.resources
- Resolution of "maya" → the person entity in active_task.entities
- Use of L3 recipe "open DM with person" (seen_count 7) to lead the brief
- Use of recent clipboard URL (12s old) as the message body
- No pixel coordinates

**Setup:** User is in Slack #design channel composer (not yet in a DM). Maya is in
participants list and in active_task.entities. The Figma URL is in clipboard
(just copied) and in recent_resources. Mercury must:
1. Recognize "send" as the verb and resolve "the latest draft" to the Figma file
2. Suggest opening DM with Maya first (cmd+K → "maya" → return) since we're in a channel
3. Then paste the URL (or use it directly from recent_resources)
```

- [ ] **Step 4: Commit**

```bash
cd /Users/arshan/Desktop/tritonhacks2026
git add tests/eval/fixtures/selector/scenario-A-slack-dm-with-person/
git commit -m "Phase 0: fixture A — send Slack DM with person from L5"
```

### Task 23: Fixture B — Arc open PR from recent_resources

**Files:**
- Create: `tests/eval/fixtures/selector/scenario-B-arc-open-PR/input.json`
- Create: `tests/eval/fixtures/selector/scenario-B-arc-open-PR/expected.json`
- Create: `tests/eval/fixtures/selector/scenario-B-arc-open-PR/notes.md`

- [ ] **Step 1: Write `input.json`**

```json
{
  "transcript": "open the PR",
  "current_screen": {
    "app": "Arc",
    "bundle_id": "company.thebrowser.Browser",
    "pid": 8120,
    "window_title": "GitHub — github.com",
    "window_id": 301,
    "display_id": 1,
    "display_bounds": [0, 0, 1728, 1117],
    "captured_at": "2026-05-16T20:11:03Z",
    "ocr_lines": ["Pull requests", "Issues", "Marketplace", "Explore"],
    "ax_elements": [
      {"role": "AXTextField", "label": "Search", "ax_path": "AXWindow/AXGroup/AXTextField[Search]", "focused": false}
    ],
    "cursor": [800, 200],
    "selection": null,
    "clipboard": null,
    "app_specific": {
      "active_url": "https://github.com/co/repo",
      "active_title": "co / repo",
      "tabs": [
        {"title": "co / repo", "url": "https://github.com/co/repo", "active": true},
        {"title": "PR #1342 · Add streaming TTS", "url": "https://github.com/co/repo/pull/1342", "active": false}
      ],
      "profile": "Work"
    }
  },
  "user_prefs": "I use Arc for browsing.",
  "active_task": {
    "id": "t_2026-05-16_20",
    "started_at": "2026-05-16T19:50:00Z",
    "label": "Review PR #1342 for streaming TTS",
    "kind": "code_review",
    "narrative": "User merged PR #1342 'Add streaming TTS' 30 min ago and has been periodically checking GitHub for follow-up comments.",
    "actions_taken": [
      {"t": "2026-05-16T19:50:00Z", "what": "opened PR #1342 in Arc"},
      {"t": "2026-05-16T19:55:00Z", "what": "merged PR #1342"}
    ],
    "resources": [
      "https://github.com/co/repo/pull/1342"
    ],
    "entities": [
      {"label": "PR #1342", "kind": "url", "uri": "https://github.com/co/repo/pull/1342"}
    ],
    "blocked_on": null,
    "likely_next_steps": ["check for review comments", "merge follow-up PR"]
  },
  "recent_events": [
    {"t": "2026-05-16T20:05:00Z", "kind": "app_switch", "from_bundle": "com.todesktop.230313mzl4w4u92", "to_bundle": "company.thebrowser.Browser"},
    {"t": "2026-05-16T20:10:00Z", "kind": "screen", "app": "Arc", "surface": "github.com home"}
  ],
  "recent_resources": [
    {"kind": "url", "uri": "https://github.com/co/repo/pull/1342", "label": "PR #1342", "app": "GitHub", "last_seen": "2026-05-16T19:55:00Z"},
    {"kind": "url", "uri": "https://github.com/co/repo", "label": "co/repo", "app": "GitHub", "last_seen": "2026-05-16T20:11:03Z"}
  ],
  "recipes_for_active_app": [
    {
      "name": "switch to existing tab",
      "trigger_pattern": "go to tab | switch to tab | open tab",
      "steps": [
        {"kind": "shortcut", "keys": "cmd+t"},
        {"kind": "type", "value": "<query>"},
        {"kind": "key", "keys": "return"}
      ],
      "seen_count": 5,
      "confidence": 0.85
    }
  ]
}
```

- [ ] **Step 2: Write `expected.json`**

```json
{
  "intent": {
    "verb": "open",
    "target": "the PR",
    "resolved_target_contains": "https://github.com/co/repo/pull/1342",
    "entities": [
      {"label": "PR #1342", "kind": "url"}
    ]
  },
  "brief_must_contain": ["https://github.com/co/repo/pull/1342"],
  "brief_must_not_contain": ["\\b\\d{3}\\s*,\\s*\\d{3}\\b"],
  "brief_token_budget": 600
}
```

- [ ] **Step 3: Write `notes.md`**

```markdown
# Scenario B — Arc, open PR from recent_resources

**Tests:**
- Resolution of "the PR" → the GitHub URL in active_task.resources / recent_resources
- Brief leads with `open_url` (the fastest tool) rather than tab-switching navigation
- Active app is a browser → app_specific.tabs includes the PR as an inactive tab; either navigating to it or switching tabs would work, but `open_url` is preferred

**Setup:** User is on GitHub home in Arc. PR #1342 is one of their tabs and also
in active_task.resources + recent_resources. Mercury must:
1. Resolve "the PR" → the URL
2. Suggest `open_url https://github.com/co/repo/pull/1342` as step 1
3. Optionally mention the tab-switch alternative
```

- [ ] **Step 4: Commit**

```bash
cd /Users/arshan/Desktop/tritonhacks2026
git add tests/eval/fixtures/selector/scenario-B-arc-open-PR/
git commit -m "Phase 0: fixture B — Arc open PR from recent_resources"
```

### Task 24: Fixture C — iTerm run tests with cwd context

**Files:**
- Create: `tests/eval/fixtures/selector/scenario-C-iterm-run-tests/input.json`
- Create: `tests/eval/fixtures/selector/scenario-C-iterm-run-tests/expected.json`
- Create: `tests/eval/fixtures/selector/scenario-C-iterm-run-tests/notes.md`

- [ ] **Step 1: Write `input.json`**

```json
{
  "transcript": "run the tests",
  "current_screen": {
    "app": "iTerm2",
    "bundle_id": "com.googlecode.iterm2",
    "pid": 5510,
    "window_title": "tritonhacks2026 — zsh — 120×40",
    "window_id": 88,
    "display_id": 1,
    "display_bounds": [0, 0, 1728, 1117],
    "captured_at": "2026-05-16T21:02:00Z",
    "ocr_lines": ["arshan@MBP tritonhacks2026 % git status", "On branch main", "nothing to commit, working tree clean", "arshan@MBP tritonhacks2026 %"],
    "ax_elements": [
      {"role": "AXTextArea", "label": "Terminal", "ax_path": "AXWindow/AXScrollArea/AXTextArea", "focused": true}
    ],
    "cursor": [120, 600],
    "selection": null,
    "clipboard": null,
    "app_specific": {
      "cwd": "/Users/arshan/Desktop/tritonhacks2026",
      "git_branch": "main",
      "git_dirty": false,
      "shell": "zsh",
      "recent_commands": ["git status", "ls", "git log --oneline -5"],
      "ssh_host": null
    }
  },
  "user_prefs": "",
  "active_task": {
    "id": "t_2026-05-16_21",
    "started_at": "2026-05-16T20:55:00Z",
    "label": "Work on context system redesign",
    "kind": "coding",
    "narrative": "User is working in the tritonhacks2026 repo on the AgentNotch context redesign. Recent activity in iTerm: git status checks.",
    "actions_taken": [
      {"t": "2026-05-16T21:00:00Z", "what": "ran git status in tritonhacks2026"}
    ],
    "resources": [
      "/Users/arshan/Desktop/tritonhacks2026"
    ],
    "entities": [
      {"label": "tritonhacks2026", "kind": "cwd", "uri": "/Users/arshan/Desktop/tritonhacks2026"}
    ],
    "blocked_on": null,
    "likely_next_steps": ["edit context files", "run tests"]
  },
  "recent_events": [
    {"t": "2026-05-16T21:00:00Z", "kind": "input", "app": "iTerm2", "text": "git status", "context": "shell command"},
    {"t": "2026-05-16T21:01:30Z", "kind": "screen", "app": "iTerm2", "surface": "git status output"}
  ],
  "recent_resources": [
    {"kind": "cwd", "uri": "/Users/arshan/Desktop/tritonhacks2026", "label": "tritonhacks2026", "app": "iTerm2", "last_seen": "2026-05-16T21:01:30Z"}
  ],
  "recipes_for_active_app": [
    {
      "name": "run swift package tests",
      "trigger_pattern": "run tests | swift test | run unit tests",
      "steps": [
        {"kind": "shell_cmd", "value": "swift test", "needs_cwd": "<cwd>"}
      ],
      "seen_count": 4,
      "confidence": 0.80
    }
  ]
}
```

- [ ] **Step 2: Write `expected.json`**

```json
{
  "intent": {
    "verb": "run",
    "target": "the tests",
    "resolved_target_contains": "tritonhacks2026"
  },
  "brief_must_contain": ["swift test", "tritonhacks2026"],
  "brief_must_not_contain": ["\\b\\d{3}\\s*,\\s*\\d{3}\\b"],
  "brief_token_budget": 600
}
```

- [ ] **Step 3: Write `notes.md`**

```markdown
# Scenario C — iTerm run tests with cwd context

**Tests:**
- Use of TerminalAdapter `cwd` from `app_specific` to scope the shell command
- L3 recipe `run swift package tests` matches and is rendered as a `shell_cmd` step
- Brief mentions both the command and the cwd (so the agent knows where to run it)
- No pixel coordinates

**Setup:** User is in iTerm in the project root. Recent commands show git activity.
There's an L3 recipe for `swift test`. Mercury must:
1. Resolve "the tests" → swift test in the current cwd
2. Suggest `swift test` as the shell_cmd, scoped to /Users/arshan/Desktop/tritonhacks2026
```

- [ ] **Step 4: Commit**

```bash
cd /Users/arshan/Desktop/tritonhacks2026
git add tests/eval/fixtures/selector/scenario-C-iterm-run-tests/
git commit -m "Phase 0: fixture C — iTerm run tests with cwd context"
```

### Task 25: Hand-curated goldens for Mock-LLM mode

For each fixture, write the SHA256 of the `input.json` bytes and create a hand-curated ideal response under `goldens/selector/<scenario>/<sha256>.json`.

**Files:**
- Create: `tests/eval/goldens/selector/scenario-A-slack-dm-with-person/<hash>.json`
- Create: `tests/eval/goldens/selector/scenario-B-arc-open-PR/<hash>.json`
- Create: `tests/eval/goldens/selector/scenario-C-iterm-run-tests/<hash>.json`

- [ ] **Step 1: Compute SHA256 for each input.json**

Run from the repo root:
```bash
cd /Users/arshan/Desktop/tritonhacks2026
for d in tests/eval/fixtures/selector/*/; do
  name=$(basename "$d")
  hash=$(shasum -a 256 "$d/input.json" | awk '{print $1}')
  echo "$name -> $hash"
done
```

Note each hash. (Important: the hash is over the file *bytes as written*, including trailing newlines. If your editor strips/adds them, re-run after saving.)

- [ ] **Step 2: Write golden for fixture A**

Create `tests/eval/goldens/selector/scenario-A-slack-dm-with-person/<hash-A>.json` (replace `<hash-A>` with the actual hash from Step 1):

```json
{
  "intent": {
    "verb": "send",
    "target": "the latest draft",
    "resolved_target": "Figma file 'Onboarding v3' (currently being edited)",
    "entities": [
      {"label": "Maya Chen", "kind": "person", "resolved_to": "@maya in Slack"},
      {"label": "Onboarding v3", "kind": "file", "resolved_to": "https://figma.com/file/abc/Onboarding-v3"}
    ],
    "confidence": 0.88
  },
  "brief": "## What the user wants\nSend Maya the Figma file 'Onboarding v3' (the file the user has been editing for the last 40 min) via Slack DM.\n\n## You are here\n- App: Slack — channel #design composer\n- Focused: AXTextArea[Message #design] (empty)\n- Useful AX paths:\n  - AXTextArea[Message #design]\n  - AXButton[Send]\n- Recent clipboard (12s old): URL https://figma.com/file/abc/Onboarding-v3\n\n## How to do it on Slack\nYou're in a channel, not a DM. Switch to DM with Maya first, then send.\n\n1. **Open DM with Maya** — `cmd+K`, type `maya`, `return`. (User has done this 7× in the last hour — high confidence.)\n2. **Send the link** — `cmd+v` (URL already on clipboard), then `return`. If clipboard has changed, the URL is also in recent_resources: `https://figma.com/file/abc/Onboarding-v3`.\n\n## What \"the latest draft\" means\nThe Figma file 'Onboarding v3'. The user last edited 'Step 2 — verify email' 4 min ago.\n\n## What \"maya\" means\nSlack user @maya — appears as a participant in #design and is referenced in active_task entities."
}
```

- [ ] **Step 3: Write golden for fixture B**

Create `tests/eval/goldens/selector/scenario-B-arc-open-PR/<hash-B>.json`:

```json
{
  "intent": {
    "verb": "open",
    "target": "the PR",
    "resolved_target": "https://github.com/co/repo/pull/1342 (PR #1342, currently in active_task)",
    "entities": [
      {"label": "PR #1342", "kind": "url", "resolved_to": "https://github.com/co/repo/pull/1342"}
    ],
    "confidence": 0.95
  },
  "brief": "## What the user wants\nOpen pull request #1342 ('Add streaming TTS') in the current browser.\n\n## You are here\n- App: Arc — GitHub homepage tab\n- Other tab open: 'PR #1342 · Add streaming TTS' at https://github.com/co/repo/pull/1342\n\n## How to do it on Arc\nThe PR URL is known — use the fastest tool:\n\n1. **open_url** `https://github.com/co/repo/pull/1342`. This will navigate the current tab.\n2. (Alternative) Switch to the existing PR tab via `cmd+T`, type `1342`, `return`. (Recipe 'switch to existing tab' has seen_count 5.)\n\n## What \"the PR\" means\nPull request #1342 on github.com/co/repo — currently in active_task.resources and was last seen 30 min ago when the user merged it."
}
```

- [ ] **Step 4: Write golden for fixture C**

Create `tests/eval/goldens/selector/scenario-C-iterm-run-tests/<hash-C>.json`:

```json
{
  "intent": {
    "verb": "run",
    "target": "the tests",
    "resolved_target": "swift test in /Users/arshan/Desktop/tritonhacks2026",
    "entities": [
      {"label": "tritonhacks2026", "kind": "cwd", "resolved_to": "/Users/arshan/Desktop/tritonhacks2026"}
    ],
    "confidence": 0.90
  },
  "brief": "## What the user wants\nRun the Swift package tests in the current iTerm working directory (the tritonhacks2026 repo).\n\n## You are here\n- App: iTerm2\n- cwd: /Users/arshan/Desktop/tritonhacks2026\n- git_branch: main (clean)\n- Recent commands: git status, ls, git log --oneline -5\n\n## How to do it on iTerm2\n1. **Run** `swift test` in the current shell (focused terminal). Recipe 'run swift package tests' (seen_count 4) matches; no need to cd — already in /Users/arshan/Desktop/tritonhacks2026.\n\n## What \"the tests\" means\nThe Swift package tests in /Users/arshan/Desktop/tritonhacks2026, invoked via `swift test` (the recipe the user has used 4 previous times in this cwd)."
}
```

- [ ] **Step 5: Commit**

```bash
cd /Users/arshan/Desktop/tritonhacks2026
git add tests/eval/goldens/
git commit -m "Phase 0: hand-curated Mock-LLM goldens for fixtures A/B/C"
```

---

## Section D — End-to-end validation

### Task 26: Validate Mock-LLM mode passes all fixtures

- [ ] **Step 1: Run mock mode**

Run from repo root:
```bash
cd /Users/arshan/Desktop/tritonhacks2026/tools/MercurySpike
swift run eval-runner mock
```

Expected: all three fixtures `[PASS]`, all six scorers per fixture `✓`. Output ends `Total: 3/3 passed`.

If any scorer fails:
- `must_contain` failure → either revise the golden to include the missing string, or revise `expected.json` to drop a string that doesn't make sense in the brief
- `must_not_contain` / `pixel_coord_grep` failure → strip the offending coords from the golden
- `intent_match` failure → revise the golden's `intent` block to match the expected shape exactly
- `schema_valid` failure → the golden isn't a valid `{intent, brief}` envelope; fix it
- `token_budget` failure → trim the golden's brief

After fix, re-run. Iterate until clean.

- [ ] **Step 2: Commit any golden fixes**

If you edited goldens, commit them:

```bash
git add tests/eval/goldens/
git commit -m "Phase 0: tighten goldens until Mock-LLM scorers all green"
```

If no edits needed, skip.

### Task 27: Run Live-Mercury mode and capture results

- [ ] **Step 1: Ensure environment is set**

Run:
```bash
echo "OPENROUTER_API_KEY length: ${#OPENROUTER_API_KEY}"
echo "MERCURY_MODEL: ${MERCURY_MODEL:-inception/mercury-2}"
```

Both should print something nonempty (`MERCURY_MODEL` falls back to a default — set it to the slug confirmed in Task 5/6 if different).

- [ ] **Step 2: Run live mode**

```bash
cd /Users/arshan/Desktop/tritonhacks2026/tools/MercurySpike
swift run eval-runner live
```

Expected: results print for each fixture (PASS/FAIL per scorer), and the run is dumped to `tests/eval/results/<timestamp>/results.json`. Note the per-fixture latencies.

Some scorers may fail — that's exactly the point. Mercury isn't tuned to this prompt yet. The signals to watch:
- `schema_valid` failures → Mercury isn't returning valid `{intent, brief}` JSON reliably. Tighten the system prompt in `Sources/EvalRunner/RunnerCommands.swift:SelectorSystemPrompt.text`. Re-run.
- `intent_match` failures → Mercury picked a different verb or didn't resolve the entity. Either the system prompt needs to be more explicit, or the expected criteria are too strict. Iterate.
- `must_contain` failures → Mercury wrote the right idea but used different phrasing. Loosen `must_contain` to the essential anchors (shortcuts, URLs) rather than full phrases.
- `pixel_coord_grep` failures → Mercury hallucinated coords from the AX bboxes. Strengthen the system prompt's coordinate rule.

Iterate **system prompt → re-run → iterate** until all three fixtures pass live. **Commit every meaningful prompt change.**

- [ ] **Step 3: Record live latency in the findings doc**

Append to `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`:

```markdown
## Eval-runner live results (n=3 fixtures)

| Fixture | Latency | Passed scorers | Failed scorers |
|---|---|---|---|
| scenario-A-slack-dm-with-person | X.XX s | 6/6 | — |
| scenario-B-arc-open-PR          | X.XX s | 6/6 | — |
| scenario-C-iterm-run-tests       | X.XX s | 6/6 | — |

p50: X.XX s, p95: X.XX s (n=3 too small for real stats — re-measure with the latency probe at n=10+ for stable numbers)

Selector system-prompt revision history:
- vN: <one-line summary of what changed and why>
```

- [ ] **Step 4: Commit prompt revisions + findings**

```bash
git add tools/MercurySpike/Sources/EvalRunner/RunnerCommands.swift \
        docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md \
        tests/eval/results/
git commit -m "Phase 0: live-mercury eval green across all three fixtures"
```

### Task 28: Update spec §11 acceptance with measured baselines

The §11 acceptance criteria refer to "the §13 fixture suite" but now there are concrete numbers worth pinning.

**Files:**
- Modify: `docs/superpowers/specs/2026-05-16-context-system-redesign-design.md`

- [ ] **Step 1: Find §11 in the spec**

```bash
grep -n "## 11. Acceptance criteria" docs/superpowers/specs/2026-05-16-context-system-redesign-design.md
```

- [ ] **Step 2: Append baseline note**

After the "Brief quality" section in §11, add:

```markdown

**Baseline established Phase 0 (`docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md`):**
- Mercury 2 (`inception/<slug>`) passes scenarios A/B/C against the selector system prompt at vN with p95 latency = X.XX s (n=3).
- Subsequent phases must not regress these baselines without an explicit prompt-revision entry in the findings doc.
```

Fill in actual values from Task 27's findings.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-16-context-system-redesign-design.md
git commit -m "Phase 0: update spec §11 with Phase 0 measured baselines"
```

---

## Phase 0 completion criteria

Before declaring Phase 0 done and moving to Phase 1:

- [ ] `swift test` passes all tests in `tools/MercurySpike/` (target: 20+ tests passing)
- [ ] `swift run eval-runner mock` passes all 3 fixtures, all 6 scorers per fixture
- [ ] `swift run eval-runner live` passes all 3 fixtures with the iterated system prompt
- [ ] `docs/superpowers/spikes/2026-05-16-mercury-via-openrouter-findings.md` is populated with: selected model slug, JSON-mode reliability %, p50/p95 latency, eval results table, prompt revision log
- [ ] `docs/superpowers/specs/2026-05-16-context-system-redesign-design.md` §9 and §11 reference measured Phase 0 baselines
- [ ] All commits pushed (if you push remotely)

After Phase 0 ships, regenerate **Phase 1 plan** (`docs/superpowers/plans/2026-05-XX-phase-1-foundation.md`) using the writing-plans skill, with the spec + Phase 0 findings as inputs.
