import Foundation

public struct ChatCompletionRequest: Encodable {
    public let model: String
    public let messages: [Message]
    public let responseFormat: ResponseFormat?
    public let temperature: Double?
    public let maxTokens: Int?

    public init(
        model: String,
        messages: [Message],
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.messages = messages
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
    }
}

public struct Message: Codable {
    public let role: String  // "system" | "user" | "assistant"
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum ResponseFormat: Encodable {
    case jsonObject

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .jsonObject:
            try container.encode("json_object", forKey: .type)
        }
    }
    private enum CodingKeys: String, CodingKey { case type }
}

public struct ChatCompletion: Decodable {
    public let id: String
    public let model: String
    public let choices: [Choice]
    public let usage: Usage?

    public struct Choice: Decodable {
        public let index: Int
        public let message: Message
        public let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Decodable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}
