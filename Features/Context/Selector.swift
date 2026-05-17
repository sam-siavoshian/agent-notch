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
        /// Markdown rendering of the brief handed to the computer-use harness.
        /// Rendered from `structuredBrief` on the Mercury path; comes directly
        /// from `LocalBriefRenderer` on the fallback path.
        public let brief: String
        /// Typed brief as returned by Mercury. Nil on the LocalBriefRenderer path.
        public let structuredBrief: StructuredBrief?
        public let l2: CL2Snapshot
        /// JPEG bytes captured at long-press time. Forwarded to the harness as
        /// the first user-message image so Claude sees the screen without taking
        /// a `computer.screenshot` tool call. Nil if capture failed or timed out.
        public let initiationScreenshot: Data?
        public let degraded: Bool        // true if we fell back to LocalBriefRenderer
        public let latencyS: Double
        public let modelUsed: String?    // nil when degraded
    }

    /// In-memory ring of the most recent selector runs (oldest → newest).
    /// Powers the Intent Dev Tools tab.
    public private(set) var recentRuns: [Result] = []
    private let maxRecentRuns = 20

    /// Snapshot of the last selector run — surfaced in Dev Tools.
    public var lastRun: Result? { recentRuns.last }

    private init() {}

    private func recordRun(_ result: Result) {
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

        // Refresh active_task when it's time-stale OR doesn't cover the current
        // app. The second trigger matters when ActiveTaskUpdater's 30s/90s gates
        // have blocked a recent app-switch tick.
        let staleThreshold: TimeInterval = 30.0
        let currentTask = L5Store.shared.loadActiveTask()
        let staleByTime = currentTask.flatMap { $0.staleSince.map { Date().timeIntervalSince($0) > staleThreshold } } ?? false
        let staleByContext = !Self.currentTaskCoversBundle(currentTask, l2: l2)
        let activeTask: CActiveTask?
        if staleByTime || staleByContext {
            activeTask = (await ActiveTaskUpdater.shared.refresh(timeout: 2.0)) ?? currentTask
        } else {
            activeTask = currentTask
        }

        let events = EventLog.shared.tail(10)
        let resources = ResourceIndex.shared.recent(limit: 20)
        let recipes = AnchorRecorder.shared.recipes(for: l2.bundleID).recipes

        let mercuryEnabled = await MainActor.run { AgentSettingsStore.shared.mercuryEnabled }
        let userPrefs = await MainActor.run { AgentSettingsStore.shared.preferences }

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
                    // Validation: when ground-truth learned controls exist,
                    // Mercury must cite them. Empty anchors = silent drop.
                    if Self.hadMatchingLearnedSurface(l2: l2) && parsed.brief.navigationAnchors.isEmpty {
                        NSLog("[Selector] WARN: Mercury returned empty navigation_anchors despite matching learned surface for \(l2.bundleID) / \(l2.windowTitle ?? "?")")
                    }
                    let result = Result(
                        intent: parsed.intent,
                        brief: Self.renderMarkdown(parsed.brief),
                        structuredBrief: parsed.brief,
                        l2: l2,
                        initiationScreenshot: initiationScreenshot,
                        degraded: false,
                        latencyS: Date().timeIntervalSince(started),
                        modelUsed: MercuryClient.defaultModel
                    )
                    recordRun(result)
                    return result
                }
            } catch {
                // Timeout, no key, malformed — fall through to local renderer.
            }
        }

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
            structuredBrief: nil,
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

    // MARK: - System prompt

    private static let systemPrompt: String = """
    You are the context selector for a macOS computer-use agent.

    You receive a JSON payload describing what the user is doing right now:
    a voice transcript, the current screen (AX elements, OCR, focused element,
    selection, clipboard, app-specific data), the user's preferences, the
    user's active task, recent events and resources, learned per-surface UI
    knowledge, a recent chronological story of activity, and per-app recipes.

    Your job is to convert this into a STRUCTURED brief the agent will use to
    act. You MUST return a JSON object matching the schema below, filling
    EVERY required field. The agent has NO MEMORY between turns and CANNOT
    see the screen until it takes a screenshot. Every useful navigation
    anchor, AX path, learned control, or recipe step MUST appear in the brief.
    The cost of a redundant anchor is 5 tokens; the cost of an omitted one is
    a wasted screenshot and a slow turn. Bias hard toward inclusion.

    Important inputs:
    - `learned_surfaces`: per-(app, surface) UI knowledge built from many
      prior passive observations. Entries that match the current screen are
      GROUND TRUTH about controls and locations. When an entry matches the
      current surface, you MUST cite at least its top-3 controls by
      `seen_count` in `navigation_anchors`, even if you think the agent
      could find them on its own.
    - `recent_story`: chronological story of recent activity with per-entry
      `narrative`, `current_goal_guess`, `content_type`, `artifact`. Use it
      to resolve deictic references ("the letter", "her", "that PR") against
      what the user has actually been touching. Never reproduce raw artifact
      bodies in the brief — summarize them.
    - `active_task`: rolling task object with label, narrative, resources.
      Use `resources[]` for "the X I was working on".
    - `recipes_for_active_app`: promoted L3 recipes (sequences seen ≥3 times).
      Prefer them over computer-vision steps when available.

    Output schema — return EXACTLY this JSON object:

    {
      "intent": {
        "verb":            string,
        "target":          string | null,
        "resolved_target": string | null,
        "entities":        [{"label": string, "kind": string, "resolved_to": string | null}],
        "confidence":      number
      },
      "brief": {
        "goal":            string,                          // one sentence, all references resolved
        "current_surface": {
          "app":             string,
          "surface":         string | null,
          "focused_element": string | null
        } | null,
        "navigation_anchors": [
          {"label": string, "ax_path": string | null, "source": string}
        ],
        "resolved_references": [
          {"phrase": string, "resolved_to": string, "evidence": string | null}
        ],
        "steps": [
          {"tool": string, "value": string, "note": string | null}
        ],
        "watch_out_for": [string]
      }
    }

    Field rules:
    - `intent.target` is the thing being acted on. Indirect-object recipients
      (a person something is being sent to) belong in `entities`, not `target`.
    - `navigation_anchors`: REQUIRED whenever ANY UI signal is in the payload
      (current AX elements, a matching learned_surfaces entry, or recipes).
      Each `source` should be one of: "learned (Nx)", "L2 AX", "recipe:<name>",
      "active_task", "resource_index". Use an empty array only when no UI
      signal exists at all.
    - `resolved_references`: include one entry per deictic phrase in the
      transcript ("it", "her", "that", "this", "the X"). If unresolved,
      set `resolved_to` to "" and lower `intent.confidence`.
    - `steps.tool` MUST be one of: `open_url`, `applescript`, `run_shortcut`,
      `menu_shortcut`, `ax_press`, `type`, `key`, `computer`. List in
      preference order — fastest tool first.
    - Never invent AX paths, URIs, or recipe steps you weren't shown.
    - Coordinate-free. Never emit pixel coordinates.
    - Strict JSON. No backticks. No prose outside the JSON.
    """

    // MARK: - Prompt builder

    private static func buildSelectorPrompt(
        transcript: String,
        l2: CL2Snapshot,
        activeTask: CActiveTask?,
        recipes: [CRecipe],
        resources: [CResourceRef],
        events: [CEvent],
        userPrefs: String
    ) throws -> String {
        /// Compact per-entry projection of `SurfaceObservation`. Drops fields
        /// Mercury doesn't need (controls, correlations, latency, allVisibleApps)
        /// to keep prompt size bounded.
        struct StoryEntry: Encodable {
            let t: Date
            let app: String?
            let surface: String?
            let narrative: String?
            let current_goal_guess: String?
            let content_type: String?
            let artifacts: [SurfaceObservation.Artifact]?
        }

        struct Payload: Encodable {
            let transcript: String
            let current_screen: CL2Snapshot
            let user_prefs: String
            let active_task: CActiveTask?
            let recent_events: [CEvent]
            let recent_resources: [CResourceRef]
            let recipes_for_active_app: [CRecipe]
            let learned_surfaces: [SurfaceMemoryStore.SurfaceMemory]
            let recent_story: [StoryEntry]
        }

        // Rank learned surfaces: any surface whose label shares a token with
        // the live window title floats above frequency-only ordering. Within
        // each surface, controls whose labels appear in the transcript are
        // boosted ahead of high-frequency-but-irrelevant ones.
        let allMemories = SurfaceMemoryStore.shared.memories(forBundle: l2.bundleID)
        let lowerTranscript = transcript.lowercased()
        var matchesCurrent: [SurfaceMemoryStore.SurfaceMemory] = []
        var others: [SurfaceMemoryStore.SurfaceMemory] = []
        for mem in allMemories {
            if Self.surfaceMatchesTitle(mem.surface, title: l2.windowTitle) {
                matchesCurrent.append(mem)
            } else {
                others.append(mem)
            }
        }
        let learned: [SurfaceMemoryStore.SurfaceMemory] = (
            matchesCurrent.sorted { $0.observationCount > $1.observationCount } +
            others.sorted { $0.observationCount > $1.observationCount }
        ).prefix(6).map { mem in
            var trimmed = mem
            trimmed.controls = Array(mem.controls.sorted { lhs, rhs in
                let lInTranscript = lowerTranscript.contains(lhs.label.lowercased())
                let rInTranscript = lowerTranscript.contains(rhs.label.lowercased())
                if lInTranscript != rInTranscript { return lInTranscript }
                return lhs.seenCount > rhs.seenCount
            }.prefix(12))
            return trimmed
        }

        // Last 20 story entries within the 5-minute window.
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
                    artifacts: obs.artifacts
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
        let data = try Self.promptEncoder.encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Response parser

    private static let jsonDecoder = JSONDecoder()

    private static let promptEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Decode Mercury's `{intent, brief}` envelope. Robust: when `intent` is
    /// malformed but `brief` is valid we still return — the brief is the
    /// load-bearing artifact for the harness.
    private static func parseResponse(_ raw: String) -> (intent: CIntent, brief: StructuredBrief)? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let briefAny = obj["brief"],
              let briefData = try? JSONSerialization.data(withJSONObject: briefAny),
              let brief = try? jsonDecoder.decode(StructuredBrief.self, from: briefData)
        else { return nil }

        let intent: CIntent
        if let intentAny = obj["intent"],
           let intentData = try? JSONSerialization.data(withJSONObject: intentAny),
           let parsed = try? jsonDecoder.decode(CIntent.self, from: intentData) {
            intent = parsed
        } else {
            intent = CIntent(verb: "do", target: nil, resolvedTarget: nil, entities: [], confidence: 0.2)
        }
        return (intent, brief)
    }

    // MARK: - Surface matching

    /// Fuzzy match between a learned surface label and the live window title.
    /// Tokenizes both into alphanumeric chunks ≥3 chars; returns true on any
    /// shared token.
    private static func surfaceMatchesTitle(_ surface: String, title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return !tokens(surface).intersection(tokens(title)).isEmpty
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    /// True when the active_task mentions the live app/bundleID anywhere in
    /// its label, narrative, or resources.
    private static func currentTaskCoversBundle(_ task: CActiveTask?, l2: CL2Snapshot) -> Bool {
        guard let task else { return false }
        let needles = [l2.bundleID.lowercased(), l2.app.lowercased()].filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let haystack = ([task.label, task.narrative] + task.resources)
            .joined(separator: " ")
            .lowercased()
        return needles.contains(where: { haystack.contains($0) })
    }

    /// True iff at least one learned surface for the live bundleID both matches
    /// the live window title AND has any controls.
    private static func hadMatchingLearnedSurface(l2: CL2Snapshot) -> Bool {
        SurfaceMemoryStore.shared
            .memories(forBundle: l2.bundleID)
            .contains { mem in
                surfaceMatchesTitle(mem.surface, title: l2.windowTitle) && !mem.controls.isEmpty
            }
    }

    // MARK: - Markdown renderer

    /// Render a `StructuredBrief` into the markdown the harness consumes via
    /// `Input.contextSummary`. Sections with empty arrays / nil fields are omitted.
    private static func renderMarkdown(_ b: StructuredBrief) -> String {
        var lines: [String] = []
        lines.append("## What the user wants")
        lines.append(b.goal)
        lines.append("")

        if let cs = b.currentSurface {
            lines.append("## You are here")
            var loc = "- App: \(cs.app)"
            if let s = cs.surface, !s.isEmpty { loc += " — \(s)" }
            lines.append(loc)
            if let f = cs.focusedElement, !f.isEmpty {
                lines.append("- Focused: \(f)")
            }
            if !b.navigationAnchors.isEmpty {
                lines.append("- Anchors:")
                for a in b.navigationAnchors {
                    let path = (a.axPath?.isEmpty == false) ? " — `\(a.axPath!)`" : ""
                    lines.append("  - \(a.label)\(path) _(\(a.source))_")
                }
            }
            lines.append("")
        } else if !b.navigationAnchors.isEmpty {
            lines.append("## Anchors")
            for a in b.navigationAnchors {
                let path = (a.axPath?.isEmpty == false) ? " — `\(a.axPath!)`" : ""
                lines.append("- \(a.label)\(path) _(\(a.source))_")
            }
            lines.append("")
        }

        if !b.steps.isEmpty {
            lines.append("## How to do it")
            for (i, s) in b.steps.enumerated() {
                let note = (s.note?.isEmpty == false) ? " — \(s.note!)" : ""
                lines.append("\(i + 1). **\(s.tool)** `\(s.value)`\(note)")
            }
            lines.append("")
        }

        if !b.resolvedReferences.isEmpty {
            lines.append("## What references mean")
            for r in b.resolvedReferences where !r.resolvedTo.isEmpty {
                let ev = (r.evidence?.isEmpty == false) ? " _(\(r.evidence!))_" : ""
                lines.append("- **\"\(r.phrase)\"** → \(r.resolvedTo)\(ev)")
            }
            lines.append("")
        }

        if !b.watchOutFor.isEmpty {
            lines.append("## Watch out for")
            for w in b.watchOutFor { lines.append("- \(w)") }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - StructuredBrief

/// Typed shape Mercury must fill in. Driven by the system-prompt schema.
/// Decoding-fail acts as the validation gate: if Mercury drops a required
/// field, the selector falls through to `LocalBriefRenderer`.
public struct StructuredBrief: Codable {
    public let goal: String
    public let currentSurface: CurrentSurface?
    public let navigationAnchors: [NavigationAnchor]
    public let resolvedReferences: [ResolvedReference]
    public let steps: [Step]
    public let watchOutFor: [String]

    public struct CurrentSurface: Codable {
        public let app: String
        public let surface: String?
        public let focusedElement: String?
        enum CodingKeys: String, CodingKey {
            case app, surface
            case focusedElement = "focused_element"
        }
    }

    public struct NavigationAnchor: Codable {
        public let label: String
        public let axPath: String?
        public let source: String
        enum CodingKeys: String, CodingKey {
            case label, source
            case axPath = "ax_path"
        }
    }

    public struct ResolvedReference: Codable {
        public let phrase: String
        public let resolvedTo: String
        public let evidence: String?
        enum CodingKeys: String, CodingKey {
            case phrase, evidence
            case resolvedTo = "resolved_to"
        }
    }

    public struct Step: Codable {
        public let tool: String
        public let value: String
        public let note: String?
    }

    enum CodingKeys: String, CodingKey {
        case goal, steps
        case currentSurface = "current_surface"
        case navigationAnchors = "navigation_anchors"
        case resolvedReferences = "resolved_references"
        case watchOutFor = "watch_out_for"
    }
}
