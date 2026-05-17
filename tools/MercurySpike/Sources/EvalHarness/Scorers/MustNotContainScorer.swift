import Foundation

public struct MustNotContainScorer: Scorer {
    public let name = "must_not_contain"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let patterns = expected.brief_must_not_contain, !patterns.isEmpty else {
            return ScoreResult(scorerName: name, passed: true, details: "no forbidden patterns")
        }
        var matches: [String] = []
        var invalid: [String] = []
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let range = NSRange(modelOutput.brief.startIndex..., in: modelOutput.brief)
                if regex.firstMatch(in: modelOutput.brief, range: range) != nil {
                    matches.append(pattern)
                }
            } catch {
                invalid.append(pattern)
            }
        }
        if !invalid.isEmpty {
            return ScoreResult(scorerName: name, passed: false, details: "invalid regex(es): \(invalid.joined(separator: ", "))")
        }
        if matches.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "none of \(patterns.count) forbidden patterns matched")
        }
        return ScoreResult(scorerName: name, passed: false, details: "forbidden pattern(s) matched: \(matches.joined(separator: ", "))")
    }
}
