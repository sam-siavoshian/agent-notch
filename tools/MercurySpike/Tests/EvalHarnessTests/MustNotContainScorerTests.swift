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
