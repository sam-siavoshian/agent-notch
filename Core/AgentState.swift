//
//  AgentState.swift
//  Agent in the Notch
//
//  Observable state for what the agent is doing right now. Writes from the
//  agent wiring, reads from the Notch UI. Uses `@Observable` so views that
//  only read a slice (e.g. `state.activity`) skip the re-eval when an
//  unrelated field (`activityLog`) appends.
//

import Foundation
import Observation

public struct AgentLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let activity: AgentActivity
    public let detail: String
    /// Pre-formatted "2m ago" string, set at insertion. Avoids per-row
    /// `Text(_, style: .relative)` recomputation in the activity feed.
    public let formattedTimestamp: String
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
@Observable
public final class AgentState {
    public static let shared = AgentState()

    public var activity: AgentActivity = .idle
    public var detail: String = ""
    public var lastTranscript: String = ""
    public var activityLog: [AgentLogEntry] = []

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private init() {
        activityLog.reserveCapacity(31)
    }

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
            let now = Date()
            let entry = AgentLogEntry(
                timestamp: now,
                activity: activity,
                detail: logDetail,
                formattedTimestamp: Self.relativeFormatter.localizedString(for: now, relativeTo: now)
            )
            activityLog.insert(entry, at: 0)
            if activityLog.count > 30 { activityLog.removeLast() }
        }
        self.activity = activity
        self.detail = detail
    }
}
