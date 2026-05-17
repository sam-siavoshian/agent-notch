import Foundation

/// Single-call Gemini client for vision pre-processing at long-press time.
/// Sends a screenshot + a short user prompt; receives structured text back.
///
/// Endpoint: https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
/// Model:    gemini-3.1-flash-lite (cheap, fast, multimodal)
///
/// This is a deliberate REPLACEMENT for the old Gemini observation pipeline
/// (deleted in Phase 5b). That one fanned out across 6 lanes per screenshot.
/// This one is one call, one screenshot, structured JSON out. Used by
/// `VisionEnricher` and only at long-press time.
public final class GeminiVisionClient {

    public static let shared = GeminiVisionClient()

    public static let defaultModel = "gemini-3.1-flash-lite"

    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

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

    /// Send a multimodal request (text prompt + one JPEG image) and return the assistant's text.
    public func generate(
        prompt: String,
        imageJPEG: Data,
        model: String = GeminiVisionClient.defaultModel,
        timeout: TimeInterval = 1.5
    ) async throws -> String {
        guard let apiKey = Secrets.geminiAPIKey, !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout + 0.5

        let body = RequestBody(
            contents: [
                Content(parts: [
                    .text(prompt),
                    .inlineData(InlineData(mimeType: "image/jpeg", data: imageJPEG.base64EncodedString()))
                ])
            ],
            generationConfig: GenerationConfig(responseMimeType: "application/json", maxOutputTokens: 800)
        )
        req.httpBody = try JSONEncoder().encode(body)

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

    // MARK: - Request shapes

    private struct RequestBody: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig
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
        enum CodingKeys: String, CodingKey { case responseMimeType = "response_mime_type", maxOutputTokens = "max_output_tokens" }
    }
}
