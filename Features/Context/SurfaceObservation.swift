import Foundation

/// A single Gemini-produced understanding of what's on screen at one moment.
/// Output of one GeminiObserver.observe(...) call.
///
/// Carries two layers of information:
///  - SCREEN layer (frontmostApp, surface, controls, layout) — used by
///    `SurfaceMemoryStore` to build durable per-(app, surface) UI knowledge.
///  - USER layer (narrative, currentGoalGuess, continuityLink, contentType,
///    artifact) — used by `CaptureStoryLog` to build a chronological story of
///    what the user has been doing, which Mercury reads at long-press time
///    so briefs can carry real continuity instead of one-frame guesses.
public struct SurfaceObservation: Codable, Identifiable {
    public let id: UUID
    public let t: Date
    public let frontmostApp: String?
    /// Bundle ID of the frontmost app at capture time. System-injected by the
    /// observer caller, not produced by Gemini — the model has no way to know
    /// it from pixels. The canonical key for `SurfaceMemoryStore`; `frontmostApp`
    /// (localized display name) varies across language and version and is kept
    /// only for display.
    public let bundleID: String?
    public let allVisibleApps: [String]
    public let screenLayout: String?            // multi-app spatial description
    public let currentSurface: String?          // e.g. "Slack #design channel composer"
    public let observableControls: [Control]
    public let crossAppCorrelations: [String]
    public let userVisibleState: String?
    public let modelLatencyS: Double

    // MARK: - Capture Story layer (S17)
    //
    // These describe what the USER is doing, not just what's on the screen.
    // Optional because older entries in the on-disk JSONL won't have them, and
    // because Gemini may legitimately decline to fill any field rather than
    // invent (per prompt rule).

    /// 1-2 sentences about what the user is doing right now.
    public let narrative: String?
    /// One short phrase guessing the user's current goal.
    public let currentGoalGuess: String?
    /// One sentence linking to recent activity; nil if not inferable.
    public let continuityLink: String?
    /// Primary content type — the frontmost app's content. One of: document |
    /// form | chat | code | settings | browser_article | email | media | other.
    /// String-typed to stay tolerant of future values. A quick filter; the full
    /// per-app set lives in `artifacts`.
    public let contentType: String?
    /// Structured content extracted from each visible app that has useful
    /// content (not just the frontmost). When a user has Slack + Brave +
    /// Figma all visible, you get up to three entries — one per app — each
    /// tagged with its own `app` and `content_type`. Lets the Selector
    /// resolve deictic references like "the doc" against whichever visible
    /// app actually contains a document.
    public let artifacts: [Artifact]?

    public struct Control: Codable {
        public let label: String
        public let purpose: String?         // "send the typed message"
        public let location: String?        // "bottom-right of composer"
        public let iconHint: String?        // "paper plane" — useful when label is empty
    }

    /// One structured-content extraction tagged to a specific visible app.
    /// `payload` is heterogeneous because the per-content-type schemas vary
    /// (a document has body_excerpt + headings; a chat has messages[]; code
    /// has file_path, selection, focused_function, etc.) — see GeminiObserver's
    /// system prompt for the per-type schema.
    public struct Artifact: Codable {
        public let app: String
        public let contentType: String
        public let payload: [String: AnyCodable]
        enum CodingKeys: String, CodingKey {
            case app
            case contentType = "content_type"
            case payload
        }
    }

    public init(
        id: UUID = UUID(),
        t: Date = Date(),
        frontmostApp: String?,
        bundleID: String? = nil,
        allVisibleApps: [String],
        screenLayout: String?,
        currentSurface: String?,
        observableControls: [Control],
        crossAppCorrelations: [String],
        userVisibleState: String?,
        modelLatencyS: Double,
        narrative: String? = nil,
        currentGoalGuess: String? = nil,
        continuityLink: String? = nil,
        contentType: String? = nil,
        artifacts: [Artifact]? = nil
    ) {
        self.id = id; self.t = t
        self.frontmostApp = frontmostApp
        self.bundleID = bundleID
        self.allVisibleApps = allVisibleApps
        self.screenLayout = screenLayout
        self.currentSurface = currentSurface
        self.observableControls = observableControls
        self.crossAppCorrelations = crossAppCorrelations
        self.userVisibleState = userVisibleState
        self.modelLatencyS = modelLatencyS
        self.narrative = narrative
        self.currentGoalGuess = currentGoalGuess
        self.continuityLink = continuityLink
        self.contentType = contentType
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case id, t
        case frontmostApp = "frontmost_app"
        case bundleID = "bundle_id"
        case allVisibleApps = "all_visible_apps"
        case screenLayout = "screen_layout"
        case currentSurface = "current_surface"
        case observableControls = "observable_controls"
        case crossAppCorrelations = "cross_app_correlations"
        case userVisibleState = "user_visible_state"
        case modelLatencyS = "model_latency_s"
        case narrative
        case currentGoalGuess = "current_goal_guess"
        case continuityLink = "continuity_link"
        case contentType = "content_type"
        case artifacts
    }
}
