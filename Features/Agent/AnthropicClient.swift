//
//  AnthropicClient.swift
//
//  Thin HTTP client for Anthropic Messages API (no streaming).
//

import Foundation

private let log = Log(category: "anthropic")

public struct AnthropicClient: Sendable {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let status: Int?
        public let body: String?
        public let underlying: (any Swift.Error)?
        public var description: String {
            "AnthropicClient.Error(status: \(status.map(String.init) ?? "nil"), body: \(body ?? "nil"), underlying: \(underlying.map { "\($0)" } ?? "nil"))"
        }
    }

    public var apiKey: String
    public var session: URLSession
    public var endpoint: URL
    public var betaHeaders: [String]

    // swiftlint:disable:next force_unwrapping — hardcoded literal
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let sharedEncoder = JSONEncoder()
    private static let sharedDecoder = JSONDecoder()

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = AnthropicClient.defaultEndpoint,
        // Computer-use beta omitted by default: the harness picks the
        // model-family-specific header and prepends it; a hardcoded default
        // would mismatch the other family.
        betaHeaders: [String] = ["prompt-caching-2024-07-31", "interleaved-thinking-2025-05-14"]
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.betaHeaders = betaHeaders
    }

    public func send(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        log.info("anthropic.request model=\(request.model) messages=\(request.messages.count) max_tokens=\(request.maxTokens)")
        return try await post(request, includeBetaHeaders: true)
    }

    /// Plain text → text helper for single-shot synthesis (no tools, no beta).
    /// Returns the first non-empty text block from the response.
    public func sendPlainText(
        model: String,
        system: String?,
        userText: String,
        maxTokens: Int
    ) async throws -> String {
        struct PlainMessage: Encodable { let role: String; let content: String }
        struct PlainRequest: Encodable {
            let model: String
            let maxTokens: Int
            let system: String?
            let messages: [PlainMessage]
            enum CodingKeys: String, CodingKey {
                case model, system, messages
                case maxTokens = "max_tokens"
            }
        }
        let payload = PlainRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: [PlainMessage(role: "user", content: userText)]
        )
        let decoded: AnthropicMessageResponse = try await post(payload, includeBetaHeaders: false)
        for case .text(let t) in decoded.content
            where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        throw Error(status: nil, body: "no text content block", underlying: nil)
    }

    private func post<Body: Encodable>(_ body: Body, includeBetaHeaders: Bool) async throws -> AnthropicMessageResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if includeBetaHeaders, !betaHeaders.isEmpty {
            req.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        do {
            req.httpBody = try Self.sharedEncoder.encode(body)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            log.error("anthropic.network_error error=\(error)")
            throw Error(status: nil, body: nil, underlying: error)
        }

        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            log.error("anthropic.http_error status=\(http?.statusCode ?? -1) body=\(bodyString ?? "nil")")
            throw Error(status: http?.statusCode, body: bodyString, underlying: nil)
        }
        log.info("anthropic.response status=\(http.statusCode) body_bytes=\(data.count)")
        do {
            return try Self.sharedDecoder.decode(AnthropicMessageResponse.self, from: data)
        } catch {
            let bodyString = String(data: data, encoding: .utf8)
            log.error("anthropic.decode_error status=\(http.statusCode) body=\(bodyString ?? "nil") error=\(error)")
            throw Error(status: http.statusCode, body: bodyString, underlying: error)
        }
    }
}
