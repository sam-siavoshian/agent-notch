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
