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

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .haiku:  return "Haiku"
        case .sonnet: return "Sonnet"
        }
    }

    /// Concrete Anthropic model ID handed to the Messages API.
    public var modelID: String {
        switch self {
        case .haiku:  return AnthropicModel.haiku45
        case .sonnet: return AnthropicModel.sonnet46
        }
    }

    public var iconName: String {
        switch self {
        case .haiku:  return "hare.fill"
        case .sonnet: return "leaf.fill"
        }
    }

    // MARK: - Computer-use tool versions
    //
    // Anthropic ships TWO parallel computer-use tool versions, and each model
    // family supports exactly one of them. Mismatching the model and the tool
    // type produces HTTP 400 "does not support tool types: ..." with no
    // graceful API-level fallback, so we have to pair them correctly at
    // request time. Per docs:
    //   computer-use-2025-11-24 → Opus 4.7 / 4.6 / 4.5, Sonnet 4.6
    //   computer-use-2025-01-24 → Haiku 4.5, Sonnet 4.5, Opus 4.1, Sonnet 4, Opus 4
    // The tool TYPE in the request's tools array must match the BETA header.

    /// The `tools[*].type` string for the `computer` tool when this model is
    /// current. Paired with `computerUseBetaHeader`.
    public var computerUseToolType: String {
        switch self {
        case .haiku:  return "computer_20250124"
        case .sonnet: return "computer_20251124"
        }
    }

    /// The `anthropic-beta` header value for computer-use when this model is
    /// current. Paired with `computerUseToolType`.
    public var computerUseBetaHeader: String {
        switch self {
        case .haiku:  return "computer-use-2025-01-24"
        case .sonnet: return "computer-use-2025-11-24"
        }
    }
}
