import Foundation

public struct PixelCoordGrepScorer: Scorer {
    public let name = "pixel_coord_grep"
    public init() {}

    private static let pattern = "\\b\\d{2,4}\\s*,\\s*\\d{2,4}\\b"

    public func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult {
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: Self.pattern) } catch {
            return ScoreResult(scorerName: name, passed: false, details: "internal: bad regex")
        }
        let range = NSRange(modelOutput.brief.startIndex..., in: modelOutput.brief)
        let matches = regex.matches(in: modelOutput.brief, range: range)
        if matches.isEmpty {
            return ScoreResult(scorerName: name, passed: true, details: "no pixel-coord-shaped substrings")
        }
        let snippets = matches.prefix(3).map { String(modelOutput.brief[Range($0.range, in: modelOutput.brief)!]) }
        return ScoreResult(scorerName: name, passed: false, details: "found pixel-coord-shaped substring(s): \(snippets.joined(separator: ", "))")
    }
}
