import Foundation

/// Continuous, throttled, single-call Gemini Flash Lite observer that watches
/// the user's screen passively and produces structured `SurfaceObservation`s.
///
/// Triggered by `ContextCoordinator.capture(...)` after a major-change capture.
/// Throttled to one observation every `minIntervalBetweenObservations` seconds.
///
/// On success the observation lands in THREE independent sinks, each serving
/// a different consumer:
///   - `ScreenObservationLog`  — in-memory ring for the live DevTools "Screen Obs" tab
///   - `SurfaceMemoryStore`    — per-(app, surface) UI knowledge accumulator
///                               (the "agent learning UI without being told" map)
///   - `CaptureStoryLog`       — append-only chronological story (S17) the
///                               Selector reads at long-press time so Mercury
///                               can write briefs with real continuity
///
/// This observer does NOT drive Mercury directly — it builds the substrate
/// Mercury reads.
public final class GeminiObserver {
    public static let shared = GeminiObserver()

    private var lastObservedAt: Date = .distantPast
    private static let minIntervalBetweenObservations: TimeInterval = 8.0   // >= 8s between calls
    private let queue = DispatchQueue(label: "AgentNotch.GeminiObserver.queue")

    public init() {}

    /// Try to observe this screen. Throttled. Returns silently if too soon,
    /// disabled by settings, or no Gemini key is set.
    ///
    /// `bundleID` is system-provided (NSWorkspace.frontmostApplication) and
    /// stamped onto the resulting `SurfaceObservation` so `SurfaceMemoryStore`
    /// can key on it. Gemini sees only `frontmostHint` (a display name) as a
    /// nudge — it cannot infer bundle IDs from pixels.
    public func observe(screenshotPNG: Data, frontmostHint: String? = nil, bundleID: String? = nil) async {
        let now = Date()
        let shouldRun: Bool = queue.sync {
            guard now.timeIntervalSince(lastObservedAt) >= Self.minIntervalBetweenObservations else { return false }
            lastObservedAt = now
            return true
        }
        guard shouldRun else { return }

        let enabled = await MainActor.run { AgentSettingsStore.shared.geminiObserverEnabled }
        guard enabled else { return }
        guard Secrets.geminiAPIKey != nil else { return }    // no key -> skip silently

        let started = Date()
        let systemPrompt = Self.systemPrompt
        let userText = Self.userText(frontmostHint: frontmostHint)

        let raw: String
        do {
            raw = try await GeminiVisionClient.shared.generate(
                systemPrompt: systemPrompt,
                userText: userText,
                imagePNG: screenshotPNG,
                timeout: 60.0
            )
        } catch {
            // GeminiVisionClient already logged the failure to AgentObservabilityLog
            // via the new .geminiCall event — nothing else to do here.
            return
        }

        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ObservationDTO.self, from: data) else {
            // Successful HTTP but observation didn't parse — log it so we can debug.
            AgentObservabilityLog.shared.record(.memoryMutation(
                id: UUID(), t: now, kind: .resourceRecorded,
                summary: "screen obs FAILED parse — raw response preview: \(raw.prefix(300))"
            ))
            return
        }

        let latency = Date().timeIntervalSince(started)

        let obs = SurfaceObservation(
            t: now,
            frontmostApp: parsed.frontmostApp,
            bundleID: bundleID,
            allVisibleApps: parsed.allVisibleApps ?? [],
            screenLayout: parsed.screenLayout,
            currentSurface: parsed.currentSurface,
            observableControls: parsed.observableControls?.map {
                SurfaceObservation.Control(label: $0.label, purpose: $0.purpose, location: $0.location, iconHint: $0.iconHint)
            } ?? [],
            crossAppCorrelations: parsed.crossAppCorrelations ?? [],
            userVisibleState: parsed.userVisibleState,
            modelLatencyS: latency,
            narrative: parsed.narrative,
            currentGoalGuess: parsed.currentGoalGuess,
            continuityLink: parsed.continuityLink,
            contentType: parsed.contentType,
            artifacts: parsed.artifacts?.map {
                SurfaceObservation.Artifact(app: $0.app, contentType: $0.contentType, payload: $0.payload)
            }
        )

