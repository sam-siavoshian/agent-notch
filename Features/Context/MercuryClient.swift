import Foundation

/// Production client for Mercury 2 via OpenRouter. Per-call hard timeout
/// (default 2.5s for Selector / 2.0s for ActiveTaskUpdater).
public final class MercuryClient {

    public static let shared = MercuryClient()

    public static let defaultModel = "inception/mercury-2"

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private let session: URLSession = .shared

    private init() {}

    public enum ClientError: Error, CustomStringConvertible {
        case missingAPIKey
        case timeout
        case httpStatus(Int, Data)
        case malformedResponse(String)
        public var description: String {
            switch self {
            case .missingAPIKey:           return "OPENROUTER_API_KEY not set"
            case .timeout:                 return "Mercury request timed out"
            case .httpStatus(let c, let d):
                let preview = String(data: d, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
                return "OpenRouter HTTP \(c): \(preview)"
            case .malformedResponse(let s): return "Malformed OpenRouter response: \(s)"
            }
        }
    }

    public struct Message: Codable {
        public let role: String     // "system" | "user" | "assistant"
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try c.decode(String.self, forKey: .role)
            self.content = (try? c.decode(String.self, forKey: .content)) ?? ""
        }
        private enum CodingKeys: String, CodingKey { case role, content }
    }

    public enum ResponseFormat {
        case jsonObject
        case freeform
    }

    /// Send a chat completion request and return the assistant's content string.
    /// `responseFormat == .jsonObject` engages OpenRouter's strict-JSON mode.
    public func complete(
        messages: [Message],
        model: String = MercuryClient.defaultModel,
        responseFormat: ResponseFormat = .jsonObject,
        maxTokens: Int = 1200,
        timeout: TimeInterval = 2.5
    ) async throws -> String {
        let startedAt = Date()
        let obsID = UUID()
        let systemContent = messages.first(where: { $0.role == "system" })?.content
        let role = Self.inferRole(systemContent: systemContent)
        let userPreview = messages.last(where: { $0.role == "user" })?.content.prefix(4000) ?? ""
        let systemPreview = systemContent?.prefix(4000) ?? "<none>"
        let requestSummary = "model=\(model) maxTokens=\(maxTokens) timeout=\(timeout)s\n--- system ---\n\(systemPreview)\n--- user ---\n\(userPreview)"

        do {
            let result = try await performRequest(
                messages: messages,
                model: model,
                responseFormat: responseFormat,
                maxTokens: maxTokens,
                timeout: timeout
            )
            AgentObservabilityLog.shared.record(.mercuryCall(
                id: obsID,
                t: startedAt,
                role: role,
                requestSummary: requestSummary,
                responseSummary: String(result.prefix(4000)),
                latencyS: Date().timeIntervalSince(startedAt),
                success: true,
                promptTokens: nil,
                completionTokens: nil
            ))
            return result
        } catch {
            AgentObservabilityLog.shared.record(.mercuryCall(
                id: obsID,
                t: startedAt,
                role: role,
                requestSummary: requestSummary,
                responseSummary: "ERROR: \(error)",
                latencyS: Date().timeIntervalSince(startedAt),
                success: false,
                promptTokens: nil,
                completionTokens: nil
            ))
            throw error
        }
    }

    private static func inferRole(systemContent: String?) -> AgentObservabilityLog.MercuryRole {
        guard let content = systemContent else { return .other }
        if content.contains("context selector") { return .selector }
        if content.contains("Active Task object") { return .activeTaskUpdater }
        if content.contains("recipe") && content.contains("name") { return .recipeNaming }
        return .other
    }

    /// Separated from `complete` so the public wrapper can record observability
    /// events for both success and failure paths without duplicating logic.
    private func performRequest(
        messages: [Message],
        model: String,
        responseFormat: ResponseFormat,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        guard let apiKey = Secrets.openRouterAPIKey, !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("AgentNotch", forHTTPHeaderField: "X-Title")
        req.addValue("https://github.com/wyattgill01/AgentNotch", forHTTPHeaderField: "HTTP-Referer")
        req.timeoutInterval = timeout + 0.5

        let body = RequestBody(
            model: model,
            messages: messages,
            response_format: responseFormat == .jsonObject ? .init(type: "json_object") : nil,
            max_tokens: maxTokens
        )
        req.httpBody = try Self.encoder.encode(body)

        // Race the request against the deadline.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let (data, response) = try await self.session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw ClientError.malformedResponse("non-HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ClientError.httpStatus(http.statusCode, data)
                }
                struct Envelope: Decodable {
                    let choices: [Choice]
                    struct Choice: Decodable { let message: Message }
                }
                let env = try Self.decoder.decode(Envelope.self, from: data)
                return env.choices.first?.message.content ?? ""
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ClientError.timeout
            }
            guard let first = try await group.next() else {
                throw ClientError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Request body

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let response_format: ResponseFormatBody?
        let max_tokens: Int
    }
    private struct ResponseFormatBody: Encodable {
        let type: String
    }
}
