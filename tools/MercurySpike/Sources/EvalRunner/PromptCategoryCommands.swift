import Foundation
import EvalHarness
import OpenRouterAPI

/// Phase-3 commands for the new prompt categories: `active_task_updater` and
/// `recipe_naming`. These share transport with the selector commands but use
/// different system prompts, fixture trees, and (deliberately ad-hoc) scoring
/// pulled straight from each fixture's `expected.json`.
///
/// The selector flow's typed `Fixture.Expected` schema doesn't fit either of
/// these prompt classes, so we bypass `Harness.run(fixtures:)` and walk the
/// fixture directories manually.
enum PromptCategoryCommands {

    // MARK: - Paths

    private static func fixturesDir(_ category: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/eval/fixtures/\(category)")
    }

    private static func goldensDir(_ category: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/eval/goldens/\(category)")
    }

    private static func resultsDir() -> URL {
        URL(fileURLWithPath: "tests/eval/results")
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
    }

    // MARK: - Generic fixture loader (no typed expected.json schema)

    struct RawFixture {
        let name: String
        let directory: URL
        let inputRaw: Data
        let expectedAny: [String: Any]
    }

    private static func loadRawFixtures(in dir: URL) throws -> [RawFixture] {
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        var out: [RawFixture] = []
        for child in contents {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            let inputURL = child.appendingPathComponent("input.json")
            let expectedURL = child.appendingPathComponent("expected.json")
            guard FileManager.default.fileExists(atPath: inputURL.path),
                  FileManager.default.fileExists(atPath: expectedURL.path) else { continue }
            let inputRaw = try Data(contentsOf: inputURL)
            let expectedRaw = try Data(contentsOf: expectedURL)
            let expectedAny = (try? JSONSerialization.jsonObject(with: expectedRaw)) as? [String: Any] ?? [:]
            out.append(RawFixture(name: child.lastPathComponent, directory: child, inputRaw: inputRaw, expectedAny: expectedAny))
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: - ActiveTaskUpdater scoring

    struct Check {
        let label: String
        let passed: Bool
        let detail: String
    }

    static func scoreActiveTask(raw: String, expected: [String: Any]) -> [Check] {
        var checks: [Check] = []

        // Parse raw as JSON object
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            checks.append(Check(label: "json_parse", passed: false, detail: "raw response is not valid JSON: \(raw.prefix(120))"))
            return checks
        }

        // Determine shape
        let hasUpdate = obj["update"] != nil
        let hasArchive = obj["archive_and_start_new"] != nil
        let actualShape: String = {
            if hasUpdate && !hasArchive { return "update" }
            if hasArchive && !hasUpdate { return "archive_and_start_new" }
            return "unknown"
        }()
        let expectedShape = expected["response_shape"] as? String ?? "update"
        checks.append(Check(
            label: "response_shape",
            passed: actualShape == expectedShape,
            detail: "expected=\(expectedShape) actual=\(actualShape)"
        ))

        // Extract the relevant active_task body for label / kind / narrative / resources checks
        var taskAny: [String: Any]? = nil
        if let u = obj["update"] as? [String: Any] { taskAny = u }
        if let pair = obj["archive_and_start_new"] as? [String: Any],
           let nt = pair["new_task"] as? [String: Any] {
            taskAny = nt
        }

        // active_task_label_contains: ANY-of (case-insensitive substring on label)
        if let needles = expected["active_task_label_contains"] as? [String] {
            let label = (taskAny?["label"] as? String ?? "").lowercased()
            let hit = needles.first(where: { label.contains($0.lowercased()) })
            checks.append(Check(
                label: "active_task_label_contains",
                passed: hit != nil,
                detail: hit != nil
                    ? "label '\(label)' contains '\(hit!)'"
                    : "label '\(label)' missing any of \(needles)"
            ))
        }

        // active_task_kind_in: kind must be one of the listed values (case-insensitive)
        if let allowed = expected["active_task_kind_in"] as? [String] {
            let kind = (taskAny?["kind"] as? String ?? "").lowercased()
            let allowedLower = allowed.map { $0.lowercased() }
            let ok = allowedLower.contains(kind)
            checks.append(Check(
                label: "active_task_kind_in",
                passed: ok,
                detail: ok ? "kind '\(kind)' in \(allowed)" : "kind '\(kind)' not in \(allowed)"
            ))
        }

        // narrative_must_contain: ALL must appear in narrative (case-insensitive)
        if let needles = expected["narrative_must_contain"] as? [String] {
            let narrative = (taskAny?["narrative"] as? String ?? "").lowercased()
            let missing = needles.filter { !narrative.contains($0.lowercased()) }
            checks.append(Check(
                label: "narrative_must_contain",
                passed: missing.isEmpty,
                detail: missing.isEmpty
                    ? "all \(needles.count) substring(s) present"
                    : "missing: \(missing)"
            ))
        }

        // resources_must_include: each URI must appear in resources array (substring tolerant)
        if let needles = expected["resources_must_include"] as? [String] {
            let resources = (taskAny?["resources"] as? [String]) ?? []
            let joined = resources.joined(separator: " | ")
            let missing = needles.filter { !joined.contains($0) }
            checks.append(Check(
                label: "resources_must_include",
                passed: missing.isEmpty,
                detail: missing.isEmpty
                    ? "all \(needles.count) uri(s) present"
                    : "missing: \(missing); have: \(resources)"
            ))
        }

        // For archive_and_start_new shape, validate ended outcome too
        if expectedShape == "archive_and_start_new",
           let needles = expected["ended_outcome_must_contain"] as? [String],
           let pair = obj["archive_and_start_new"] as? [String: Any],
           let ended = pair["ended_task"] as? [String: Any] {
            let outcome = (ended["outcome"] as? String ?? "").lowercased()
            let missing = needles.filter { !outcome.contains($0.lowercased()) }
            checks.append(Check(
                label: "ended_outcome_must_contain",
                passed: missing.isEmpty,
                detail: missing.isEmpty
                    ? "all \(needles.count) substring(s) present"
                    : "missing: \(missing) (outcome=\(outcome.prefix(80)))"
            ))
        }

        // For archive_and_start_new shape, validate new task label too
        if expectedShape == "archive_and_start_new",
           let needles = expected["new_task_label_contains"] as? [String] {
            let label = (taskAny?["label"] as? String ?? "").lowercased()
            let hit = needles.first(where: { label.contains($0.lowercased()) })
            checks.append(Check(
                label: "new_task_label_contains",
                passed: hit != nil,
                detail: hit != nil
                    ? "label '\(label)' contains '\(hit!)'"
                    : "label '\(label)' missing any of \(needles)"
            ))
        }

        // For archive_and_start_new shape, kind family on new task
        if expectedShape == "archive_and_start_new",
           let allowed = expected["new_task_kind_in"] as? [String] {
            let kind = (taskAny?["kind"] as? String ?? "").lowercased()
            let allowedLower = allowed.map { $0.lowercased() }
            let ok = allowedLower.contains(kind)
            checks.append(Check(
                label: "new_task_kind_in",
                passed: ok,
                detail: ok ? "kind '\(kind)' in \(allowed)" : "kind '\(kind)' not in \(allowed)"
            ))
        }

        return checks
    }

    // MARK: - RecipeNaming scoring

    static func scoreRecipeNaming(raw: String, expected: [String: Any]) -> [Check] {
        var checks: [Check] = []
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            checks.append(Check(label: "json_parse", passed: false, detail: "raw response is not valid JSON: \(raw.prefix(120))"))
            return checks
        }
        let name = (obj["name"] as? String ?? "").lowercased()
        let trigger = (obj["trigger_pattern"] as? String ?? "").lowercased()

        checks.append(Check(
            label: "has_name",
            passed: !name.isEmpty,
            detail: "name='\(name)'"
        ))
        checks.append(Check(
            label: "has_trigger_pattern",
            passed: !trigger.isEmpty,
            detail: "trigger_pattern='\(trigger)'"
        ))

        if let needles = expected["name_must_contain_any"] as? [String] {
            let hit = needles.first { name.contains($0.lowercased()) }
            checks.append(Check(
                label: "name_must_contain_any",
                passed: hit != nil,
                detail: hit != nil ? "matched '\(hit!)'" : "no match in \(needles)"
            ))
        }

        if let needles = expected["trigger_pattern_must_contain_any"] as? [String] {
            let hit = needles.first { trigger.contains($0.lowercased()) }
            checks.append(Check(
                label: "trigger_pattern_must_contain_any",
                passed: hit != nil,
                detail: hit != nil ? "matched '\(hit!)'" : "no match in \(needles)"
            ))
        }

        return checks
    }

