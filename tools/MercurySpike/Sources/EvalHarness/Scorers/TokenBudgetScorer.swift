import Foundation

public struct TokenBudgetScorer: Scorer {
    public let name = "token_budget"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let budget = expected.brief_token_budget else {
            return ScoreResult(scorerName: name, passed: true, details: "no budget set")
        }
        let approxTokens = (modelOutput.brief.count + 3) / 4
        if approxTokens <= budget {
            return ScoreResult(scorerName: name, passed: true, details: "\(approxTokens) ≤ budget \(budget)")
        }
        return ScoreResult(scorerName: name, passed: false, details: "\(approxTokens) > budget \(budget)")
    }
}
