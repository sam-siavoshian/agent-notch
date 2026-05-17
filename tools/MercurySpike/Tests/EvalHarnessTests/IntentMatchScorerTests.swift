import XCTest
@testable import EvalHarness

final class IntentMatchScorerTests: XCTestCase {

    func testExactVerbMatchPasses() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: "the draft", resolved_target: nil, confidence: 0.8, entities: nil),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil, entities: nil)
        XCTAssertTrue(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testVerbMismatchFails() {
        let out = ModelOutput(
            intent: .init(verb: "open", target: nil, resolved_target: nil, confidence: nil, entities: nil),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil, entities: nil)
        let r = IntentMatchScorer().score(modelOutput: out, expected: expected)
        XCTAssertFalse(r.passed)
        XCTAssertTrue(r.details.contains("verb"))
    }

    func testResolvedTargetSubstringMatch() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: "the draft", resolved_target: "Figma file 'Onboarding v3'", confidence: nil, entities: nil),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: "Onboarding v3", entities: nil)
        XCTAssertTrue(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testEntityKindSetMatch() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: nil, resolved_target: nil, confidence: nil,
                          entities: [.init(label: "Maya Chen", kind: "person", resolved_to: "@maya")]),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil,
                                    entities: [("Maya", "person")])
        XCTAssertTrue(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testEntityMissingFails() {
        let out = ModelOutput(
            intent: .init(verb: "send", target: nil, resolved_target: nil, confidence: nil, entities: []),
            brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil,
                                    entities: [("Maya", "person")])
        XCTAssertFalse(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testNoIntentInOutputFails() {
        let out = ModelOutput(intent: nil, brief: "", rawJSON: "")
        let expected = makeExpected(verb: "send", target: nil, resolvedContains: nil, entities: nil)
        XCTAssertFalse(IntentMatchScorer().score(modelOutput: out, expected: expected).passed)
    }

    private func makeExpected(
        verb: String,
        target: String?,
        resolvedContains: String?,
        entities: [(String, String)]?
    ) -> Fixture.Expected {
        let ents = entities?.map { Fixture.Expected.IntentExpectation.Entity(label: $0.0, kind: $0.1) }
        return Fixture.Expected(
            intent: .init(verb: verb, target: target, resolved_target_contains: resolvedContains, entities: ents),
            brief_must_contain: [],
            brief_must_not_contain: nil,
            brief_token_budget: nil
        )
    }
}
