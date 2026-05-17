//
//  AnthropicClient.swift
//  Agent in the Notch
//
//  Thin HTTP client for Anthropic Messages API with computer-use beta.
//  No streaming for now — full response per turn keeps the loop simple.
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

    // swiftlint:disable:next force_unwrapping — hardcoded literal, never nil
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let sharedEncoder = JSONEncoder()
    private static let sharedDecoder = JSONDecoder()

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = AnthropicClient.defaultEndpoint,
        // No computer-use beta in the default — the harness picks it per
        // current model (Haiku uses 2025-01-24, Sonnet 4.6 / Opus 4.x use
        // 2025-11-24) and prepends it. Hardcoding it here would force a
        // mismatch when the user picks a model from the other family.
        betaHeaders: [String] = ["prompt-caching-2024-07-31", "interleaved-thinking-2025-05-14"]
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.betaHeaders = betaHeaders
    }

    public func send(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betaHeaders.isEmpty {
            req.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }

        do {
            req.httpBody = try Self.sharedEncoder.encode(request)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }

        log.info("anthropic.request model=\(request.model) messages=\(request.messages.count) max_tokens=\(request.maxTokens)")
        let (data, response): (Data, URLResponse)
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

    /// Plain text → text helper. Used by callers (e.g. the context reducer)
    /// that only need single-shot synthesis with no tools and no beta headers.
    /// Returns the concatenated text content from the response. Throws on a
    /// non-2xx response, transport failure, or empty content.
    public func sendPlainText(
        model: String,
        system: String?,
        userText: String,
        maxTokens: Int
    ) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Deliberately no anthropic-beta header — this path is plain messages.

        struct PlainMessage: Encodable {
            let role: String
            let content: String
        }
        struct PlainRequest: Encodable {
            let model: String
            let maxTokens: Int
            let system: String?
            let messages: [PlainMessage]
            enum CodingKeys: String, CodingKey {
                case model
                case maxTokens = "max_tokens"
                case system
                case messages
            }
        }

        let payload = PlainRequest(
            model: model,
            maxTokens: maxTokens,
            system: system,
            messages: [PlainMessage(role: "user", content: userText)]
        )

        do {
            req.httpBody = try Self.sharedEncoder.encode(payload)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }

        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            throw Error(status: http?.statusCode, body: bodyString, underlying: nil)
        }

        let decoded: AnthropicMessageResponse
        do {
            decoded = try Self.sharedDecoder.decode(AnthropicMessageResponse.self, from: data)
        } catch {
            let bodyString = String(data: data, encoding: .utf8)
            throw Error(status: http.statusCode, body: bodyString, underlying: error)
        }

        for case .text(let t) in decoded.content
            where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        throw Error(status: http.statusCode, body: "no text content block", underlying: nil)
    }
}
