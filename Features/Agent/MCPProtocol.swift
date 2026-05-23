//
//  MCPProtocol.swift
//  Agent in the Notch
//
//  Minimal JSON-RPC 2.0 + Model Context Protocol message shapes used by the
//  in-app `MCPBridge` server to expose AgentNotch's computer-use tools to a
//  spawned `claude` subprocess. Only the surface area we actually serve is
//  modeled here — not the full MCP spec — to keep parsing surface small.
//
//  Methods implemented by the bridge:
//    - "initialize"        — handshake; advertises tools capability.
//    - "notifications/initialized" (notification — no response)
//    - "tools/list"        — returns the catalog the harness uses today.
//    - "tools/call"        — routes name + arguments into ToolDispatcher.
//
//  Anything else falls through to a JSON-RPC -32601 "Method not found".
//

import Foundation

public enum MCP {
    // MARK: - JSON-RPC envelope

    /// JSON-RPC 2.0 has three message shapes (request / response / notification)
    /// that share the same top-level `jsonrpc` + `id` fields. We decode the
    /// envelope first and then re-encode the inner `params` / `result` blob
    /// per method.
    public struct Envelope: Decodable {
        public let jsonrpc: String
        public let id: JSONRPCID?
        public let method: String?
        public let params: JSON?
        public let result: JSON?
        public let error: JSONRPCError?
    }

    /// JSON-RPC ids may be string, number, or null. Encoded back exactly as
    /// received so the client correlates response to request.
    public enum JSONRPCID: Codable, Sendable, Hashable {
        case string(String)
        case int(Int)
        case null

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Int.self) { self = .int(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be string|int|null")
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null:          try c.encodeNil()
            case .int(let v):    try c.encode(v)
            case .string(let v): try c.encode(v)
            }
        }
    }

    public struct JSONRPCError: Codable, Sendable {
        public let code: Int
        public let message: String
        public let data: JSON?

        public init(code: Int, message: String, data: JSON? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        public static let parseError      = JSONRPCError(code: -32700, message: "Parse error")
        public static let invalidRequest  = JSONRPCError(code: -32600, message: "Invalid Request")
        public static let methodNotFound  = JSONRPCError(code: -32601, message: "Method not found")
        public static let invalidParams   = JSONRPCError(code: -32602, message: "Invalid params")
        public static let internalError   = JSONRPCError(code: -32603, message: "Internal error")
    }

    /// Wire response. Encoded with `result` OR `error` set, never both.
    public struct Response: Encodable {
        public let jsonrpc: String
        public let id: JSONRPCID
        public let result: JSON?
        public let error: JSONRPCError?

        public init(id: JSONRPCID, result: JSON) {
            self.jsonrpc = "2.0"
            self.id = id
            self.result = result
            self.error = nil
        }

        public init(id: JSONRPCID, error: JSONRPCError) {
            self.jsonrpc = "2.0"
            self.id = id
            self.result = nil
            self.error = error
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(jsonrpc, forKey: .jsonrpc)
            try c.encode(id,      forKey: .id)
            if let result { try c.encode(result, forKey: .result) }
            if let error  { try c.encode(error,  forKey: .error) }
        }

        private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
    }

    // MARK: - MCP types (subset)

    /// Static tool descriptor returned in `tools/list`. `inputSchema` is a JSON
    /// Schema dict; clients use it to decide how to call the tool. Annotations
    /// (readOnlyHint, destructiveHint, etc) are optional and not modeled — we
    /// rely on `--allowedTools` for safety, not annotation hints.
    public struct ToolDescriptor: Encodable {
        public let name: String
        public let description: String
        public let inputSchema: JSON

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "inputSchema"
        }
    }

    /// Content item inside a `tools/call` response. `text`, `image`, and
    /// `resource` are the three MCP variants; we emit text + image only.
    public enum ContentItem: Encodable {
        case text(String)
        case image(base64: String, mimeType: String)

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .image(let b64, let mime):
                try c.encode("image", forKey: .type)
                try c.encode(b64, forKey: .data)
                try c.encode(mime, forKey: .mimeType)
            }
        }

        private enum CodingKeys: String, CodingKey { case type, text, data, mimeType }
    }

    public struct CallToolResult: Encodable {
        public let content: [ContentItem]
        public let isError: Bool

        public init(content: [ContentItem], isError: Bool = false) {
            self.content = content
            self.isError = isError
        }

        enum CodingKeys: String, CodingKey {
            case content
            case isError = "isError"
        }
    }
}

private struct MCPToolsListWrapper: Encodable { let tools: [MCP.ToolDescriptor] }

extension Array where Element == MCP.ToolDescriptor {
    func asResultJSON() throws -> JSON {
        try JSON.from(MCPToolsListWrapper(tools: self))
    }
}
