import Foundation
import CryptoKit

public struct MockLLMClient: LLMClientProtocol {
    public let goldensDirectory: URL

    public init(goldensDirectory: URL) {
        self.goldensDirectory = goldensDirectory
    }

    public func complete(rawInput: Data) async throws -> String {
        let hash = Self.sha256Hex(rawInput)
        let goldenURL = goldensDirectory.appendingPathComponent("\(hash).json")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            throw LLMClientError.mockMiss(hash: hash)
        }
        return try String(contentsOf: goldenURL, encoding: .utf8)
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
