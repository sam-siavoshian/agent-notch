import Foundation
import AppKit

/// The long-press entry point. Assembles the selector input from L2 + L3 + L4 + L5
/// and calls Mercury 2 via OpenRouter for `{intent, brief}`. Falls back to
/// `LocalBriefRenderer` when Mercury times out or returns malformed JSON.
public final class ContextSelector {

    public static let shared = ContextSelector()

    /// Result returned to `AgentSession`: the resolved intent + the markdown brief
    /// emitted to the harness as a system block, plus diagnostics for Dev Tools.
    public struct Result {
        public let intent: CIntent
        public let brief: String
        public let l2: CL2Snapshot
        /// JPEG bytes captured at long-press time (same frame OCR ran on).
        /// Forwarded to the harness as the first user-message image so Claude
        /// sees the screen without taking a `computer.screenshot` tool call.
        /// Nil if capture failed or timed out.
        public let initiationScreenshot: Data?
        public let degraded: Bool        // true if we fell back to LocalBriefRenderer
        public let latencyS: Double
        public let modelUsed: String?    // nil when degraded
    }

    /// Snapshot of the last selector run — surfaced in Dev Tools.
    public private(set) var lastRun: Result?

    /// In-memory ring of the most recent selector runs (oldest → newest).
    /// Bounded to `maxRecentRuns`. Powers the Dev Tools Intent history view.
    /// Note: `recentRuns.last == lastRun` by construction — that duplication
    /// is intentional for caller ergonomics.
    public private(set) var recentRuns: [Result] = []
    private let maxRecentRuns = 20

    private init() {}

    private func recordRun(_ result: Result) {
        lastRun = result
        recentRuns.append(result)
        if recentRuns.count > maxRecentRuns {
            recentRuns.removeFirst(recentRuns.count - maxRecentRuns)
        }
    }

    /// Run the selector for a long-press transcript. Total budget ~3.5s worst case.
    public func select(transcript: String) async -> Result {
        let started = Date()
        let snap = await L2Snapshotter.snapshot(overallDeadline: 0.4)
        let l2 = snap.l2
        let initiationScreenshot = snap.screenshotJPEG

        // Ensure active_task isn't more than 30 s stale before bundling it.
        let staleThreshold: TimeInterval = 30.0
        let currentTask = L5Store.shared.loadActiveTask()
        let needsRefresh = currentTask.flatMap { $0.staleSince.map { Date().timeIntervalSince($0) > staleThreshold } } ?? false
        let activeTask: CActiveTask?
        if needsRefresh {
            activeTask = (await ActiveTaskUpdater.shared.refresh(timeout: 2.0)) ?? currentTask
        } else {
            activeTask = currentTask
        }

        let events = EventLog.shared.tail(10)
        let resources = ResourceIndex.shared.recent(limit: 20)
        let recipes = AnchorRecorder.shared.recipes(for: l2.bundleID).recipes

        // Read user-tunable settings on the main actor.
        let mercuryEnabled = await MainActor.run { AgentSettingsStore.shared.mercuryEnabled }
        let userPrefs = await MainActor.run { AgentSettingsStore.shared.preferences }

        // Try Mercury first (when enabled + key available)
        if mercuryEnabled {
            do {
                let raw = try await callMercury(
                    transcript: transcript,
                    l2: l2,
                    activeTask: activeTask,
                    recipes: recipes,
                    resources: resources,
                    events: events,
                    userPrefs: userPrefs,
                    timeout: 2.5
                )
                if let parsed = Self.parseResponse(raw) {
                    let result = Result(
                        intent: parsed.intent,
                        brief: parsed.brief,
                        l2: l2,
                        initiationScreenshot: initiationScreenshot,
                        degraded: false,
                        latencyS: Date().timeIntervalSince(started),
                        modelUsed: MercuryClient.defaultModel
                    )
                    recordRun(result)
                    return result
                }
                // Parse failed — fall through to local renderer.
            } catch {
                // Timeout, no key, malformed — fall through.
            }
        }

        // Local fallback
        let (intent, brief) = LocalBriefRenderer.render(
            transcript: transcript,
            l2: l2,
            activeTask: activeTask,
            recipesForActiveApp: recipes,
            recentResources: resources
        )
        let result = Result(
            intent: intent,
            brief: brief,
            l2: l2,
            initiationScreenshot: initiationScreenshot,
            degraded: true,
            latencyS: Date().timeIntervalSince(started),
            modelUsed: nil
        )
        recordRun(result)
        return result
    }

