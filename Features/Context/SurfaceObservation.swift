import Foundation

/// A single Gemini-produced understanding of what's on screen at one moment.
/// Output of one GeminiObserver.observe(...) call.
public struct SurfaceObservation: Codable, Identifiable {
    public let id: UUID
    public let t: Date
    public let frontmostApp: String?
    public let allVisibleApps: [String]
    public let screenLayout: String?            // multi-app spatial description
    public let currentSurface: String?          // e.g. "Slack #design channel composer"
    public let observableControls: [Control]
    public let crossAppCorrelations: [String]
    public let userVisibleState: String?
    public let modelLatencyS: Double

    public struct Control: Codable {
        public let label: String
        public let purpose: String?         // "send the typed message"
        public let location: String?        // "bottom-right of composer"
        public let iconHint: String?        // "paper plane" — useful when label is empty
    }

    public init(
        id: UUID = UUID(),
        t: Date = Date(),
        frontmostApp: String?,
        allVisibleApps: [String],
        screenLayout: String?,
        currentSurface: String?,
        observableControls: [Control],
        crossAppCorrelations: [String],
        userVisibleState: String?,
        modelLatencyS: Double
    ) {
        self.id = id; self.t = t
        self.frontmostApp = frontmostApp
        self.allVisibleApps = allVisibleApps
        self.screenLayout = screenLayout
        self.currentSurface = currentSurface
        self.observableControls = observableControls
        self.crossAppCorrelations = crossAppCorrelations
        self.userVisibleState = userVisibleState
        self.modelLatencyS = modelLatencyS
    }

    enum CodingKeys: String, CodingKey {
        case id, t
        case frontmostApp = "frontmost_app"
        case allVisibleApps = "all_visible_apps"
        case screenLayout = "screen_layout"
        case currentSurface = "current_surface"
        case observableControls = "observable_controls"
        case crossAppCorrelations = "cross_app_correlations"
        case userVisibleState = "user_visible_state"
        case modelLatencyS = "model_latency_s"
    }
}
