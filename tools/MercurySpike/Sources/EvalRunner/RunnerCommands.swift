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
