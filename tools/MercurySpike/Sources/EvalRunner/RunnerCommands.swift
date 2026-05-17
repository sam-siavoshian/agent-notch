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

// SelectorSystemPrompt moved to Sources/EvalHarness/SelectorSystemPrompt.swift
// so Phase 4 production Selector.swift can `import EvalHarness` and reuse the
// same fixture-validated baseline.
