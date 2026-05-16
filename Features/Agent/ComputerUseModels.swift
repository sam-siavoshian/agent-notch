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
}

public struct AnthropicMessageRequest: Codable, Sendable {
    public var model: String
    public var maxTokens: Int
    public var system: String?
    public var messages: [Message]
    public var tools: [Tool]
    public var toolChoice: ToolChoice?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case tools
        case toolChoice = "tool_choice"
    }

    public struct ToolChoice: Codable, Sendable {
        public var type: String // "auto" | "any" | "tool" | "none"
        public init(type: String) { self.type = type }
    }
}

public enum Tool: Codable, Sendable {
    case computer(displayWidth: Int, displayHeight: Int, displayNumber: Int?)

    private enum Keys: String, CodingKey {
        case type, name
        case displayWidth = "display_width_px"
        case displayHeight = "display_height_px"
        case displayNumber = "display_number"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .computer(let w, let h, let n):
            try c.encode("computer_20251124", forKey: .type)
            try c.encode("computer", forKey: .name)
            try c.encode(w, forKey: .displayWidth)
            try c.encode(h, forKey: .displayHeight)
            if let n { try c.encode(n, forKey: .displayNumber) }
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
            self = .computer(displayWidth: w, displayHeight: h, displayNumber: n)
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
    case image(mediaType: String, base64: String)
    case toolUse(id: String, name: String, input: JSON)
    case toolResult(toolUseId: String, content: [ContentBlock], isError: Bool)

    private enum Keys: String, CodingKey {
        case type, text
        case source
        case id, name, input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
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
        case .image(let media, let b64):
            try c.encode("image", forKey: .type)
            var sc = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try sc.encode("base64", forKey: .type)
            try sc.encode(media, forKey: .mediaType)
            try sc.encode(b64, forKey: .data)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let tid, let content, let isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(tid, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .isError) }
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
            self = .image(mediaType: media, base64: data)
        case "tool_use":
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let input = try c.decode(JSON.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let tid = try c.decode(String.self, forKey: .toolUseId)
            let content = (try? c.decode([ContentBlock].self, forKey: .content)) ?? []
            let isError = (try? c.decode(Bool.self, forKey: .isError)) ?? false
            self = .toolResult(toolUseId: tid, content: content, isError: isError)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown content block type \(type)"
            )
        }
    }
}

public struct AnthropicMessageResponse: Codable, Sendable {
    public var id: String
    public var model: String
    public var role: String
    public var content: [ContentBlock]
    public var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case id, model, role, content
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
    public var arrayValue: [JSON]? {
        if case .array(let v) = self { return v } else { return nil }
    }
    public var objectValue: [String: JSON]? {
        if case .object(let v) = self { return v } else { return nil }
    }
}
