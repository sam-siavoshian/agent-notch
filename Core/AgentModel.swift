//
//  AgentModel.swift
//  Agent in the Notch
//
//  User-selectable computer-use model. Maps display name → Anthropic model ID.
//

import Foundation

public enum AgentModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case haiku
    case sonnet
    case opus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .haiku:  return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus:   return "Opus"
        }
    }

    /// Concrete Anthropic model ID handed to the Messages API.
    public var modelID: String {
        switch self {
        case .haiku:  return AnthropicModel.haiku45
        case .sonnet: return AnthropicModel.sonnet46
        case .opus:   return AnthropicModel.opus47
        }
    }

    public var iconName: String {
        switch self {
        case .haiku:  return "hare.fill"
        case .sonnet: return "leaf.fill"
        case .opus:   return "crown.fill"
        }
    }
}
