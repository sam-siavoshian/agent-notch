import Foundation

public struct SchemaValidScorer: Scorer {
    public let name = "schema_valid"
    public init() {}

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        guard let data = modelOutput.rawJSON.data(using: .utf8) else {
            return ScoreResult(scorerName: name, passed: false, details: "rawJSON is non-utf8")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScoreResult(scorerName: name, passed: false, details: "rawJSON is not a JSON object")
        }
        guard let intent = obj["intent"] as? [String: Any] else {
            return ScoreResult(scorerName: name, passed: false, details: "missing 'intent' object")
        }
        guard intent["verb"] is String else {
            return ScoreResult(scorerName: name, passed: false, details: "intent.verb missing or not a string")
        }
        guard let brief = obj["brief"] as? String, !brief.isEmpty else {
            return ScoreResult(scorerName: name, passed: false, details: "missing 'brief' string")
        }
        return ScoreResult(scorerName: name, passed: true, details: "valid envelope")
    }
}