        ScreenObservationLog.shared.record(obs)
        SurfaceMemoryStore.shared.accumulate(obs)
        CaptureStoryLog.shared.record(obs)
        AgentObservabilityLog.shared.record(.memoryMutation(
            id: UUID(), t: now, kind: .resourceRecorded,
            summary: "screen obs: \(obs.frontmostApp ?? "?") · \(obs.currentSurface ?? "?") · \(obs.observableControls.count) controls"
        ))
    }

    // MARK: - Prompt

    /// Static, cacheable system prompt. Keep this stable across calls — anything
    /// that varies per call belongs in `userText(frontmostHint:)`.
    private static let systemPrompt: String = """
    You are watching a user's macOS screen passively. Look at this screenshot and
    produce a STRUCTURED JSON observation that captures THREE things:
      (a) UI/UX of the frontmost window so a future agent can act on it,
      (b) what the USER is doing right now (the human, not the pixels),
      (c) STRUCTURED CONTENT from every visible app's window that carries
          something specific — multiple apps means multiple artifacts.

    Return strictly one JSON object matching this schema (snake_case keys):

    {
      "frontmost_app":           "the app whose window is in focus",
      "all_visible_apps":        ["EVERY app whose window content is visible — frontmost first, then background windows, sidebars, split-screen partners. Read window chrome titles to confirm. Do not omit apps just because they aren't focused."],
      "screen_layout":           "one sentence describing the spatial layout (e.g. 'TextEdit fills the left half; Brave is split on the right with Slack peeking in the bottom-right corner')",
      "current_surface":         "specific surface within the frontmost app (e.g. 'Slack #design composer', 'Figma Onboarding-v3 / Step 2', 'Notes - Letter to Marcus')",
      "observable_controls":     [{"label": string, "purpose": string, "location": string, "icon_hint": string|null}],
      "cross_app_correlations":  ["sentences about how visible apps relate (e.g. 'Slack DM references the Figma file shown on the right'). 0-3 entries. Only when a real link is visible."],
      "user_visible_state":      "what the user appears to be doing right now",

      "narrative":           "1-2 sentences about what the USER is doing (not the screen — the user). Name people, files, channels VERBATIM. e.g. 'User is drafting a follow-up letter to Marcus about Q3 timelines; cursor sits in the middle of the second paragraph.'",
      "current_goal_guess":  "one short phrase guessing the user's current goal. e.g. 'Send Marcus a Q3 update'",
      "continuity_link":     "one sentence linking to recent activity if visible; null if not inferable.",
      "content_type":        "PRIMARY content type — frontmost app's content. One of: document | form | chat | code | settings | browser_article | email | media | other",

      "artifacts":           [
        // One entry per VISIBLE app that has actionable content. The frontmost
        // app's artifact MUST be present if it has any content. Background
        // apps appear here when their visible region has something specific
        // (a chat message, a code line, a doc paragraph, an article title).
        // Skip apps that are visible but show nothing extractable.
        {
          "app":          "the app this artifact belongs to (must appear in all_visible_apps)",
          "content_type": "one of: document | form | chat | code | settings | browser_article | email | media | other",
          "payload":      "object whose shape depends on content_type — see below"
        }
      ]
    }

    Payload schema by content_type. Be SPECIFIC. Pull names, URLs, file paths,
    function names, line numbers, channel names, addressees VERBATIM. Capture
    the user's current attention point (selection, cursor, scrolled-to section)
    when visible.

      document -> {
        "title":              string,
        "body_excerpt":       string (≤800 chars, VERBATIM from the screen),
        "word_count":         int|null,
        "addressee":          string|null,
        "visible_headings":   [string],          // headings within the visible viewport
        "selection":          string|null,       // currently selected text
        "caret_context":      string|null,       // ≤200 chars around the cursor if visible
        "last_paragraph":     string|null        // ≤200 chars of the most-recently-touched paragraph
      }
      form -> {
        "fields":              [{"label": string, "value": string|null, "type": string}],
        "submit_label":        string|null,
        "validation_errors":   [string]          // visible inline errors
      }
      chat -> {
        "channel_or_dm":       string|null,      // e.g. '#design' or 'DM with Sarah Chen'
        "thread_topic":        string|null,
        "messages":            [{"author": string, "excerpt": string, "timestamp_label": string|null, "attachments": [string]}],
        "composer_draft":      string|null,      // what's typed but not sent
        "unread_indicator":    string|null       // e.g. '3 new', '@mention'
      }
      code -> {
        "file_path":           string|null,      // VERBATIM — relative or absolute as shown
        "language":            string,
        "focused_function":    string|null,
        "visible_symbols":     [string],         // function/class/type names visible
        "imports":             [string],         // visible import statements
        "selection":           string|null,
        "cursor_line":         string|null,      // ≤120 chars of the current line if visible
        "error_indicators":    [string]          // squiggles, error text, panel errors
      }
      settings -> {
        "panel_name":          string,
        "visible_options":     [string],
        "current_values":      [{"label": string, "value": string}]
      }
      browser_article -> {
        "url":                 string|null,      // from address bar — VERBATIM
        "title":               string,
        "lede":                string,           // first paragraph or visible intro
        "visible_section":     string|null,      // current heading scrolled-to
        "visible_links":       [string]          // up to 5 anchor texts of links in viewport
      }
      email -> {
        "from":                string|null,
        "to":                  string|null,
        "cc":                  [string],
        "subject":             string|null,
        "body_excerpt":        string,           // ≤600 chars VERBATIM
        "attachments":         [string],
        "date":                string|null
      }
      media -> {
        "media_type":          string,           // video | audio | image
        "title":               string|null,
        "creator":             string|null,
        "position":            string|null,
        "playback_state":      string|null       // playing | paused | buffering
      }
      other -> { "summary": string }

    Rules:
    - `observable_controls` describes ONLY the frontmost app's UI. Artifacts
      describe per-app CONTENT. Don't mix them — a background app's controls
      don't belong in observable_controls, and the frontmost UI chrome
      doesn't belong in any artifact payload.
    - Up to 12 observable_controls, prioritized by likely relevance to action.
    - Up to 4 artifacts. Frontmost first, then visible others. Empty array is
      valid if literally nothing is extractable.
    - For each control: label = visible text OR what an agent would call it;
      purpose = what it does; location = "top-right of toolbar" / "bottom-left
      of composer" etc; icon_hint = "paper plane" / "paperclip" / null.
    - Never invent. If a field can't be read, set it to null (or empty array).
    - body_excerpt / cursor_line / selection / caret_context / lede must be
      VERBATIM from the screen. Do not paraphrase or correct typos.
    - all_visible_apps must include the frontmost; do not omit background
      windows that have content.
    - Strict JSON. No backticks. No prose outside the JSON.
    """

    /// Per-call tail — varies between requests so must not be folded into the
    /// (future) cached prefix.
    private static func userText(frontmostHint: String?) -> String {
        guard let hint = frontmostHint else { return "" }
        return "Currently frontmost app: \(hint)"
    }

    // MARK: - Parse DTO (snake_case wire shape)

    private struct ObservationDTO: Decodable {
        let frontmostApp: String?
        let allVisibleApps: [String]?
        let screenLayout: String?
        let currentSurface: String?
        let observableControls: [Ctrl]?
        let crossAppCorrelations: [String]?
        let userVisibleState: String?

        // S17: Capture Story fields. All optional — Gemini may omit any.
        let narrative: String?
        let currentGoalGuess: String?
        let continuityLink: String?
        let contentType: String?
        /// Per-visible-app structured content. Gemini emits one entry per app
        /// that has actionable content (frontmost + visible background windows).
        /// Heterogeneous payload — kept as untyped JSON because the per-type
        /// schemas vary and Mercury consumes it as JSON anyway.
        let artifacts: [ArtifactDTO]?

        struct Ctrl: Decodable {
            let label: String
            let purpose: String?
            let location: String?
            let iconHint: String?
            enum CodingKeys: String, CodingKey {
                case label, purpose, location, iconHint = "icon_hint"
            }
        }
        struct ArtifactDTO: Decodable {
            let app: String
            let contentType: String
            let payload: [String: AnyCodable]
            enum CodingKeys: String, CodingKey {
                case app
                case contentType = "content_type"
                case payload
            }
        }
        enum CodingKeys: String, CodingKey {
            case frontmostApp = "frontmost_app"
            case allVisibleApps = "all_visible_apps"
            case screenLayout = "screen_layout"
            case currentSurface = "current_surface"
            case observableControls = "observable_controls"
            case crossAppCorrelations = "cross_app_correlations"
            case userVisibleState = "user_visible_state"
            case narrative
            case currentGoalGuess = "current_goal_guess"
            case continuityLink = "continuity_link"
            case contentType = "content_type"
            case artifacts
        }
    }
}
