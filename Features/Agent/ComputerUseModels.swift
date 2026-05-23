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
/// the block this is attached to. Only the 4 most recent breakpoints count;
/// the harness uses one on the system block + three rolling on the last
/// content block of each of the 3 most recent user messages
/// (see `ComputerUseHarness.injectPromptCaching`).
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
    /// SSE streaming flag. nil = non-streaming (full response). true = server
    /// returns text/event-stream — caller must use AnthropicClient.sendStreaming.
    public var stream: Bool?

    public init(
        model: String,
        maxTokens: Int,
        system: [SystemBlock]?,
        messages: [Message],
        tools: [Tool],
        toolChoice: ToolChoice? = nil,
        thinking: ThinkingConfig? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
        case thinking
        case stream
    }

    public struct ToolChoice: Codable, Sendable {
        public var type: String // "auto" | "any" | "tool" | "none"
        public init(type: String) { self.type = type }
    }
}

public enum Tool: Sendable {
    /// `toolType` is the wire-protocol string Anthropic expects (e.g.
    /// "computer_20250124" for Haiku 4.5, "computer_20251124" for Sonnet 4.6
    /// and Opus 4.x). Must match the `computer-use-*` beta header on the
    /// request — see `AgentModel.computerUseToolType`.
    case computer(displayWidth: Int, displayHeight: Int, displayNumber: Int?, cache: Bool = false, toolType: String)
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
        case .computer(let w, let h, let n, let cache, let toolType):
            try c.encode(toolType, forKey: .type)
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
            self = .computer(displayWidth: w, displayHeight: h, displayNumber: n, cache: false, toolType: type)
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

    /// Round-trip an `Encodable` value through JSON into the enum so callers
    /// don't reinvent the encoder/decoder dance every time they need to plumb
    /// an MCP response or tool schema through the in-memory form.
    public static func from<E: Encodable>(_ value: E) throws -> JSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSON.self, from: data)
    }

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

    /// Shared decoder for `parse(_:)`. Reused so we don't allocate one per call
    /// on hot paths (stream tool-use input reassembly, MCP envelope reads).
    private static let stringDecoder = JSONDecoder()

    /// Decode a JSON string into a `JSON` value. Throws on malformed input
    /// (caller decides whether to fall back). Use this everywhere we accept a
    /// JSON-as-string payload (stream input_json_delta reassembly, MCP wire
    /// format) so the failure mode is uniform.
    public static func parse(_ raw: String) throws -> JSON {
        guard let data = raw.data(using: .utf8) else {
            throw NSError(
                domain: "JSON.parse",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "input is not valid UTF-8"]
            )
        }
        return try Self.stringDecoder.decode(JSON.self, from: data)
    }
}

// MARK: - Streaming

/// One server-sent event from Anthropic's streaming Messages API. Reference:
/// https://docs.anthropic.com/en/docs/build-with-claude/streaming
///
/// The harness assembles a full `AnthropicMessageResponse` from these as the
/// stream completes, but exposes the deltas live so TTS can start speaking on
/// the first `text_delta` instead of waiting for the entire turn.
public enum StreamEvent: Sendable {
    /// Initial envelope. `message` carries id/model/role with usage prefilled
    /// (input_tokens + cache fields) but empty content.
    case messageStart(message: AnthropicMessageResponse)
    /// A new content block is opening at this index. The block is the
    /// "empty shell" (text=""; tool_use with input={}, etc.).
    case contentBlockStart(index: Int, block: ContentBlock)
    /// A delta against the content block at `index`. Variants:
    /// `.text(_)` for text_delta, `.thinking(_)` for thinking_delta,
    /// `.signature(_)` for signature_delta on a thinking block,
    /// `.partialJSON(_)` for input_json_delta on a tool_use block.
    case contentBlockDelta(index: Int, delta: BlockDelta)
    case contentBlockStop(index: Int)
    /// End-of-turn metadata. `stopReason` is the final stop_reason; usage's
    /// `outputTokens` is authoritative (input_tokens was on messageStart).
    case messageDelta(stopReason: String?, stopSequence: String?, outputTokens: Int?)
    case messageStop
    case ping
    case streamError(type: String, message: String)

    public enum BlockDelta: Sendable {
        case text(String)
        case thinking(String)
        case signature(String)
        case partialJSON(String)
    }
}

/// Parses a single `data: <json>` payload into a `StreamEvent`. The line's
/// `event:` header is encoded in the payload's `type` field — Anthropic always
/// duplicates it there — so the parser doesn't need the SSE event name.
/// Returns nil for unknown payloads (forward-compat with future event types).
public enum StreamEventDecoder {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    public static func decode(_ jsonString: String) -> StreamEvent? {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }
        switch type {
        case "message_start":
            guard let msg = obj["message"] as? [String: Any],
                  let raw = try? JSONSerialization.data(withJSONObject: msg),
                  let response = try? decoder.decode(AnthropicMessageResponse.self, from: raw) else {
                return nil
            }
            return .messageStart(message: response)

        case "content_block_start":
            guard let index = obj["index"] as? Int,
                  let block = obj["content_block"] as? [String: Any],
                  let raw = try? JSONSerialization.data(withJSONObject: block),
                  let cb = try? decoder.decode(ContentBlock.self, from: raw) else {
                return nil
            }
            return .contentBlockStart(index: index, block: cb)

        case "content_block_delta":
            guard let index = obj["index"] as? Int,
                  let delta = obj["delta"] as? [String: Any],
                  let dtype = delta["type"] as? String else {
                return nil
            }
            switch dtype {
            case "text_delta":
                let s = (delta["text"] as? String) ?? ""
                return .contentBlockDelta(index: index, delta: .text(s))
            case "thinking_delta":
                let s = (delta["thinking"] as? String) ?? ""
                return .contentBlockDelta(index: index, delta: .thinking(s))
            case "signature_delta":
                let s = (delta["signature"] as? String) ?? ""
                return .contentBlockDelta(index: index, delta: .signature(s))
            case "input_json_delta":
                let s = (delta["partial_json"] as? String) ?? ""
                return .contentBlockDelta(index: index, delta: .partialJSON(s))
            default:
                return nil
            }

        case "content_block_stop":
            guard let index = obj["index"] as? Int else { return nil }
            return .contentBlockStop(index: index)

        case "message_delta":
            let delta = obj["delta"] as? [String: Any]
            let stopReason = delta?["stop_reason"] as? String
            let stopSequence = delta?["stop_sequence"] as? String
            let usage = obj["usage"] as? [String: Any]
            let outTokens = usage?["output_tokens"] as? Int
            return .messageDelta(stopReason: stopReason, stopSequence: stopSequence, outputTokens: outTokens)

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            let err = obj["error"] as? [String: Any]
            let etype = (err?["type"] as? String) ?? "unknown"
            let emsg  = (err?["message"] as? String) ?? ""
            return .streamError(type: etype, message: emsg)

        default:
            return nil
        }
    }
}
