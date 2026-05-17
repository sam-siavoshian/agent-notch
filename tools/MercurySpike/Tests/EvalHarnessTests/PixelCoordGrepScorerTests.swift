import XCTest
@testable import EvalHarness

final class PixelCoordGrepScorerTests: XCTestCase {
    private let expected = Fixture.Expected(
        intent: .init(verb: "x", target: nil, resolved_target_contains: nil, entities: nil),
        brief_must_contain: [], brief_must_not_contain: nil, brief_token_budget: nil
    )

    func testPassesWhenNoPixelCoordsPresent() {
        let out = ModelOutput(intent: nil, brief: "Press cmd+K then type maya.", rawJSON: "")
        XCTAssertTrue(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnObviousPixelCoords() {
        let out = ModelOutput(intent: nil, brief: "Click at 847, 612 to send.", rawJSON: "")
        XCTAssertFalse(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testFailsOnBracketedCoords() {
        let out = ModelOutput(intent: nil, brief: "Bbox: 100,200,60,28", rawJSON: "")
        XCTAssertFalse(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }

    func testAllowsShortNumbersThatArentCoords() {
        let out = ModelOutput(intent: nil, brief: "Took 12 seconds. Use port 8080. 5 of 10 done.", rawJSON: "")
        XCTAssertTrue(PixelCoordGrepScorer().score(modelOutput: out, expected: expected).passed)
    }
}
