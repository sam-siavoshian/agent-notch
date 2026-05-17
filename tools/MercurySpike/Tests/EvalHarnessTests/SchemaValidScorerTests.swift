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
