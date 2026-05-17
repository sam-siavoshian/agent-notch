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