    // MARK: - Mercury call

    private func callMercury(
        transcript: String,
        l2: CL2Snapshot,
        activeTask: CActiveTask?,
        recipes: [CRecipe],
        resources: [CResourceRef],
        events: [CEvent],
        userPrefs: String,
        timeout: TimeInterval
    ) async throws -> String {
        let prompt = try Self.buildSelectorPrompt(
            transcript: transcript,
            l2: l2,
            activeTask: activeTask,
            recipes: recipes,
            resources: resources,
            events: events,
            userPrefs: userPrefs
        )
        return try await MercuryClient.shared.complete(
            messages: [
                MercuryClient.Message(role: "system", content: Self.systemPrompt),
                MercuryClient.Message(role: "user", content: prompt)
            ],
            responseFormat: .jsonObject,
            maxTokens: 1200,
            timeout: timeout
        )
    }

    // MARK: - System prompt (kept here; Phase 5 cleanup can move to a shared constant)

    static let systemPrompt: String = """
    You are the context selector for an on-screen macOS computer-use agent.

    You receive a single JSON payload with: a voice transcript, the current screen
    snapshot (AX elements, OCR, selection, clipboard, app-specific data), the user's
    preferences, the user's active task and recent activity, and per-app operational
    recipes the agent can use.

    You may receive `learned_surfaces`: accumulated per-surface UI knowledge
    built up over many prior passive observations of this app. Each entry has
    {app, surface, controls[], observation_count, last_seen}. Treat this as the
    canonical map of "how this app's surfaces actually work" — when the current
    screen matches a learned surface, prefer its controls/locations over your own
    inferences. Use it to write more confident, more specific steps in the brief
    (e.g., "Send button bottom-right of composer — seen 47 times"). Don't dump
    raw learned_surfaces into the brief; distill them into actionable guidance.

    You may receive `recent_story`: a chronological strip of what the user has
    been doing across the last few minutes, built from per-capture vision
    observations. Each entry has {t, app, surface, narrative,
    current_goal_guess, content_type, artifact}. Use this to:
    - Resolve deictic references ("the letter", "her message", "that doc")
      against the artifacts the user has actually been touching.
    - Write briefs with real continuity ("you've been drafting a letter to
      Marcus for the last 5 minutes" beats "you appear to be in TextEdit").
    - Decide whether the user's current voice request is a CONTINUATION of
      recent activity (most common) or a NEW task (less common).
    Never reproduce raw artifact bodies into the brief verbatim — they may
    be sensitive. Summarize them.

    Your job is two things in one call:

    (1) RESOLVE INTENT. Output {verb, target, resolved_target?, entities, confidence}.
        Use active_task, recent_events, recent_resources, and clipboard to resolve
        deictic references — "the draft", "her", "that PR", "this". Be specific. If
        you cannot resolve a reference with high confidence, leave resolved_target
        null and set confidence accordingly. **Indirect-object recipients (a person
        a thing is being sent to) belong in `entities`, not `target` — `target` is
        the thing being acted on.**

    (2) WRITE THE BRIEF. A markdown briefing for the computer-use agent, ≤600 tokens,
        structured per the template below. The agent has these tools, in preference
        order: open_url > applescript > run_shortcut > ax_query+ax_press >
        menu_shortcut > computer (vision+click). ALWAYS lead with anchors above
        "computer". Never include pixel coordinates — they are not reliable across
        turns.

    Brief template (omit any section with nothing concrete to say):

    ## What the user wants
    <one sentence with resolved references>

    ## You are here
    - App, window, focused element (AX path)
    - Useful AX paths on this screen (≤5, role+label+ax_path)
    - Active selection or recent clipboard if relevant

    ## How to do it on <app>
    <ordered steps, leading with the fastest tool — shortcut, url, menu, applescript>

    ## What "<deictic>" means
    <one entry per pronoun/reference that resolved to a specific resource>

    ## Watch out for
    <only if there's a real, evidenced gotcha>

    Rules:
    - Coordinate-free. Anchors only.
    - Never invent recipes, AX paths, or resources. If you don't have it, say
      "you'll need to look" and let the agent screenshot.
    - Stay under 600 tokens. Density over completeness.

    Return strictly one JSON object: { "intent": {...}, "brief": "..." }.
    """

