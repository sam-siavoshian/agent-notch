import XCTest
@testable import EvalHarness

final class TokenBudgetScorerTests: XCTestCase {
    func testPassesUnderBudget() {
        let out = ModelOutput(intent: nil, brief: String(repeating: "x", count: 100), rawJSON: "")
        let expected = makeExpected(budget: 600)
        XCTAssertTrue(TokenBudgetScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOverBudget() {
        let out = ModelOutput(intent: nil, brief: String(repeating: "x", count: 3000), rawJSON: "")
        let expected = makeExpected(budget: 600)
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
