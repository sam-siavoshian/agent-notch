import Foundation

public struct IntentMatchScorer: Scorer {
    public let name = "intent_match"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let intent = modelOutput.intent else {
            return ScoreResult(scorerName: name, passed: false, details: "model output has no intent block")
        }
        var failures: [String] = []

        if intent.verb.lowercased() != expected.intent.verb.lowercased() {
            failures.append("verb: got '\(intent.verb)' expected '\(expected.intent.verb)'")
        }
        if let expectedSubstring = expected.intent.resolved_target_contains {
            let actual = (intent.resolved_target ?? "").lowercased()
            if !actual.contains(expectedSubstring.lowercased()) {
                failures.append("resolved_target: '\(intent.resolved_target ?? "<nil>")' does not contain '\(expectedSubstring)'")
            }
        }
        if let expectedEntities = expected.intent.entities {
            let actualLabels = Set((intent.entities ?? []).map { $0.label.lowercased() })
            for ex in expectedEntities {
                let found = actualLabels.contains { $0.contains(ex.label.lowercased()) }
                if !found {
                    failures.append("entity '\(ex.label)' (\(ex.kind)) missing from intent.entities")
                }
            }
        }

        if failures.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "intent matches expected")
        }
        return ScoreResult(scorerName: name, passed: false, details: failures.joined(separator: "; "))
    }
}
