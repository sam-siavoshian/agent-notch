//
//  ClaudeCodeSession.swift
//  Agent in the Notch
//
//  Tracks the user's current Claude Code conversation state across long-press
//  turns. CC is spawned fresh every turn (`-p` is one-shot per process), but
//  `--resume <session-id>` carries history forward. We rotate to a fresh
//  session once the running token estimate crosses `resetThreshold` so CC
//  never lands inside its own auto-compact territory.
//
//  Token estimates come from CC's stream-json `message_delta.usage` events
//  (input + output tokens per turn). Cache reads are not counted toward the
//  estimate — they don't pressure the context window the same way fresh input
//  does, but cheap to include and the threshold is conservative anyway.
//

import Foundation

public actor ClaudeCodeSession {
    public static let shared = ClaudeCodeSession()

    /// 75% of CC's 200k context window. Cuts a clean session boundary well
    /// before CC's own auto-compact would kick in.
    public static let resetThreshold = 150_000

    private var currentId: String?
    private var tokenEstimate: Int = 0
    private var lastUsedAt: Date?

    public init() {}

    /// nil = caller should spawn a fresh `claude -p` (no `--resume` flag).
    public func shouldResume() -> String? {
        guard let id = currentId else { return nil }
        if tokenEstimate >= Self.resetThreshold { return nil }
        return id
    }

    /// Stash the session id observed in the first stream-json event of a run.
    public func setSessionId(_ id: String) {
        // CC sometimes rotates the session id even mid-resume (e.g. if it
        // forks an internal subagent). Track whatever the latest one is.
        currentId = id
        lastUsedAt = Date()
    }

    public func addUsage(input: Int, output: Int) {
        let delta = max(0, input) + max(0, output)
        tokenEstimate += delta
        if tokenEstimate >= Self.resetThreshold {
            // Don't clear `currentId` here — caller checks `shouldResume()`
            // BEFORE the next spawn. Clearing eagerly would race against
            // an in-flight turn still appending usage.
        }
    }

    /// Snapshot for diagnostics / dev tools.
    public func snapshot() -> (sessionID: String?, tokenEstimate: Int, lastUsedAt: Date?) {
        (currentId, tokenEstimate, lastUsedAt)
    }

    public func reset() {
        currentId = nil
        tokenEstimate = 0
        lastUsedAt = nil
    }
}
