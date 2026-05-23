//
//  AgentProvider.swift
//  Agent in the Notch
//
//  Selects which backend drives the computer-use loop:
//    - .anthropicAPI    → AnthropicClient → claude-haiku-4-5 over HTTPS.
//    - .claudeCodeCLI   → spawn local `claude -p` subprocess. Tools surface
//                         via the AgentNotch MCP bridge (Unix domain socket)
//                         which routes back into the same ToolDispatcher.
//
//  CC mode uses the user's own CC auth (subscription or `claude login`), so
//  AgentNotch's ANTHROPIC_API_KEY is irrelevant when this is .claudeCodeCLI.
//

import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropicAPI
    case claudeCodeCLI

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anthropicAPI:  return "Anthropic API"
        case .claudeCodeCLI: return "Claude Code"
        }
    }

    /// SF Symbol used for the settings row icons. `cloud` for the hosted API,
    /// `terminal` for the local CLI.
    public var symbolName: String {
        switch self {
        case .anthropicAPI:  return "cloud"
        case .claudeCodeCLI: return "terminal"
        }
    }
}
