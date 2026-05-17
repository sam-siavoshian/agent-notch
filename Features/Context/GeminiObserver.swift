import Foundation

/// Continuous, throttled, single-call Gemini Flash Lite observer that watches
/// the user's screen passively and produces structured `SurfaceObservation`s.
///
/// Triggered by `ContextCoordinator.capture(...)` after a major-change capture.
/// Throttled to one observation every `minIntervalBetweenObservations` seconds.
/// On success the observation is appended to `ScreenObservationLog` (the live
/// stream) and merged into `SurfaceMemoryStore` (the persistent per-surface
/// UI/UX knowledge the Selector consults at long-press time).
///
/// This is the "agent learning UI without being told" engine. It does NOT
/// drive Mercury directly — it builds the substrate Mercury reads.
public final class GeminiObserver {
    public static let shared = GeminiObserver()

    private var lastObservedAt: Date = .distantPast
    private static let minIntervalBetweenObservations: TimeInterval = 8.0   // >= 8s between calls
    private let queue = DispatchQueue(label: "AgentNotch.GeminiObserver.queue")

    public init() {}

    /// Try to observe this screen. Throttled. Returns silently if too soon,
    /// disabled by settings, or no Gemini key is set.
    public func observe(screenshotPNG: Data, frontmostHint: String? = nil) async {
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
            allVisibleApps: parsed.allVisibleApps ?? [],
            screenLayout: parsed.screenLayout,
            currentSurface: parsed.currentSurface,
            observableControls: (parsed.observableControls ?? []).map {
                SurfaceObservation.Control(label: $0.label, purpose: $0.purpose, location: $0.location, iconHint: $0.iconHint)
            },
            crossAppCorrelations: parsed.crossAppCorrelations ?? [],
            userVisibleState: parsed.userVisibleState,
            modelLatencyS: latency
        )

        ScreenObservationLog.shared.record(obs)
        SurfaceMemoryStore.shared.accumulate(obs)
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
    produce a STRUCTURED JSON observation that teaches an agent the UI/UX of what's
    visible. Future agent runs will reuse what you observe.

    Return strictly one JSON object matching this schema (snake_case keys):

    {
      "frontmost_app":           "the app whose window is in focus",
      "all_visible_apps":        ["list", "of", "all", "apps", "with", "visible", "windows"],
      "screen_layout":           "one sentence describing the spatial layout of windows",
      "current_surface":         "specific surface within the frontmost app (e.g. 'Slack #design composer', 'Figma Onboarding-v3 / Step 2')",
      "observable_controls":     [{"label": string, "purpose": string, "location": string, "icon_hint": string|null}],
      "cross_app_correlations":  ["sentences about how visible apps relate to each other"],
      "user_visible_state":      "what the user appears to be doing right now"
    }

    Rules:
    - Focus on ACTIONABLE controls — buttons, links, menu items, input fields,
      tabs. Skip decoration.
    - For each control: label = visible text OR what an agent would call it;
      purpose = what it does; location = "top-right of toolbar" / "bottom-left
      of composer" etc; icon_hint = "paper plane" / "paperclip" / null.
    - Up to 12 observable_controls, prioritized by likely relevance.
    - cross_app_correlations: 0-3 sentences. Only include real correlations
      (e.g., "Slack message references the Figma file visible on the right").
      Don't invent.
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
        struct Ctrl: Decodable {
            let label: String
            let purpose: String?
            let location: String?
            let iconHint: String?
            enum CodingKeys: String, CodingKey {
                case label, purpose, location, iconHint = "icon_hint"
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
        }
    }
}
