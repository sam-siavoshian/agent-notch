//
//  ComputerUseModels.swift
//  Agent in the Notch
//
//  Codable types for Anthropic Messages API with computer-use beta tool.
//  Schema reference: https://docs.anthropic.com/en/docs/agents-and-tools/computer-use
//

import Foundation

public enum AnthropicModel {
    public static let haiku45 = "claude-haiku-4-5-20251001"
    public static let sonnet46 = "claude-sonnet-4-6"
    public static let opus47 = "claude-opus-4-7"
}

/// Anthropic prompt cache marker. Server caches everything up to and including
/// the block this is attached to. Only the 4 most recent breakpoints count, so
/// the harness keeps one rolling marker on the latest screenshot.
public struct CacheControl: Codable, Sendable {
    public var type: String
    public init(type: String = "ephemeral") { self.type = type }
}

public struct SystemBlock: Codable, Sendable {
    public var type: String
    public var text: String
    public var cacheControl: CacheControl?

    public init(text: String, cache: Bool = false) {
        self.type = "text"
        self.text = text
        self.cacheControl = cache ? CacheControl() : nil
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }
}

public struct ThinkingConfig: Codable, Sendable {
    public var type: String
    public var budgetTokens: Int
    public init(budgetTokens: Int) {
        self.type = "enabled"
        self.budgetTokens = budgetTokens
    }
    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

public struct AnthropicMessageRequest: Codable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: [SystemBlock]?
    public var messages: [Message]
    public var tools: [Tool]
    public var toolChoice: ToolChoice?
    public var thinking: ThinkingConfig?

    public init(
        model: String,
        maxTokens: Int,
        system: [SystemBlock]?,
        messages: [Message],
        tools: [Tool],
        toolChoice: ToolChoice? = nil,
        thinking: ThinkingConfig? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.thinking = thinking
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
        case thinking
    }

    public struct ToolChoice: Codable, Sendable {
        public var type: String // "auto" | "any" | "tool" | "none"
        public init(type: String) { self.type = type }
    }
}

public enum Tool: Sendable {
    case computer(displayWidth: Int, displayHeight: Int, displayNumber: Int?, cache: Bool = false)
    case custom(name: String, description: String, inputSchema: JSON, cache: Bool = false)

    private enum Keys: String, CodingKey {
        case type, name, description
        case displayWidth = "display_width_px"
        case displayHeight = "display_height_px"
        case displayNumber = "display_number"
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }
}

extension Tool: Codable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .computer(let w, let h, let n, let cache):
            try c.encode("computer_20250124", forKey: .type)
            try c.encode("computer", forKey: .name)
            try c.encode(w, forKey: .displayWidth)
            try c.encode(h, forKey: .displayHeight)
            if let n { try c.encode(n, forKey: .displayNumber) }
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        case .custom(let name, let desc, let schema, let cache):
            try c.encode("custom", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(desc, forKey: .description)
            try c.encode(schema, forKey: .inputSchema)
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "computer_20251124", "computer_20250124":
            let w = try c.decode(Int.self, forKey: .displayWidth)
            let h = try c.decode(Int.self, forKey: .displayHeight)
            let n = try? c.decode(Int.self, forKey: .displayNumber)
            self = .computer(displayWidth: w, displayHeight: h, displayNumber: n, cache: false)
        case "custom":
            let name = try c.decode(String.self, forKey: .name)
            let desc = (try? c.decode(String.self, forKey: .description)) ?? ""
            let schema = (try? c.decode(JSON.self, forKey: .inputSchema)) ?? .object([:])
            self = .custom(name: name, description: desc, inputSchema: schema, cache: false)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown tool type \(type)"
            )
        }
    }
}

public struct Message: Codable, Sendable {
    public var role: String // "user" | "assistant"
    public var content: [ContentBlock]

    public init(role: String, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }
}

public enum ContentBlock: Codable, Sendable {
    case text(String)
    case image(mediaType: String, base64: String, cache: Bool = false)
    case toolUse(id: String, name: String, input: JSON)
    case toolResult(toolUseId: String, content: [ContentBlock], isError: Bool, cache: Bool = false)
    case thinking(thinking: String, signature: String)
    case redactedThinking(data: String)

    private enum Keys: String, CodingKey {
        case type, text
        case source
        case id, name, input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
        case cacheControl = "cache_control"
        case thinking, signature, data
    }

    private enum SourceKeys: String, CodingKey {
        case type, mediaType = "media_type", data
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .image(let media, let b64, let cache):
            try c.encode("image", forKey: .type)
            var sc = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try sc.encode("base64", forKey: .type)
            try sc.encode(media, forKey: .mediaType)
            try sc.encode(b64, forKey: .data)
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let tid, let content, let isError, let cache):
            try c.encode("tool_result", forKey: .type)
            try c.encode(tid, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .isError) }
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        case .thinking(let t, let sig):
            try c.encode("thinking", forKey: .type)
            try c.encode(t, forKey: .thinking)
            try c.encode(sig, forKey: .signature)
        case .redactedThinking(let data):
            try c.encode("redacted_thinking", forKey: .type)
            try c.encode(data, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            let sc = try c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            let media = try sc.decode(String.self, forKey: .mediaType)
            let data = try sc.decode(String.self, forKey: .data)
            self = .image(mediaType: media, base64: data, cache: false)
        case "tool_use":
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let input = try c.decode(JSON.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let tid = try c.decode(String.self, forKey: .toolUseId)
            let content = (try? c.decode([ContentBlock].self, forKey: .content)) ?? []
            let isError = (try? c.decode(Bool.self, forKey: .isError)) ?? false
            self = .toolResult(toolUseId: tid, content: content, isError: isError, cache: false)
        case "thinking":
            let t = (try? c.decode(String.self, forKey: .thinking)) ?? ""
            let sig = (try? c.decode(String.self, forKey: .signature)) ?? ""
            self = .thinking(thinking: t, signature: sig)
        case "redacted_thinking":
            let d = (try? c.decode(String.self, forKey: .data)) ?? ""
            self = .redactedThinking(data: d)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown content block type \(type)"
            )
        }
    }

    /// Return a copy of this block with cache_control set. Only meaningful for
    /// image and toolResult cases — others return self unchanged.
    public func withCache(_ on: Bool = true) -> ContentBlock {
        switch self {
        case .image(let m, let b, _): return .image(mediaType: m, base64: b, cache: on)
        case .toolResult(let id, let c, let e, _): return .toolResult(toolUseId: id, content: c, isError: e, cache: on)
        default: return self
        }
    }
}

public struct AnthropicMessageResponse: Codable, Sendable {
    public var id: String
    public var model: String
    public var role: String
    public var content: [ContentBlock]
    public var stopReason: String?
    public var usage: Usage?

    public struct Usage: Codable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheCreationInputTokens: Int?
        public var cacheReadInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, model, role, content, usage
        case stopReason = "stop_reason"
    }
}

/// Lightweight JSON value type for tool input/output dictionaries.
public indirect enum JSON: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v } else { return nil }
    }
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v } else { return nil }
    }
    public var arrayValue: [JSON]? {
        if case .array(let v) = self { return v } else { return nil }
    }
    public var objectValue: [String: JSON]? {
        if case .object(let v) = self { return v } else { return nil }
    }
}