    // MARK: - Generic runner

    /// Runs a category with a given client + scorer. Returns count of (passed, total).
    private static func runCategory(
        category: String,
        modeLabel: String,
        client: LLMClientProtocol,
        scorer: (String, [String: Any]) -> [Check],
        writeResults: Bool
    ) async throws -> (passed: Int, total: Int) {
        let fixtures = try loadRawFixtures(in: fixturesDir(category))
        print("\(modeLabel) (\(category)): \(fixtures.count) fixture(s)\n")

        var passedCount = 0
        var totalCount = 0
        var resultRows: [[String: Any]] = []

        for fixture in fixtures {
            totalCount += 1
            let start = Date()
            let raw: String
            do {
                raw = try await client.complete(rawInput: fixture.inputRaw)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("[FAIL] \(fixture.name)  (\(String(format: "%.2f", elapsed))s)")
                print("  ✗ client_error: \(error)")
                resultRows.append([
                    "category": category,
                    "fixture": fixture.name,
                    "check": "client_error",
                    "passed": false,
                    "detail": "\(error)",
                    "latency_s": elapsed
                ])
                continue
            }
            let elapsed = Date().timeIntervalSince(start)
            let checks = scorer(raw, fixture.expectedAny)
            let allPassed = !checks.isEmpty && checks.allSatisfy { $0.passed }
            print("[\(allPassed ? "PASS" : "FAIL")] \(fixture.name)  (\(String(format: "%.2f", elapsed))s)")
            for c in checks {
                let mark = c.passed ? "  ✓" : "  ✗"
                print("\(mark) \(c.label): \(c.detail)")
                resultRows.append([
                    "category": category,
                    "fixture": fixture.name,
                    "check": c.label,
                    "passed": c.passed,
                    "detail": c.detail,
                    "latency_s": elapsed
                ])
            }
            if allPassed { passedCount += 1 }
        }

        print("\nTotal: \(passedCount)/\(totalCount) passed\n")

        if writeResults && !resultRows.isEmpty {
            let dir = resultsDir()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(category)-results.json")
            let data = try JSONSerialization.data(withJSONObject: resultRows, options: [.prettyPrinted])
            try data.write(to: url)
            print("Results written to \(url.path)")
        }

        return (passedCount, totalCount)
    }

