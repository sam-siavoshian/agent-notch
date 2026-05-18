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
        /// Markdown rendering of the brief, handed to the computer-use harness
        /// verbatim. When Mercury succeeds this is rendered from `structuredBrief`
        /// in Swift (deterministic shape); when we fall back to LocalBriefRenderer
        /// it comes from there directly.
        public let brief: String
        /// Typed brief object as returned by Mercury. Nil when degraded — the
        /// LocalBriefRenderer path does not produce a structured shape today.
        /// Consumers that want to render the brief differently (Dev Tools,
        /// validation, future agents) should prefer this over `brief`.
        public let structuredBrief: StructuredBrief?
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

        // Refresh active_task when it's either time-stale OR doesn't cover the
        // current app. The second trigger matters when the 30s/90s gates in
        // ActiveTaskUpdater have blocked a recent app-switch tick: the user
        // long-presses in VSCode but the on-disk task still describes Slack.
        // Forcing a refresh here (tight 2s deadline) keeps Mercury from
        // writing a brief grounded in the wrong context.
        let staleThreshold: TimeInterval = 30.0
        let currentTask = L5Store.shared.loadActiveTask()
        let staleByTime = currentTask.flatMap { $0.staleSince.map { Date().timeIntervalSince($0) > staleThreshold } } ?? false
        let staleByContext = !Self.currentTaskCoversBundle(currentTask, l2: l2)
        let needsRefresh = staleByTime || staleByContext
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

        // Deterministic cross-app routing hint, computed BEFORE Mercury. If
        // the transcript names an entity that resolves to a different app
        // (e.g. "phone1k" → Discord while user is in Brave), this hint will
        // be prepended to the brief regardless of what Mercury writes. Belt-
        // and-suspenders against Mercury misrouting.
        let routingHint = Self.routingHint(transcript: transcript, currentApp: l2.app)

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
                    // Validation gate: if the user has a matching learned surface
                    // with controls, Mercury MUST have cited them in
                    // navigation_anchors. An empty anchors list when ground
                    // truth was available means Mercury "decided" the anchors
                    // weren't useful and dropped them — exactly the failure
                    // mode the structured brief is meant to catch. Log but
                    // proceed; the brief is still likely usable.
                    let hadMatchingLearned = Self.hadMatchingLearnedSurface(l2: l2)
                    if hadMatchingLearned && parsed.brief.navigationAnchors.isEmpty {
                        NSLog("[Selector] WARN: Mercury returned empty navigation_anchors despite matching learned surface for \(l2.bundleID) / \(l2.windowTitle ?? "?")")
                    }
                    let renderedBrief = Self.renderMarkdown(parsed.brief, routingHint: routingHint)
                    Self.persistBriefOutput(transcript: transcript, mercuryRaw: raw, renderedBrief: renderedBrief, routingHint: routingHint, degraded: false)
                    let result = Result(
                        intent: parsed.intent,
                        brief: renderedBrief,
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
                // Parse failed — fall through to local renderer.
            } catch {
                // Timeout, no key, malformed — fall through.
            }
        }

        // Local fallback — same routing hint applies, prepended to the local brief.
        let (intent, localBrief) = LocalBriefRenderer.render(
            transcript: transcript,
            l2: l2,
            activeTask: activeTask,
            recipesForActiveApp: recipes,
            recentResources: resources
        )
        let briefWithHint: String
        if let routingHint, !routingHint.isEmpty {
            briefWithHint = routingHint + "\n\n" + localBrief
        } else {
            briefWithHint = localBrief
        }
        Self.persistBriefOutput(transcript: transcript, mercuryRaw: nil, renderedBrief: briefWithHint, routingHint: routingHint, degraded: true)
        let result = Result(
            intent: intent,
            brief: briefWithHint,
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

    // MARK: - System prompt (kept here; Phase 5 cleanup can move to a shared constant)

    static let systemPrompt: String = """
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
      ALSO: when the transcript names a person, file, channel, or other
      entity (e.g. "phone1k", "the merge"), search ALL `learned_surfaces`
      AND `recent_resources` for that name — not just the current surface.
      If a surface/resource matches the named entity, set `steps[0]` to the
      app of THAT surface (e.g. Discord), EVEN IF a generic alternative like
      Messages or Mail would also work. The user's actual usage trumps the
      agent's AppleScript allowlist. Put the match in `resolved_references`
      with `evidence` citing the matching surface name + seen_count.
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
            /// Per-visible-app structured content from this observation.
            /// Mercury reads it to resolve deictic references — "the doc"
            /// pulls the entry whose content_type is document, "her message"
            /// pulls a chat entry, etc.
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

        // Tokenize the transcript ONCE up front. Used by every cross-cutting
        // ranking step below (surfaces, controls, resources, story). Drops
        // stopwords + tokens shorter than 3 chars to avoid junk hits on "to"
        // or "is".
        let lowerTranscript = transcript.lowercased()
        let tTokens = Self.transcriptTokens(transcript)

        // STAGE 1 — current-app surfaces. The window-title-matching ones float
        // up so a long-press in a niche surface (e.g. one specific Slack
        // channel) still surfaces even when busier channels dominate the
        // observationCount.
        let allMemories = SurfaceMemoryStore.shared.memories(forBundle: l2.bundleID)
        var matchesCurrent: [SurfaceMemoryStore.SurfaceMemory] = []
        var others: [SurfaceMemoryStore.SurfaceMemory] = []
        for mem in allMemories {
            if Self.surfaceMatchesTitle(mem.surface, title: l2.windowTitle) {
                matchesCurrent.append(mem)
            } else {
                others.append(mem)
            }
        }
        let currentRanked = matchesCurrent.sorted { $0.observationCount > $1.observationCount }
                          + others.sorted { $0.observationCount > $1.observationCount }

        // STAGE 2 — cross-app surfaces. Critical for cross-app intents like
        // "DM phone1k" issued while Brave is frontmost. Without this, the
        // bundle-scoped lookup above returns only Brave surfaces and Mercury
        // never sees that phone1k has 9 observations on Discord. The fallback
        // path is then a generic AppleScript Messages call.
        let crossAppMatches = SurfaceMemoryStore.shared.searchAcrossApps(
            matchingTokens: tTokens,
            limit: 4
        )

        // Merge with dedup. Cross-app matches go FIRST — they're explicitly
        // transcript-relevant, which is a stronger signal than current-surface
        // proximity. Dedup by (bundleID, surface) so a cross-app match doesn't
        // get re-included via the current-app path.
        var seen: Set<String> = []
        let learned: [SurfaceMemoryStore.SurfaceMemory] = (crossAppMatches + currentRanked)
            .filter { mem in
                let key = "\(mem.bundleID)\u{1F}\(mem.surface)"
                return seen.insert(key).inserted
            }
            .prefix(8)
            .map { mem -> SurfaceMemoryStore.SurfaceMemory in
                var trimmed = mem
                trimmed.controls = Array(mem.controls.sorted { lhs, rhs in
                    let lInTranscript = lowerTranscript.contains(lhs.label.lowercased())
                    let rInTranscript = lowerTranscript.contains(rhs.label.lowercased())
                    if lInTranscript != rInTranscript { return lInTranscript }
                    return lhs.seenCount > rhs.seenCount
                }.prefix(12))
                return trimmed
            }

        // Resources: existing order is lastSeen desc. Also boost any whose
        // label or URI contains a transcript token, so "the lethal company
        // repo" lifts the matching GitHub URL ahead of stale tabs.
        let rankedResources: [CResourceRef] = resources.sorted { lhs, rhs in
            let lScore = Self.resourceTokenScore(lhs, tokens: tTokens)
            let rScore = Self.resourceTokenScore(rhs, tokens: tTokens)
            if lScore != rScore { return lScore > rScore }
            return lhs.lastSeen > rhs.lastSeen
        }

        // Story: keep the rolling 5-minute "what's happening now" window, AND
        // bring in older entries whose narrative/goal/surface contains a
        // transcript token. Without the second arm, an entity reference older
        // than 5 minutes drops out entirely — e.g. "finish my message to
        // phone1k" 20 minutes after the draft was last visible.
        let storyWindowSeconds: TimeInterval = 300
        let now = Date()
        let allStory: [SurfaceObservation] = CaptureStoryLog.shared.tail(40)
        let storyFiltered: [SurfaceObservation] = allStory.filter { obs in
            if now.timeIntervalSince(obs.t) <= storyWindowSeconds { return true }
            guard !tTokens.isEmpty else { return false }
            let narrative: String = obs.narrative ?? ""
            let goal: String = obs.currentGoalGuess ?? ""
            let surface: String = obs.currentSurface ?? ""
            let hay: String = (narrative + " " + goal + " " + surface).lowercased()
            return tTokens.contains(where: { hay.contains($0) })
        }
        let storyTrimmed: [SurfaceObservation] = Array(storyFiltered.suffix(20))
        let recentStory: [StoryEntry] = storyTrimmed.map { obs in
            StoryEntry(
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
            recent_resources: Array(rankedResources.prefix(20)),
            recipes_for_active_app: Array(recipes.sorted { $0.seenCount > $1.seenCount }.prefix(8)),
            learned_surfaces: learned,
            recent_story: recentStory
        )
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        Self.persistPayload(transcript: transcript, payloadJSON: json)
        return json
    }

    // MARK: - Response parser

    /// Decode Mercury's `{intent, brief}` envelope where `brief` is now a typed
    /// `StructuredBrief` object (no longer a free-form markdown string). Robust:
    /// when `intent` is malformed but `brief` is valid we still return — the
    /// brief is the load-bearing artifact for the harness.
    static func parseResponse(_ raw: String) -> (intent: CIntent, brief: StructuredBrief)? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let briefAny = obj["brief"],
              let briefData = try? JSONSerialization.data(withJSONObject: briefAny),
              let brief = try? JSONDecoder().decode(StructuredBrief.self, from: briefData)
        else { return nil }

        var intent: CIntent
        if let intentAny = obj["intent"],
           let intentData = try? JSONSerialization.data(withJSONObject: intentAny),
           let parsed = try? JSONDecoder().decode(CIntent.self, from: intentData) {
            intent = parsed
        } else {
            intent = CIntent(verb: "do", target: nil, resolvedTarget: nil, entities: [], confidence: 0.2)
        }
        return (intent, brief)
    }

    // MARK: - Surface matching

    /// Fuzzy match between a learned surface label and the live window title.
    /// Tokenizes both into alphanumeric chunks ≥3 chars and returns true on
    /// any shared token. Cheap, language-agnostic, and good enough to catch
    /// "Slack #design composer" ↔ "Slack — design" without dragging in a
    /// real string-similarity dependency.
    static func surfaceMatchesTitle(_ surface: String, title: String?) -> Bool {
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

    /// Common English words and voice-command verbs that carry no entity
    /// signal. Filtered out of transcript tokens so "let phone 1k know" ranks
    /// surfaces by "phone" and the "1k"/"phone1k" component, not by garbage
    /// matches on "let" or "know".
    private static let transcriptStopwords: Set<String> = [
        "the", "and", "for", "you", "your", "yours", "let", "tell", "him", "her",
        "they", "them", "this", "that", "those", "these", "with", "from", "into",
        "have", "has", "had", "need", "needs", "wants", "want", "wanted", "know",
        "knows", "knew", "make", "send", "say", "ask", "show", "open", "find",
        "got", "put", "what", "when", "where", "why", "how", "who", "now",
        "then", "are", "was", "were", "will", "would", "should", "could", "can",
        "him", "his", "hers", "she", "ours", "their", "but", "and"
    ]

    /// Tokenize a transcript for cross-cutting ranking. Drops stopwords and
    /// tokens < 3 chars. Returns a deduplicated list (order does not matter
    /// for the matching loops downstream).
    static func transcriptTokens(_ transcript: String) -> [String] {
        Array(
            Set(
                transcript.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 3 && !transcriptStopwords.contains($0) }
            )
        )
    }

    /// Count of transcript tokens appearing in a resource's label or URI.
    /// Used to re-rank `recent_resources` so transcript-relevant URIs ("the
    /// lethal company repo") sort ahead of stale-but-recent ones.
    static func resourceTokenScore(_ r: CResourceRef, tokens: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        let labelPart: String = r.label ?? ""
        let hay: String = (labelPart + " " + r.uri).lowercased()
        return tokens.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
    }

    /// Deterministic cross-app routing hint, prepended to the brief BEFORE
    /// Mercury's structured output. This is the belt-and-suspenders fix for
    /// the "Mercury sees Discord phone1k but Claude still opens Messages"
    /// failure mode. The hint is computed from `SurfaceMemoryStore` directly,
    /// independent of Mercury, so the routing decision is guaranteed to reach
    /// Claude even if Mercury misbehaves or omits the relevant `steps[0]`.
    ///
    /// Fires only when:
    ///   1. The transcript has tokens that match surfaces in some other app
    ///   2. There is a clear app winner (more evidence than the runner-up)
    ///   3. The winning app is NOT the current frontmost (otherwise no
    ///      cross-app routing is needed — the agent can act in place)
    static func routingHint(transcript: String, currentApp: String?) -> String? {
        let tokens = transcriptTokens(transcript)
        guard !tokens.isEmpty else { return nil }
        let matches = SurfaceMemoryStore.shared.searchAcrossApps(matchingTokens: tokens, limit: 6)
        guard !matches.isEmpty else { return nil }

        // Aggregate by app name (NOT bundleID — same app accessed via web +
        // native should count together).
        var byApp: [String: (total: Int, surfaces: [String])] = [:]
        for m in matches {
            var entry = byApp[m.app] ?? (0, [])
            entry.total += m.observationCount
            entry.surfaces.append(m.surface)
            byApp[m.app] = entry
        }
        let ranked = byApp.map { (app: $0.key, total: $0.value.total, surfaces: $0.value.surfaces) }
            .sorted { $0.total > $1.total }
        guard let top = ranked.first else { return nil }

        // Skip when the matched app is already frontmost — no cross-app
        // routing needed there; the agent should ax_press inside the surface.
        if let currentApp, top.app.caseInsensitiveCompare(currentApp) == .orderedSame {
            return nil
        }

        // Only emit when the winner has substantially more evidence than the
        // runner-up. Without this guard, a single transcript token matching
        // two unrelated apps would emit a misleading hint.
        let runnerUp = ranked.dropFirst().first?.total ?? 0
        guard top.total > runnerUp else { return nil }

        let surfaceExamples = top.surfaces.prefix(3).joined(separator: ", ")
        let transcriptShort = String(transcript.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))

        return """
        ## ROUTING — open \(top.app) first
        The voice transcript ("\(transcriptShort)") names an entity that resolves to **\(top.app)** based on \(top.total) prior observations across \(top.surfaces.count) learned surfaces: \(surfaceExamples). Use `open_app` with name "\(top.app)" as your FIRST tool. Do NOT default to Messages or Mail just because the verb sounds messaging-like — the user does not contact this person there.
        """
    }

    // MARK: - Payload persistence

    /// Append-only JSONL log of every Mercury payload, written to
    /// ~/Library/Application Support/AgentNotch/ContextMemory/mercury-payloads.jsonl.
    /// One line per long-press. Makes the question "did Mercury actually see
    /// X?" falsifiable — without this we can only see Mercury's RESPONSE in
    /// Dev Tools, not the input that produced it, so prompt-rule regressions
    /// are silent. Best-effort: disk write failure does not block the run.
    private static let payloadsFile: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mercury-payloads.jsonl")
    }()

    private static let payloadsQueue = DispatchQueue(label: "AgentNotch.Selector.payloadsQueue", qos: .utility)

    private static func persistPayload(transcript: String, payloadJSON: String) {
        payloadsQueue.async {
            let envelope: [String: Any] = [
                "kind": "input",
                "t": ISO8601DateFormatter().string(from: Date()),
                "transcript": transcript,
                "payload": (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))) ?? payloadJSON
            ]
            appendEnvelope(envelope)
        }
    }

    /// Append a second JSONL line for the same long-press carrying Mercury's
    /// raw response, the markdown brief that Claude actually saw, the
    /// routing hint that was injected (or nil), and whether we degraded to
    /// the LocalBriefRenderer. Together with the matching `input` line this
    /// gives a complete forensic record per long-press.
    private static func persistBriefOutput(transcript: String, mercuryRaw: String?, renderedBrief: String, routingHint: String?, degraded: Bool) {
        payloadsQueue.async {
            var envelope: [String: Any] = [
                "kind": "output",
                "t": ISO8601DateFormatter().string(from: Date()),
                "transcript": transcript,
                "degraded": degraded,
                "rendered_brief": renderedBrief
            ]
            if let mercuryRaw {
                // Embed the parsed JSON if possible so jq/grep can drill in.
                if let parsed = try? JSONSerialization.jsonObject(with: Data(mercuryRaw.utf8)) {
                    envelope["mercury_raw"] = parsed
                } else {
                    envelope["mercury_raw"] = mercuryRaw
                }
            }
            if let routingHint {
                envelope["routing_hint"] = routingHint
            }
            appendEnvelope(envelope)
        }
    }

    /// MUST be called from `payloadsQueue`. Best-effort append; failure is
    /// logged via NSLog so the long-press doesn't block on disk.
    private static func appendEnvelope(_ envelope: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        var line = data
        line.append(0x0A) // \n
        if let h = try? FileHandle(forWritingTo: payloadsFile) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: payloadsFile, options: [.atomic])
        }
    }

    /// True when the on-disk active_task mentions the live app/bundleID
    /// anywhere in its label, narrative, or resources. When false, the task
    /// is "context-stale" relative to where the user is right now and the
    /// Selector forces a refresh regardless of `staleSince`.
    static func currentTaskCoversBundle(_ task: CActiveTask?, l2: CL2Snapshot) -> Bool {
        guard let task else { return false }
        let needles = [l2.bundleID.lowercased(), l2.app.lowercased()].filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        let haystack = ([
            task.label,
            task.narrative
        ] + task.resources).joined(separator: " ").lowercased()
        return needles.contains(where: { haystack.contains($0) })
    }

    /// True iff at least one learned surface for the live bundleID both
    /// matches the live window title AND has any controls. Used by `select`
    /// to detect when Mercury silently dropped anchors despite ground truth.
    static func hadMatchingLearnedSurface(l2: CL2Snapshot) -> Bool {
        SurfaceMemoryStore.shared
            .memories(forBundle: l2.bundleID)
            .contains { mem in
                surfaceMatchesTitle(mem.surface, title: l2.windowTitle) && !mem.controls.isEmpty
            }
    }

    // MARK: - Markdown renderer

    /// Render a `StructuredBrief` into the markdown the harness has always
    /// consumed via `Input.contextSummary`. The shape is deterministic and
    /// driven entirely by what Mercury filled in — Swift never paraphrases,
    /// reorders, or invents. Sections with empty arrays / nil fields are
    /// omitted so the rendered prose stays tight.
    ///
    /// `routingHint` is prepended verbatim BEFORE Mercury's output. It is
    /// computed deterministically from `SurfaceMemoryStore`, so even if
    /// Mercury writes a wrong-app brief the routing decision still reaches
    /// Claude.
    static func renderMarkdown(_ b: StructuredBrief, routingHint: String? = nil) -> String {
        var lines: [String] = []
        if let routingHint, !routingHint.isEmpty {
            lines.append(routingHint)
            lines.append("")
        }
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

/// Typed shape Mercury must fill in. Driven by the system-prompt schema in
/// `ContextSelector.systemPrompt`. Decoding-fail acts as the validation
/// gate: if Mercury drops a required field, the selector falls through to
/// `LocalBriefRenderer`.
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
