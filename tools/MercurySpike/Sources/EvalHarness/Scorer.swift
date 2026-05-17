import Foundation

public struct ScoreResult {
    public let scorerName: String
    public let passed: Bool
    public let details: String

    public init(scorerName: String, passed: Bool, details: String) {
        self.scorerName = scorerName
        self.passed = passed
        self.details = details
    }
}

/// A Scorer evaluates a model response against fixture expectations.
public protocol Scorer {
    var name: String { get }
    func score(modelOutput: ModelOutput, expected: Fixture.Expected) -> ScoreResult
}

/// The Selector's structured output. Wraps the raw JSON returned by Mercury.
public struct ModelOutput {
    public let intent: Intent?
    public let brief: String
    public let rawJSON: String   // for grep-style scorers

    public struct Intent: Decodable {
        public let verb: String
        public let target: String?
        public let resolved_target: String?
        public let confidence: Double?
        public let entities: [Entity]?

        public struct Entity: Decodable {
            public let label: String
            public let kind: String
            public let resolved_to: String?
        }
    }

    public init(intent: Intent?, brief: String, rawJSON: String) {
        self.intent = intent
        self.brief = brief
        self.rawJSON = rawJSON
    }

    /// Parse a Mercury response shaped `{"intent": {...}, "brief": "..."}`.
    public static func parse(_ raw: String) throws -> ModelOutput {
        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "ModelOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: "non-utf8"])
        }
        struct Envelope: Decodable {
            let intent: Intent?
            let brief: String?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return ModelOutput(intent: env.intent, brief: env.brief ?? "", rawJSON: raw)
    }
}
