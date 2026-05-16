//
//  AnthropicClient.swift
//  Agent in the Notch
//
//  Thin HTTP client for Anthropic Messages API with computer-use beta.
//  No streaming for now — full response per turn keeps the loop simple.
//

import Foundation

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

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        betaHeaders: [String] = ["computer-use-2025-11-24"]
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

        let encoder = JSONEncoder()
        do {
            req.httpBody = try encoder.encode(request)
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

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AnthropicMessageResponse.self, from: data)
        } catch {
            let bodyString = String(data: data, encoding: .utf8)
            throw Error(status: http.statusCode, body: bodyString, underlying: error)
        }
    }
}
