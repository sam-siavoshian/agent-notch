import Foundation

public struct OpenRouterClient {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public let apiKey: String
    public let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func chatCompletion(request: ChatCompletionRequest) async throws -> ChatCompletion {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // OpenRouter best-practice headers; harmless if omitted.
        req.addValue("AgentNotch", forHTTPHeaderField: "X-Title")
        req.addValue("https://github.com/wyattgill01/AgentNotch", forHTTPHeaderField: "HTTP-Referer")

        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.httpStatus(http.statusCode, data)
        }
        return try JSONDecoder().decode(ChatCompletion.self, from: data)
    }
}
