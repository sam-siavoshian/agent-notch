import Foundation

public enum OpenRouterError: Error, CustomStringConvertible {
    case httpStatus(Int, Data)
    case missingAPIKey
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .httpStatus(let code, let data):
            let preview = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
            return "OpenRouter HTTP \(code): \(preview)"
        case .missingAPIKey:
            return "OPENROUTER_API_KEY not set"
        case .malformedResponse(let s):
            return "Malformed OpenRouter response: \(s)"
        }
    }
}
