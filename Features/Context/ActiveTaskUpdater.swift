import Foundation
import AppKit

/// Periodic Mercury synthesis maintaining the rolling `active_task`. Runs every ~90s
/// while the user is active, or on demand from Selector (Phase 4) when the task is stale.
///
/// Trigger conditions (any of):
///   - ≥90 s since last update AND at least one substantive event (not just dwell)
///   - App switch where the new bundle_id isn't in current `active_task.resources`
///   - Synchronous refresh request from Selector with stale_since > 30 s (uses
///     a 2 s hard deadline; falls back to stale task on timeout)
public final class ActiveTaskUpdater {

    public static let shared = ActiveTaskUpdater()

    private var timer: Timer?
    private var lastUpdateAt: Date = .distantPast
    private var lastEventSeqAtUpdate: Int = 0
    private let queue = DispatchQueue(label: "AgentNotch.ActiveTaskUpdater.queue")

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        stop()
        // Fire every 30s for the trigger-condition check; the actual Mercury call
        // happens only when triggers fire.
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
        // Subscribe to app-switch notifications for the second trigger.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppSwitch(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleAppSwitch(_ notification: Notification) {
        Task { await self.tick() }
    }

    // MARK: - Trigger evaluation + Mercury call

    /// Periodic / event-driven update tick. Returns the new active_task (or nil if no
    /// update fired). Idempotent — runs only when triggers say so.
    @discardableResult
    public func tick() async -> CActiveTask? {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdateAt)
        let latestSeq = EventLog.shared.snapshot().last?.seq ?? 0
        let newEvents = latestSeq > lastEventSeqAtUpdate
        guard elapsed >= 90.0 && newEvents else { return nil }
        return await refresh(timeout: 8.0)
    }

    /// On-demand refresh used by Selector (Phase 4) with a tight deadline.
    /// Returns the latest `CActiveTask` on success, or nil if Mercury fails / times out.
    @discardableResult
    public func refresh(timeout: TimeInterval) async -> CActiveTask? {
        let current = L5Store.shared.loadActiveTask()
        let events = EventLog.shared.tail(20)
        let resources = ResourceIndex.shared.recent(limit: 10)

        let prompt = Self.buildPrompt(current: current, events: events, resources: resources)
        do {
            let raw = try await MercuryClient.shared.complete(
                messages: [
                    MercuryClient.Message(role: "system", content: Self.systemPrompt),
                    MercuryClient.Message(role: "user", content: prompt)
                ],
                responseFormat: .jsonObject,
                maxTokens: 8000,
                timeout: timeout
            )
            guard let result = Self.parseResponse(raw, fallback: current) else {
                if var stale = current {
                    stale.staleSince = stale.staleSince ?? Date()
                    try? L5Store.shared.saveActiveTask(stale)
                    return stale
                }
                return nil
            }

            // Apply
            switch result {
            case .update(let updated):
                try? L5Store.shared.saveActiveTask(updated)
                lastUpdateAt = Date()
                lastEventSeqAtUpdate = events.last?.seq ?? lastEventSeqAtUpdate
                return updated
            case .archiveAndStartNew(let ended, let newTask):
                try? L5Store.shared.archive(ended)
                try? L5Store.shared.saveActiveTask(newTask)
                lastUpdateAt = Date()
                lastEventSeqAtUpdate = events.last?.seq ?? lastEventSeqAtUpdate
                return newTask
            }
        } catch {
            // Mark stale; return whatever we have.
            if var stale = current {
                stale.staleSince = stale.staleSince ?? Date()
                try? L5Store.shared.saveActiveTask(stale)
                return stale
            }
            return nil
        }
    }

    // MARK: - System prompt (will move to EvalHarness-style baseline in Phase 4 cleanup)

    static let systemPrompt: String = """
    You maintain a structured Active Task object representing what the user is working on.

    You will receive:
      - CURRENT active_task: the current task object, or null if none exists
      - NEW events: a list of recent CEvent objects since the last update
      - RECENT resources: URIs the user has touched recently

    Return strictly one of these JSON shapes:

      { "update": { ...updated active_task fields... } }

      - OR -

      { "archive_and_start_new": {
          "ended_task": { ...the previous task with an "outcome" string added... },
          "new_task":   { ...complete new active_task object... }
        }
      }

    CRITICAL RULES:

    1. **When CURRENT is null** (cold start), you MUST synthesize a brand-new active_task
       from the NEW events AND the RECENT resources input. Set:
         - id: any unique string (use the timestamp of the first event, like "t_2026-05-17T10:00")
         - started_at: timestamp of the first event in NEW events
         - label: a concrete phrase derived from the actual app + surface in the events
                  (NOT empty, NOT a generic placeholder)
         - kind: one of "design_iteration", "coding", "research", "comms", "admin", or
                 a similarly specific kind — never empty
         - narrative: a 1-3 sentence description GROUNDED in the actual events
                      (e.g., name the app, the surface, what the user typed/clicked)
         - resources: an array of URI strings. You MUST copy every `uri` field from the
                      RECENT resources input into this array (verbatim, including
                      `figma://`, `file://`, `https://` schemes). Do NOT leave this
                      array empty when the input contained resources. Also add any
                      URIs implied by the events themselves.
         - actions_taken, entities, likely_next_steps: populate from the events
         - blocked_on: usually null
         - stale_since: null

    2. **When choosing archive_and_start_new**, the new_task fields MUST be grounded in
       the NEW events you were just shown — DO NOT invent app names, file names, task
       titles, or actions that are not present in the input. If the events show
       "iTerm git status" and "switch to VSCode", a valid new_task.label is
       "explore git state in <repo from events>" or "context switch to VSCode" —
       NOT "update SomeRandomFile.swift" or any concept not in the events.

    3. **Use archive_and_start_new ONLY when** the user has clearly switched domains
       (different apps, different resources, different topic). When in doubt, prefer
       update — adding context to an existing task is almost always right.

    4. **Be specific in the narrative.** The narrative MUST literally name (verbatim)
       every concrete entity present in the events: app names, window titles, file
       names, repo/folder names, channel names, people. Avoid generic phrases like
       "coding tasks", "user is working", "the editor", "completing tasks" — they
       signal you're not reading the events.

       APP-NAME NORMALIZATION (mandatory — apply this when writing the narrative):
         - app: "Visual Studio Code"  →  write the literal substring "VSCode"
                                         somewhere in the narrative (you may also
                                         write "Visual Studio Code", but "VSCode"
                                         MUST appear at least once).
         - app: "Figma"               →  write the literal substring "Figma".
         - app: "iTerm2"              →  write the literal substring "iTerm2".
         - app: "Slack"               →  write the literal substring "Slack".
         - app: "Google Chrome"       →  write the literal substring "Chrome".
         - app: "Arc"                 →  write the literal substring "Arc".

       File and repo names MUST also appear verbatim in the narrative when they are
       present in the events (e.g., "ActiveTaskUpdater.swift", "agent-notch").

    5. **For archive_and_start_new specifically:**
       - The ended_task.outcome MUST name the app/domain being left behind verbatim
         (e.g., "Paused Figma onboarding iteration to switch to coding in agent-notch").
       - The new_task.label MUST include the concrete subject of the new work —
         typically the repo/folder name from the events (e.g., "agent-notch") and
         the kind of work (e.g., "edit ActiveTaskUpdater.swift in agent-notch repo").
    """

    // MARK: - Prompt builder

    static func buildPrompt(current: CActiveTask?, events: [CEvent], resources: [CResourceRef]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let currentJSON: String = {
            if let current, let data = try? encoder.encode(current) {
                return String(data: data, encoding: .utf8) ?? "null"
            }
            return "null"
        }()

        let eventsJSON: String = {
            if let data = try? encoder.encode(events) {
                return String(data: data, encoding: .utf8) ?? "[]"
            }
            return "[]"
        }()

        let resourcesJSON: String = {
            if let data = try? encoder.encode(resources) {
                return String(data: data, encoding: .utf8) ?? "[]"
            }
            return "[]"
        }()

        return """
        CURRENT active_task:
        \(currentJSON)

        NEW events since last update:
        \(eventsJSON)

        RECENT resources index:
        \(resourcesJSON)

        Return strictly one JSON object: {update: ...} OR {archive_and_start_new: {ended_task, new_task}}.
        """
    }

    // MARK: - Response parser

    enum Result {
        case update(CActiveTask)
        case archiveAndStartNew(ended: CArchivedTask, new: CActiveTask)
    }

    static func parseResponse(_ raw: String, fallback: CActiveTask?) -> Result? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let updateAny = obj["update"], let updateData = try? JSONSerialization.data(withJSONObject: updateAny) {
            if let updated = try? decoder.decode(CActiveTask.self, from: updateData) {
                return .update(updated)
            }
        }
        if let pairAny = obj["archive_and_start_new"] as? [String: Any] {
            if let endedAny = pairAny["ended_task"], let newAny = pairAny["new_task"],
               let endedData = try? JSONSerialization.data(withJSONObject: endedAny),
               let newData = try? JSONSerialization.data(withJSONObject: newAny),
               let ended = try? decoder.decode(CArchivedTask.self, from: endedData),
               let newTask = try? decoder.decode(CActiveTask.self, from: newData) {
                return .archiveAndStartNew(ended: ended, new: newTask)
            }
        }
        return nil
    }
}
