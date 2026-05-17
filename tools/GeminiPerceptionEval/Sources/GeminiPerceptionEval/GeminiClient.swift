import Foundation

/// Stripped-down Gemini vision client for the perception eval CLI.
///
/// Copied (and trimmed) from `Features/Context/GeminiVisionClient.swift` so the
/// CLI is self-contained — no dependency on the app target. The wire shape
/// (request body, snake_case keys, image-then-text part order, response envelope)
/// must stay in lockstep with the live client, or the eval scores something
/// different than what production sends.
public final class GeminiClient {

    public static let defaultModel = "gemini-3.1-flash-lite"

    public let session: URLSession
    public let apiKey: String

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// One knob set per variant. `mediaResolution` is required;
    /// `thinkingBudget == nil` means "omit thinking_config entirely".
    public struct Variant: Equatable, Sendable {
        public let name: String
        public let mediaResolution: String        // e.g. "MEDIA_RESOLUTION_HIGH"
        public let thinkingBudget: Int?           // nil = omit
        public let maxOutputTokens: Int
        public init(name: String, mediaResolution: String, thinkingBudget: Int?, maxOutputTokens: Int = 4000) {
            self.name = name
            self.mediaResolution = mediaResolution
            self.thinkingBudget = thinkingBudget
            self.maxOutputTokens = maxOutputTokens
        }

        /// Resolve a variant by short name. Returns nil for unknown variants.
        public static func named(_ name: String) -> Variant? {
            switch name {
            case "high-min":
                return Variant(name: name, mediaResolution: "MEDIA_RESOLUTION_HIGH", thinkingBudget: 0)
            case "ultra-min":
                return Variant(name: name, mediaResolution: "MEDIA_RESOLUTION_ULTRA_HIGH", thinkingBudget: 0)
            case "high-default":
                return Variant(name: name, mediaResolution: "MEDIA_RESOLUTION_HIGH", thinkingBudget: nil)
            case "medium-min":
                return Variant(name: name, mediaResolution: "MEDIA_RESOLUTION_MEDIUM", thinkingBudget: 0)
            case "ultra-default":
                // Mentioned in CLI usage examples but not in the official variant list.
                // Treat as ultra-high + no thinking config for completeness.
                return Variant(name: name, mediaResolution: "MEDIA_RESOLUTION_ULTRA_HIGH", thinkingBudget: nil)
            default:
                return nil
            }
        }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case timeout
        case httpStatus(Int, Data)
        case malformedResponse(String)
        public var description: String {
            switch self {
            case .timeout: return "Gemini request timed out"
            case .httpStatus(let c, let d):
                let preview = String(data: d, encoding: .utf8).map { String($0.prefix(200)) } ?? "<binary>"
                return "Gemini HTTP \(c): \(preview)"
            case .malformedResponse(let s): return "Malformed Gemini response: \(s)"
            }
        }
    }

    /// Returns the raw JSON-encoded request body for a (prompt, image, variant) tuple.
    /// Used by dry-mode to print the exact payload without making a network call.
    public static func encodeBody(prompt: String, imagePNG: Data, variant: Variant) throws -> Data {
        let body = RequestBody(
            contents: [
                Content(parts: [
                    .inlineData(InlineData(mimeType: "image/png", data: imagePNG.base64EncodedString())),
                    .text(prompt)
                ])
            ],
            generationConfig: GenerationConfig(
                responseMimeType: "application/json",
                maxOutputTokens: variant.maxOutputTokens,
                mediaResolution: variant.mediaResolution
            ),
            thinkingConfig: variant.thinkingBudget.map { ThinkingConfig(thinkingBudget: $0) }
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(body)
    }

    /// Make a live request and return the assistant's text part.
    public func generate(
        prompt: String,
        imagePNG: Data,
        variant: Variant,
        model: String = GeminiClient.defaultModel,
        timeout: TimeInterval = 60.0
    ) async throws -> String {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout + 0.5
        req.httpBody = try Self.encodeBody(prompt: prompt, imagePNG: imagePNG, variant: variant)

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
                let env = try JSONDecoder().decode(Envelope.self, from: data)
                return env.candidates.first?.content.parts.first?.text ?? ""
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

    // MARK: - Wire shapes (must mirror GeminiVisionClient.swift)

    private struct RequestBody: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig
        let thinkingConfig: ThinkingConfig?
        enum CodingKeys: String, CodingKey {
            case contents
            case generationConfig = "generation_config"
            case thinkingConfig = "thinking_config"
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(contents, forKey: .contents)
            try c.encode(generationConfig, forKey: .generationConfig)
            // Only emit thinking_config if explicitly set — omitting it falls back to model default.
            if let t = thinkingConfig {
                try c.encode(t, forKey: .thinkingConfig)
            }
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
            case .text(let s):       try c.encode(s, forKey: .text)
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
        enum CodingKeys: String, CodingKey {
            case responseMimeType = "response_mime_type"
            case maxOutputTokens = "max_output_tokens"
            case mediaResolution = "media_resolution"
        }
    }
    private struct ThinkingConfig: Encodable {
        let thinkingBudget: Int
        enum CodingKeys: String, CodingKey { case thinkingBudget = "thinking_budget" }
    }
}