    // MARK: - Prompt builder

    static func buildSelectorPrompt(
        transcript: String,
        l2: CL2Snapshot,
        activeTask: CActiveTask?,
        recipes: [CRecipe],
        resources: [CResourceRef],
        events: [CEvent],
        userPrefs: String
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        /// Compact per-entry projection of `SurfaceObservation` for the
        /// Mercury payload. We drop fields Mercury doesn't need (controls,
        /// correlations, latency, allVisibleApps) to keep prompt size bounded;
        /// what's left is the user-centric story: when, where, doing what,
        /// with what content.
        struct StoryEntry: Encodable {
            let t: Date
            let app: String?
            let surface: String?
            let narrative: String?
            let current_goal_guess: String?
            let content_type: String?
            let artifact: [String: AnyCodable]?
        }

        struct Payload: Encodable {
            let transcript: String
            let current_screen: CL2Snapshot
            let user_prefs: String
            let active_task: CActiveTask?
            let recent_events: [CEvent]
            let recent_resources: [CResourceRef]
            let recipes_for_active_app: [CRecipe]
            /// Accumulated per-(app, surface) UI knowledge built up by
            /// `GeminiObserver` over many observations. Mercury should treat
            /// this as the canonical "how this app's surfaces actually work"
            /// reference and lean on it when AX/OCR are sparse.
            let learned_surfaces: [SurfaceMemoryStore.SurfaceMemory]
            /// Recent chronological story of what the user has been doing, built
            /// up by GeminiObserver per capture and persisted to CaptureStoryLog.
            /// Mercury uses this to write briefs with real continuity rather than
            /// guessing from sparse events. Last ~20 entries OR last 5 minutes,
            /// whichever is shorter.
            let recent_story: [StoryEntry]
        }

        // Cap the per-surface control list to keep prompt size bounded; sort
        // by frequency so the most-seen surfaces/controls surface first.
        let learned: [SurfaceMemoryStore.SurfaceMemory] = Array(
            SurfaceMemoryStore.shared
                .memories(for: l2.app)
                .sorted { $0.observationCount > $1.observationCount }
                .prefix(6)
                .map { mem -> SurfaceMemoryStore.SurfaceMemory in
                    var trimmed = mem
                    trimmed.controls = Array(
                        mem.controls.sorted { $0.seenCount > $1.seenCount }.prefix(12)
                    )
                    return trimmed
                }
        )

        // Pull the last 20 story entries, then keep only those within the last
        // 5 minutes. If fewer fit the window, that's fine — emit what's there.
        let storyWindowSeconds: TimeInterval = 300
        let now = Date()
        let recentStory: [StoryEntry] = CaptureStoryLog.shared.tail(20)
            .compactMap { obs in
                guard now.timeIntervalSince(obs.t) <= storyWindowSeconds else { return nil }
                return StoryEntry(
                    t: obs.t,
                    app: obs.frontmostApp,
                    surface: obs.currentSurface,
                    narrative: obs.narrative,
                    current_goal_guess: obs.currentGoalGuess,
                    content_type: obs.contentType,
                    artifact: obs.artifact
                )
            }

        let payload = Payload(
            transcript: transcript,
            current_screen: l2,
            user_prefs: userPrefs,
            active_task: activeTask,
            recent_events: events,
            recent_resources: Array(resources.prefix(20)),
            recipes_for_active_app: Array(recipes.sorted { $0.seenCount > $1.seenCount }.prefix(8)),
            learned_surfaces: learned,
            recent_story: recentStory
        )
        let data = try encoder.encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Response parser

    /// Robust parse: extract `brief` via JSONSerialization first (so it survives even when
    /// Mercury's intent shape doesn't decode), then attempt typed intent decode.
    static func parseResponse(_ raw: String) -> (intent: CIntent, brief: String)? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let brief = obj["brief"] as? String, !brief.isEmpty else { return nil }
        var intent: CIntent
        if let intentAny = obj["intent"],
           let intentData = try? JSONSerialization.data(withJSONObject: intentAny),
           let parsed = try? JSONDecoder().decode(CIntent.self, from: intentData) {
            intent = parsed
        } else {
            // Brief is valid but intent malformed — return a low-confidence default.
            intent = CIntent(verb: "do", target: nil, resolvedTarget: nil, entities: [], confidence: 0.2)
        }
        return (intent, brief)
    }
}
