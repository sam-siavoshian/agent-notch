import Foundation

public protocol LLMClientProtocol {
    /// Completes a request and returns the raw response text (typically JSON).
    /// `rawInput` is the canonical bytes for the request body — used both as the
    /// HTTP body in live mode and as the hash key in mock mode.
    func complete(rawInput: Data) async throws -> String
}

public enum LLMClientError: Error, CustomStringConvertible {
    case mockMiss(hash: String)
    public var description: String {
        switch self {
        case .mockMiss(let h): return "Mock-LLM has no golden for input hash \(h)"
        }
    }
}
