import Foundation

public struct Harness {
    public let client: LLMClientProtocol
    public let scorers: [Scorer]

    public init(client: LLMClientProtocol, scorers: [Scorer]? = nil) {
        self.client = client
        self.scorers = scorers ?? [
            SchemaValidScorer(),
            MustContainScorer(),
            MustNotContainScorer(),
            IntentMatchScorer(),
            PixelCoordGrepScorer(),
            TokenBudgetScorer()
        ]
    }

    public struct FixtureResult {
        public let fixtureName: String
        public let modelOutputRaw: String
        public let latencySeconds: Double
        public let scoreResults: [ScoreResult]
        public var allPassed: Bool { scoreResults.allSatisfy(\.passed) }

        public init(fixtureName: String, modelOutputRaw: String, latencySeconds: Double, scoreResults: [ScoreResult]) {
            self.fixtureName = fixtureName
            self.modelOutputRaw = modelOutputRaw
            self.latencySeconds = latencySeconds
            self.scoreResults = scoreResults
        }
    }

    public struct RunResult {
        public let fixtureResults: [FixtureResult]
        public var totalFixtures: Int { fixtureResults.count }
        public var passedFixtures: Int { fixtureResults.filter(\.allPassed).count }
        public var allPassed: Bool { fixtureResults.allSatisfy(\.allPassed) }

        public init(fixtureResults: [FixtureResult]) {
            self.fixtureResults = fixtureResults
        }
    }

    public func run(fixtures: [Fixture]) async throws -> RunResult {
        var results: [FixtureResult] = []
        for fixture in fixtures {
            let start = Date()
            let raw = try await client.complete(rawInput: fixture.inputRaw)
            let elapsed = Date().timeIntervalSince(start)

            let modelOutput: ModelOutput
            do {
                modelOutput = try ModelOutput.parse(raw)
            } catch {
                modelOutput = ModelOutput(intent: nil, brief: "", rawJSON: raw)
            }
            let scoreResults = scorers.map { $0.score(modelOutput: modelOutput, expected: fixture.expected) }
            results.append(FixtureResult(
                fixtureName: fixture.name,
                modelOutputRaw: raw,
                latencySeconds: elapsed,
                scoreResults: scoreResults
            ))
        }
        return RunResult(fixtureResults: results)
    }
}
