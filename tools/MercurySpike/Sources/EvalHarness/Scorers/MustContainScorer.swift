import Foundation

public struct MustContainScorer: Scorer {
    public let name = "must_contain"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        let needles = expected.brief_must_contain
        let haystack = modelOutput.brief.lowercased()
        let missing = needles.filter { !haystack.contains($0.lowercased()) }
        if missing.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "all \(needles.count) strings present")
        } else {
            return ScoreResult(scorerName: name, passed: false, details: "missing: \(missing.joined(separator: ", "))")
        }
    }
}
