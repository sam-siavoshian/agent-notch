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
    ///
    /// The brief is extracted via JSONSerialization *independently* of intent decoding,
    /// so a brief that's well-formed still reaches scorers even when the Intent struct
    /// can't be decoded (e.g., when Mercury emits unexpected entity shapes).
    public static func parse(_ raw: String) throws -> ModelOutput {
        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "ModelOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: "non-utf8"])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ModelOutput", code: 2, userInfo: [NSLocalizedDescriptionKey: "rawJSON not an object"])
        }
        let brief = (obj["brief"] as? String) ?? ""
        var intent: Intent?
        if let intentAny = obj["intent"] {
            if let intentData = try? JSONSerialization.data(withJSONObject: intentAny) {
                intent = try? JSONDecoder().decode(Intent.self, from: intentData)
            }
        }
        return ModelOutput(intent: intent, brief: brief, rawJSON: raw)
    }
}
