import Foundation

/// Single-call Gemini client for vision pre-processing.
/// Sends a screenshot + a short user prompt; receives structured text back.
///
/// Endpoint: https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
/// Model:    gemini-3.1-flash-lite (cheap, fast, multimodal)
///
/// One call, one screenshot, structured JSON out. Used by `GeminiObserver`
/// as the only vision path — long-press never calls into Gemini directly;
/// it reads the accumulated `SurfaceMemoryStore` instead.
///
/// Note on context caching: we attempted to cache the static system prompt
/// via the `cachedContents` API, but `gemini-3.1-flash-lite` enforces a
/// minimum cache size of ~1,024 input tokens, and our system prompt is
/// ~400 tokens. The create-cache call would 400 on us. Skipping caching
/// until the prompt grows or the minimum drops.
public final class GeminiVisionClient {

    public static let shared = GeminiVisionClient()

    public static let defaultModel = "gemini-3.1-flash-lite"

    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static let bodyEncoder = JSONEncoder()
    private static let envelopeDecoder = JSONDecoder()

    public enum ClientError: Error, CustomStringConvertible {
        case missingAPIKey
        case timeout
        case httpStatus(Int, Data)
        case malformedResponse(String)
        public var description: String {
            switch self {
            case .missingAPIKey:    return "GEMINI_API_KEY not set"
            case .timeout:           return "Gemini request timed out"
            case .httpStatus(let c, let d):
                let preview = String(data: d, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
                return "Gemini HTTP \(c): \(preview)"
            case .malformedResponse(let s): return "Malformed Gemini response: \(s)"
            }
        }
    }

    /// Send a multimodal request (text prompt + one PNG image) and return the assistant's text.
    ///
    /// The `systemPrompt` is the static instruction block (would be cached if
    /// the API allowed); `userText` is the per-call tail (e.g. frontmost-app
    /// hint) that varies between requests. They're concatenated into a single
    /// text part for now since caching is disabled — see top-of-file note.
    public func generate(
        systemPrompt: String,
        userText: String,
        imagePNG: Data,
        model: String = GeminiVisionClient.defaultModel,
        timeout: TimeInterval = 60.0
    ) async throws -> String {
        let startedAt = Date()
        let combinedText: String = {
            let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? systemPrompt : systemPrompt + "\n" + trimmed
        }()

        do {
            let result = try await performRequest(
                systemPrompt: systemPrompt,
                userText: userText,
                imagePNG: imagePNG,
                model: model,
                timeout: timeout
            )
            AgentObservabilityLog.shared.record(.geminiCall(
                id: UUID(),
                t: startedAt,
                model: model,
                promptPreview: combinedText,
                imageBytes: imagePNG.count,
                responsePreview: result,
                latencyS: Date().timeIntervalSince(startedAt),
                success: true,
                httpStatus: 200
            ))
            return result
        } catch {
            let (responsePreview, status) = Self.describeError(error)
            AgentObservabilityLog.shared.record(.geminiCall(
                id: UUID(),
                t: startedAt,
                model: model,
                promptPreview: combinedText,
                imageBytes: imagePNG.count,
                responsePreview: responsePreview,
                latencyS: Date().timeIntervalSince(startedAt),
                success: false,
                httpStatus: status
            ))
            throw error
        }
    }

    /// Extract a human-readable error preview and HTTP status (if available) from
    /// any thrown error. Used by the observability path so failures show up in
    /// the DevTools timeline.
    private static func describeError(_ error: Error) -> (preview: String, status: Int?) {
        if let ce = error as? ClientError {
            switch ce {
            case .httpStatus(let code, let data):
                let body = String(data: data, encoding: .utf8).map { String($0.prefix(400)) } ?? "<binary>"
                return ("HTTP \(code): \(body)", code)
            case .missingAPIKey:
                return ("ERROR: GEMINI_API_KEY not set", nil)
            case .timeout:
                return ("ERROR: Gemini request timed out", nil)
            case .malformedResponse(let s):
                return ("ERROR: Malformed Gemini response: \(s)", nil)
            }
        }
        return ("ERROR: \(error)", nil)
    }

    /// Raw request — separated so the public `generate` wrapper can log both
    /// success and failure paths without duplicating HTTP/timeout logic.
    private func performRequest(
        systemPrompt: String,
        userText: String,
        imagePNG: Data,
        model: String,
        timeout: TimeInterval
    ) async throws -> String {
        guard let apiKey = Secrets.geminiAPIKey, !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout + 0.5

        let combinedText: String = {
            let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? systemPrompt : systemPrompt + "\n" + trimmed
        }()

        // Image-then-text part order: Google's single-image+text guidance.
        let body = RequestBody(
            contents: [
                Content(parts: [
                    .inlineData(InlineData(mimeType: "image/png", data: imagePNG.base64EncodedString())),
                    .text(combinedText)
                ])
            ],
            generationConfig: GenerationConfig(
                responseMimeType: "application/json",
                maxOutputTokens: 4000,
                mediaResolution: "MEDIA_RESOLUTION_HIGH",
                thinkingConfig: ThinkingConfig(thinkingBudget: 0)
            )
        )
        req.httpBody = try Self.bodyEncoder.encode(body)

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
                    let candidates: [Candidate]
                    struct Candidate: Decodable {
                        let content: Content
                        struct Content: Decodable {
                            let parts: [Part]
                            struct Part: Decodable { let text: String? }
                        }
                    }
                }
                let env = try Self.envelopeDecoder.decode(Envelope.self, from: data)
                return env.candidates.first?.content.parts.first?.text ?? ""
            }
            group.addTask {
                // 60s * 1e9 = 6e10, well under UInt64.max (~1.8e19). Safe.
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

    // MARK: - Request shapes

    private struct RequestBody: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig
        enum CodingKeys: String, CodingKey {
            case contents
            case generationConfig = "generation_config"
        }
    }
    private struct Content: Encodable {
        let parts: [Part]
    }
    private enum Part: Encodable {
        case text(String)
        case inlineData(InlineData)
        enum CodingKeys: String, CodingKey { case text, inlineData = "inline_data" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):    try c.encode(s, forKey: .text)
            case .inlineData(let d): try c.encode(d, forKey: .inlineData)
            }
        }
    }
    private struct InlineData: Encodable {
        let mimeType: String
        let data: String
        enum CodingKeys: String, CodingKey { case mimeType = "mime_type", data }
    }
    private struct GenerationConfig: Encodable {
        let responseMimeType: String
        let maxOutputTokens: Int
        let mediaResolution: String
        /// `thinking_config` lives INSIDE `generation_config` per Google's
        /// v1beta API schema, not at the top level. Sending it at the top
        /// level produces HTTP 400 "Unknown name 'thinking_config'".
        let thinkingConfig: ThinkingConfig
        enum CodingKeys: String, CodingKey {
            case responseMimeType = "response_mime_type"
            case maxOutputTokens = "max_output_tokens"
            case mediaResolution = "media_resolution"
            case thinkingConfig = "thinking_config"
        }
    }
    private struct ThinkingConfig: Encodable {
        let thinkingBudget: Int
        enum CodingKeys: String, CodingKey { case thinkingBudget = "thinking_budget" }
    }
}
