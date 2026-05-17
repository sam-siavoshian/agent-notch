//
//  AgentReasoningEffort.swift
//  Agent in the Notch
//

import Foundation

public enum AgentReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Extended-thinking budget for Anthropic Messages API. `nil` disables
    /// thinking entirely (low = fastest, no reasoning tokens). Medium/high
    /// trade output latency + token cost for deeper deliberation before each
    /// tool call. Must be < the request's `max_tokens`.
    public var thinkingBudgetTokens: Int? {
        switch self {
        case .low:    return nil
        case .medium: return 2048
        case .high:   return 8192
        }
    }

    public var iconName: String {
        switch self {
        case .low:    return "bolt.fill"
        case .medium: return "brain"
        case .high:   return "brain.head.profile"
        }
    }
}
