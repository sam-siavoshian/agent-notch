import XCTest
@testable import EvalHarness

final class HarnessTests: XCTestCase {

    func testRunsAllScorersOnSingleFixture() async throws {
        let tmp = try HarnessTempDir()
        let fxDir = tmp.url.appendingPathComponent("scenario-1")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try "{\"transcript\":\"hi\"}".write(to: fxDir.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
        try """
        {"intent": {"verb": "greet"},
         "brief_must_contain": ["hello"],
         "brief_must_not_contain": ["bbox"],
         "brief_token_budget": 600}
        """.write(to: fxDir.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)

        let mockClient = HarnessStubClient(response: """
        {"intent": {"verb": "greet"}, "brief": "say hello to the user"}
        """)
        let harness = Harness(client: mockClient)
        let fixtures = try Fixture.loadAll(from: tmp.url)
        let runResult = try await harness.run(fixtures: fixtures)

        XCTAssertEqual(runResult.fixtureResults.count, 1)
        let scores = runResult.fixtureResults[0].scoreResults
        XCTAssertEqual(scores.count, 6, "expected 6 scorers: \(scores.map(\.scorerName))")
        XCTAssertTrue(scores.allSatisfy(\.passed), "all should pass: \(scores.filter { !$0.passed }.map(\.details))")
    }

    func testReportsFailingScorers() async throws {
        let tmp = try HarnessTempDir()
        let fxDir = tmp.url.appendingPathComponent("scenario-fail")
        try FileManager.default.createDirectory(at: fxDir, withIntermediateDirectories: true)
        try "{\"x\":1}".write(to: fxDir.appendingPathComponent("input.json"), atomically: true, encoding: .utf8)
        try """
        {"intent": {"verb": "send"}, "brief_must_contain": ["this string is not in the response"]}
        """.write(to: fxDir.appendingPathComponent("expected.json"), atomically: true, encoding: .utf8)

        let mockClient = HarnessStubClient(response: """
        {"intent": {"verb": "open"}, "brief": "different content"}
        """)
        let runResult = try await Harness(client: mockClient).run(fixtures: try Fixture.loadAll(from: tmp.url))
        let fixtureResult = runResult.fixtureResults[0]
        XCTAssertFalse(fixtureResult.allPassed)
        XCTAssertTrue(fixtureResult.scoreResults.contains { $0.scorerName == "must_contain" && !$0.passed })
        XCTAssertTrue(fixtureResult.scoreResults.contains { $0.scorerName == "intent_match" && !$0.passed })
    }
}

// helpers — local name-prefixed to avoid collisions with TempDir/StubClient in other test files
struct HarnessStubClient: LLMClientProtocol {
    let response: String
    func complete(rawInput: Data) async throws -> String { response }
}

final class HarnessTempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("evalharness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
