import XCTest
import CryptoKit
@testable import EvalHarness

final class MockLLMClientTests: XCTestCase {

    func testReplaysGoldenForKnownInputHash() async throws {
        let tmp = try MockTempDir()
        // Create a golden file keyed by SHA256 of the input bytes
        let input = Data("{\"x\":1}".utf8)
        let hash = sha256Hex(input)
        let goldenURL = tmp.url.appendingPathComponent("\(hash).json")
        let golden = """
        {"intent": {"verb": "send"}, "brief": "do the thing"}
        """
        try golden.write(to: goldenURL, atomically: true, encoding: .utf8)

        let client = MockLLMClient(goldensDirectory: tmp.url)
        let raw = try await client.complete(rawInput: input)
        XCTAssertTrue(raw.contains("\"verb\": \"send\""))
        XCTAssertTrue(raw.contains("do the thing"))
    }

    func testThrowsForUnknownInput() async {
        let tmp = try! MockTempDir()
        let client = MockLLMClient(goldensDirectory: tmp.url)
        do {
            _ = try await client.complete(rawInput: Data("{\"unknown\":true}".utf8))
            XCTFail("expected throw")
        } catch {
            // pass
        }
    }
}

// MARK: - Local helpers
//
// `TempDir` is being added by a parallel T09 worktree (FixtureLoadingTests.swift).
// To avoid a name collision at merge time, we define a locally-named variant here.

final class MockTempDir {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockLLMClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
