import Foundation

/// Ground-truth sidecar shape: `<fixture>.expected.json`.
public struct ExpectedFixture: Decodable {
    public let expectedSurface: String
    public let expectedControls: [String]
    enum CodingKeys: String, CodingKey {
        case expectedSurface = "expected_surface"
        case expectedControls = "expected_controls"
    }
}

/// Minimal observed shape we care about for scoring — mirrors the snake_case
/// keys the live observer expects from Gemini.
public struct ObservedFixture: Decodable {
    public let currentSurface: String?
    public let observedControls: [Control]?

    public struct Control: Decodable {
        public let label: String
    }

    enum CodingKeys: String, CodingKey {
        // The observer schema uses `observable_controls`, but the task spec
        // references both `observed_controls` and `observable_controls`.
        // Accept either to be defensive against minor model drift.
        case currentSurface = "current_surface"
        case observedControls = "observable_controls"
    }

    // Custom decode to accept either key name.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        self.currentSurface = try c.decodeIfPresent(String.self, forKey: AnyKey("current_surface"))
        if let primary = try c.decodeIfPresent([Control].self, forKey: AnyKey("observable_controls")) {
            self.observedControls = primary
        } else if let alt = try c.decodeIfPresent([Control].self, forKey: AnyKey("observed_controls")) {
            self.observedControls = alt
        } else {
            self.observedControls = nil
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

/// Per-fixture per-variant score row.
public struct ScoreRow {
    public let fixture: String
    public let variant: String
    public let surfaceMatch: Double      // 0 or 1
    public let controlRecall: Double     // 0..1
    public let controlPrecision: Double  // 0..1
    public let latencyS: Double
    public let error: String?            // non-nil if the run errored

    public init(fixture: String, variant: String, surfaceMatch: Double, controlRecall: Double, controlPrecision: Double, latencyS: Double, error: String? = nil) {
        self.fixture = fixture
        self.variant = variant
        self.surfaceMatch = surfaceMatch
        self.controlRecall = controlRecall
        self.controlPrecision = controlPrecision
        self.latencyS = latencyS
        self.error = error
    }
}

public enum Scorer {

    /// Normalize a control label for set comparison: lowercased, trimmed of whitespace.
    public static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Score one (expected, observed) pair. Returns surfaceMatch, recall, precision.
    public static func score(expected: ExpectedFixture, observed: ObservedFixture) -> (surface: Double, recall: Double, precision: Double) {
        // Surface match: case-insensitive substring of expected in observed current_surface.
        let surface: Double = {
            guard let cs = observed.currentSurface else { return 0.0 }
            let needle = expected.expectedSurface.lowercased()
            let hay = cs.lowercased()
            return hay.contains(needle) ? 1.0 : 0.0
        }()

        let expectedSet = Set(expected.expectedControls.map(normalize))
        let observedSet = Set((observed.observedControls ?? []).map { normalize($0.label) })

        let intersection = expectedSet.intersection(observedSet)
        let recall: Double = expectedSet.isEmpty ? 1.0 : Double(intersection.count) / Double(expectedSet.count)
        let precision: Double = observedSet.isEmpty ? 0.0 : Double(intersection.count) / Double(observedSet.count)
        return (surface, recall, precision)
    }
}
