//
//  AgentState.swift
//  Agent in the Notch
//
//  Observable state for what the agent is doing right now. The Haiku wiring
//  (Ashan) writes into this; the Notch UI (Wyatt) reads it for the live state
//  view.
//

import Foundation
import Combine

public struct AgentLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let activity: AgentActivity
    public let detail: String
}

public enum AgentActivity: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case toolCall(name: String)
    case error(message: String)

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .toolCall(let name): return "Running \(name)"
        case .error(let message): return "Error: \(message)"
        }
    }

    public var symbol: String {
        switch self {
        case .idle: return "moon.zzz.fill"
        case .listening: return "waveform"
        case .thinking: return "brain"
        case .toolCall: return "wrench.and.screwdriver.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
public final class AgentState: ObservableObject {
    public static let shared = AgentState()

    @Published public var activity: AgentActivity = .idle
    @Published public var detail: String = ""
    @Published public var lastTranscript: String = ""
    @Published public var activityLog: [AgentLogEntry] = []

    private init() {}

    public func set(_ activity: AgentActivity, detail: String = "") {
        let shouldLog: Bool
        let logDetail: String
        switch activity {
        case .idle:
            switch self.activity {
            case .thinking, .toolCall:
                shouldLog = true
                logDetail = detail.isEmpty ? "Done" : detail
            default:
                shouldLog = false
                logDetail = detail
            }
        default:
            shouldLog = true
            logDetail = detail
        }

        if shouldLog {
            activityLog.insert(AgentLogEntry(timestamp: Date(), activity: activity, detail: logDetail), at: 0)
            if activityLog.count > 30 { activityLog.removeLast() }
        }
        self.activity = activity
        self.detail = detail
    }
}
