//
//  AnthropicClient.swift
//  Agent in the Notch
//
//  Thin HTTP client for Anthropic Messages API with computer-use beta.
//  Two transports:
//    - send(_:)          → non-streaming, full response per turn.
//                          Used by the verifier + sendPlainText helper.
//    - sendStreaming(_:) → SSE stream of StreamEvents. Used by the harness
//                          main loop so text deltas can drive TTS and the
//                          final response is assembled from the stream.
//
//  All transient HTTP failures (429 / 500 / 529) are retried with exponential
//  backoff + jitter; 429 honors the Retry-After response header.
//
//  JSON encoder pins .sortedKeys so request bodies are byte-stable across
//  turns — prompt caching breaks on any byte-level diff in cached prefix.
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

    /// `.sortedKeys` is load-bearing for prompt caching: Anthropic hashes the
    /// raw request prefix to find the cache entry. Swift's default JSON encoder
    /// emits dictionary keys in unspecified order, so without this every turn's
    /// cache key would differ and cache_read_input_tokens would always be 0.
    private static let sharedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let sharedDecoder = JSONDecoder()

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = AnthropicClient.defaultEndpoint,
        // No computer-use beta in the default — the harness picks it per
        // current model (Haiku uses 2025-01-24, Sonnet 4.6 / Opus 4.x use
        // 2025-11-24) and prepends it. Hardcoding it here would force a
        // mismatch when the user picks a model from the other family.
        betaHeaders: [String] = ["prompt-caching-2024-07-31"]
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.betaHeaders = betaHeaders
    }

    // MARK: - Non-streaming

    public func send(_ request: AnthropicMessageRequest) async throws -> AnthropicMessageResponse {
        return try await withRetry { attempt in
            try await self.sendOnce(request, attempt: attempt)
        }
    }

    private func sendOnce(_ request: AnthropicMessageRequest, attempt: Int) async throws -> AnthropicMessageResponse {
        let req = try buildRequest(body: request, stream: false)
        log.info("anthropic.request attempt=\(attempt) model=\(request.model) messages=\(request.messages.count) max_tokens=\(request.maxTokens) stream=false")

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

    // MARK: - Streaming

    /// Returns an async stream of StreamEvents. The harness can react to deltas
    /// live (e.g. pipe `.text(_)` into TTS) and assemble the full response from
    /// the stream as it completes. Retries on 429/500/529 BEFORE the stream
    /// starts; once bytes are flowing, network failures throw into the stream.
    public func sendStreaming(_ request: AnthropicMessageRequest) -> AsyncThrowingStream<StreamEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamWithRetry(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamWithRetry(
        _ request: AnthropicMessageRequest,
        continuation: AsyncThrowingStream<StreamEvent, Swift.Error>.Continuation
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await streamOnce(request, attempt: attempt, continuation: continuation)
                return
            } catch let err as Error {
                guard let delay = retryDelay(for: err, attempt: attempt) else { throw err }
                log.warning("anthropic.stream_retry attempt=\(attempt) status=\(err.status ?? -1) sleep_ms=\(Int(delay * 1000))")
                try await Task.sleep(for: .seconds(delay))
                continue
            }
        }
    }

    private func streamOnce(
        _ request: AnthropicMessageRequest,
        attempt: Int,
        continuation: AsyncThrowingStream<StreamEvent, Swift.Error>.Continuation
    ) async throws {
        var streaming = request
        streaming.stream = true

        let req = try buildRequest(body: streaming, stream: true)
        log.info("anthropic.request attempt=\(attempt) model=\(request.model) messages=\(request.messages.count) max_tokens=\(request.maxTokens) stream=true")

        let (byteStream, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (byteStream, response) = try await session.bytes(for: req)
        } catch {
            log.error("anthropic.network_error error=\(error)")
            throw Error(status: nil, body: nil, underlying: error)
        }

        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            // Drain a small body for the error message so 429s show context.
            var body = ""
            for try await line in byteStream.lines {
                body += line + "\n"
                if body.count > 4096 { break }
            }
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
            log.error("anthropic.http_error status=\(http?.statusCode ?? -1) retry_after=\(retryAfter ?? "nil") body=\(body)")
            throw Error(status: http?.statusCode, body: body.isEmpty ? nil : body, underlying: nil)
        }

        // SSE parser. Events are separated by blank lines. We only care about
        // `data: <json>` lines — the `event:` name is duplicated inside the
        // JSON payload's `type` field, so we ignore the event header.
        for try await line in byteStream.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { return }
            if let event = StreamEventDecoder.decode(payload) {
                continuation.yield(event)
            }
        }
    }

    // MARK: - Retry policy

    /// Wraps a single send attempt with backoff for 429/500/529.
    private func withRetry<T>(_ op: (Int) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await op(attempt)
            } catch let err as Error {
                guard let delay = retryDelay(for: err, attempt: attempt) else { throw err }
                log.warning("anthropic.retry attempt=\(attempt) status=\(err.status ?? -1) sleep_ms=\(Int(delay * 1000))")
                try await Task.sleep(for: .seconds(delay))
                continue
            }
        }
    }

    /// Returns seconds to wait before retry, or nil for non-retriable errors.
    /// 429: honors Retry-After header value if present, falls back to exp+jitter.
    /// 500: small backoff, up to 2 retries.
    /// 529: longer backoff for cross-tenant overload, up to 3 retries.
    /// Anything else: no retry.
    private func retryDelay(for err: Error, attempt: Int) -> TimeInterval? {
        guard let status = err.status else { return nil }
        let jitter = Double.random(in: 0...0.4)
        switch status {
        case 429:
            if attempt > 3 { return nil }
            if let body = err.body,
               let retryAfter = Self.parseRetryAfterFromBody(body) {
                return min(retryAfter + jitter, 30)
            }
            // 1s -> 4s -> 16s
            return [1.0, 4.0, 16.0][min(attempt - 1, 2)] + jitter
        case 500, 502, 503, 504:
            if attempt > 2 { return nil }
            return [0.25, 1.0][min(attempt - 1, 1)] + jitter
        case 529:
            if attempt > 3 { return nil }
            return [1.0, 4.0, 16.0][min(attempt - 1, 2)] + jitter
        default:
            return nil
        }
    }

    private static func parseRetryAfterFromBody(_ body: String) -> TimeInterval? {
        // Anthropic occasionally surfaces a wait hint inside JSON error bodies.
        // Best-effort scrape; we'd rather use the HTTP header but URLSession
        // does not currently expose response headers on error paths in bytes(for:).
        if let range = body.range(of: "\"retry_after\":\\s*(\\d+)", options: .regularExpression) {
            let match = String(body[range])
            if let numRange = match.range(of: "\\d+", options: .regularExpression),
               let value = Double(match[numRange]) {
                return value
            }
        }
        return nil
    }

    // MARK: - Request construction

    private func buildRequest(body: AnthropicMessageRequest, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if !betaHeaders.isEmpty {
            req.setValue(betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        do {
            req.httpBody = try Self.sharedEncoder.encode(body)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }
        return req
    }

    // MARK: - Plain-text helper (verifier)

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
