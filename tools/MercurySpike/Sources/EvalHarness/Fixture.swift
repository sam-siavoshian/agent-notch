import Foundation

public struct Fixture {
    public let name: String
    public let directory: URL
    public let input: Any            // raw JSON object — the selector input payload
    public let inputRaw: Data        // for hashing / replay
    public let expected: Expected
    public let notes: String?

    public struct Expected: Decodable {
        public let intent: IntentExpectation
        public let brief_must_contain: [String]
        public let brief_must_not_contain: [String]?
        public let brief_token_budget: Int?

        public init(
            intent: IntentExpectation,
            brief_must_contain: [String],
            brief_must_not_contain: [String]?,
            brief_token_budget: Int?
        ) {
            self.intent = intent
            self.brief_must_contain = brief_must_contain
            self.brief_must_not_contain = brief_must_not_contain
            self.brief_token_budget = brief_token_budget
        }

        public struct IntentExpectation: Decodable {
            public let verb: String
            public let target: String?
            public let resolved_target_contains: String?
            public let entities: [Entity]?

            public init(
                verb: String,
                target: String?,
                resolved_target_contains: String?,
                entities: [Entity]?
            ) {
                self.verb = verb
                self.target = target
                self.resolved_target_contains = resolved_target_contains
                self.entities = entities
            }

            public struct Entity: Decodable {
                public let label: String
                public let kind: String

                public init(label: String, kind: String) {
                    self.label = label
                    self.kind = kind
                }
            }
        }
    }

    public static func load(from dir: URL) throws -> Fixture {
        let inputURL = dir.appendingPathComponent("input.json")
        let expectedURL = dir.appendingPathComponent("expected.json")
        let notesURL = dir.appendingPathComponent("notes.md")

        let inputRaw = try Data(contentsOf: inputURL)
        let inputAny = try JSONSerialization.jsonObject(with: inputRaw)

        let expectedRaw = try Data(contentsOf: expectedURL)
        let expected = try JSONDecoder().decode(Expected.self, from: expectedRaw)

        let notes = (try? String(contentsOf: notesURL, encoding: .utf8))

        return Fixture(
            name: dir.lastPathComponent,
            directory: dir,
            input: inputAny,
            inputRaw: inputRaw,
            expected: expected,
            notes: notes
        )
    }

    public static func loadAll(from parentDir: URL) throws -> [Fixture] {
        let contents = try FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: [.isDirectoryKey])
        var results: [Fixture] = []
        for child in contents {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            results.append(try Fixture.load(from: child))
        }
        return results.sorted { $0.name < $1.name }
    }
}