    // MARK: - Public commands

    static func mockActiveTask() async throws {
        let category = "active_task_updater"
        let goldensRoot = goldensDir(category)

        // Mock client per fixture (each fixture has its own golden directory)
        let fixtures = try loadRawFixtures(in: fixturesDir(category))
        print("Mock-LLM mode (\(category)): \(fixtures.count) fixture(s)\n")

        var passedCount = 0
        for fixture in fixtures {
            let goldenForFixture = goldensRoot.appendingPathComponent(fixture.name)
            let client = MockLLMClient(goldensDirectory: goldenForFixture)
            let start = Date()
            let raw: String
            do {
                raw = try await client.complete(rawInput: fixture.inputRaw)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("[FAIL] \(fixture.name)  (\(String(format: "%.2f", elapsed))s)")
                print("  ✗ mock_lookup: \(error)")
                continue
            }
            let elapsed = Date().timeIntervalSince(start)
            let checks = scoreActiveTask(raw: raw, expected: fixture.expectedAny)
            let allPassed = !checks.isEmpty && checks.allSatisfy { $0.passed }
            print("[\(allPassed ? "PASS" : "FAIL")] \(fixture.name)  (\(String(format: "%.2f", elapsed))s)")
            for c in checks {
                let mark = c.passed ? "  ✓" : "  ✗"
                print("\(mark) \(c.label): \(c.detail)")
            }
            if allPassed { passedCount += 1 }
        }
        print("\nTotal: \(passedCount)/\(fixtures.count) passed")
        if passedCount != fixtures.count { exit(1) }
    }

    static func liveActiveTask() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        let model = ProcessInfo.processInfo.environment["MERCURY_MODEL"] ?? "inception/mercury-2"
        let client = LiveMercuryGenericClient(
            openRouter: OpenRouterClient(apiKey: apiKey),
            model: model,
            systemPrompt: ActiveTaskUpdaterSystemPrompt.text,
            maxTokens: 1200
        )
        let (passed, total) = try await runCategory(
            category: "active_task_updater",
            modeLabel: "Live-Mercury mode (model=\(model))",
            client: client,
            scorer: scoreActiveTask,
            writeResults: true
        )
        if passed != total { exit(1) }
    }

    static func mockRecipeNaming() async throws {
        let category = "recipe_naming"
        let goldensRoot = goldensDir(category)
        let fixtures = try loadRawFixtures(in: fixturesDir(category))
        print("Mock-LLM mode (\(category)): \(fixtures.count) fixture(s)\n")

        var passedCount = 0
        for fixture in fixtures {
            let goldenForFixture = goldensRoot.appendingPathComponent(fixture.name)
            let client = MockLLMClient(goldensDirectory: goldenForFixture)
            let start = Date()
            let raw: String
            do {
                raw = try await client.complete(rawInput: fixture.inputRaw)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                print("[FAIL] \(fixture.name)  (\(String(format: "%.2f", elapsed))s)")
                print("  ✗ mock_lookup: \(error)")
                continue
            }
            let elapsed = Date().timeIntervalSince(start)
            let checks = scoreRecipeNaming(raw: raw, expected: fixture.expectedAny)
            let allPassed = !checks.isEmpty && checks.allSatisfy { $0.passed }
            print("[\(allPassed ? "PASS" : "FAIL")] \(fixture.name)  (\(String(format: "%.2f", elapsed))s)")
            for c in checks {
                let mark = c.passed ? "  ✓" : "  ✗"
                print("\(mark) \(c.label): \(c.detail)")
            }
            if allPassed { passedCount += 1 }
        }
        print("\nTotal: \(passedCount)/\(fixtures.count) passed")
        if passedCount != fixtures.count { exit(1) }
    }

    static func liveRecipeNaming() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        let model = ProcessInfo.processInfo.environment["MERCURY_MODEL"] ?? "inception/mercury-2"
        let client = LiveMercuryGenericClient(
            openRouter: OpenRouterClient(apiKey: apiKey),
            model: model,
            systemPrompt: RecipeNamingSystemPrompt.text,
            maxTokens: 400
        )
        let (passed, total) = try await runCategory(
            category: "recipe_naming",
            modeLabel: "Live-Mercury mode (model=\(model))",
            client: client,
            scorer: scoreRecipeNaming,
            writeResults: true
        )
        if passed != total { exit(1) }
    }
}
