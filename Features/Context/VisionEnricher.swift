import Foundation

/// One-shot vision enrichment of the current screen via Gemini Flash Lite.
/// Runs in parallel with adapter calls during L2 capture. 1.5s hard deadline.
///
/// Output is text-only (Mercury 2 is text-only) — Gemini's role here is purely
/// "vision → text" pre-processing so Mercury's brief is grounded in BOTH the
/// AX dump and what a vision model actually sees. Fills the gaps AX/OCR miss:
/// icons without labels, Electron/Tauri/canvas UI, custom-rendered controls,
/// and the visual hierarchy (sidebar vs main content vs toolbar).
public enum VisionEnricher {

    public struct Result: Codable {
        /// One-sentence description of what's visible.
        public let screen: String?
        /// What surface within the app the user is on (e.g. "Slack DM composer", "Figma onboarding-v3 / Step 2").
        public let currentSurface: String?
        /// List of clickable-looking elements with semantic purposes.
        public let clickableElements: [ClickableElement]?
        /// What looks selected/focused, regardless of AX focus.
        public let selectedOrFocused: String?
        /// Anything else worth knowing (modal dialog visible, error state, loading spinner, etc).
        public let notableState: String?

        public struct ClickableElement: Codable {
            public let label: String
            public let purpose: String?           // "send the typed message"
            public let location: String?          // "bottom-right of composer"
        }

        public init(
            screen: String? = nil,
            currentSurface: String? = nil,
            clickableElements: [ClickableElement]? = nil,
            selectedOrFocused: String? = nil,
            notableState: String? = nil
        ) {
            self.screen = screen
            self.currentSurface = currentSurface
            self.clickableElements = clickableElements
            self.selectedOrFocused = selectedOrFocused
            self.notableState = notableState
        }

        enum CodingKeys: String, CodingKey {
            case screen
            case currentSurface = "current_surface"
            case clickableElements = "clickable_elements"
            case selectedOrFocused = "selected_or_focused"
            case notableState = "notable_state"
        }
    }

    /// Attempt to enrich the screen. Returns nil on any failure — caller should
    /// treat absence as graceful degradation, not an error.
    public static func enrich(screenshotJPEG: Data, transcriptHint: String? = nil) async -> Result? {
        let hint = transcriptHint.map { "\nThe user just said: \"\($0)\"" } ?? ""
        let prompt = """
        Analyze this screenshot of a macOS application. Return strictly one JSON object
        matching this schema:

        {
          "screen":              "one-sentence description of what's visible (focal point first)",
          "current_surface":     "what surface within the app the user is on",
          "clickable_elements":  [{"label": string, "purpose": string, "location": string}],
          "selected_or_focused": "what looks selected or focused, even if no native focus indicator",
          "notable_state":       "anything else worth knowing (modal dialogs, error states, loading spinners)"
        }

        Rules:
        - Focus on what's ACTIONABLE — buttons, links, menu items, input fields.
        - Don't describe decoration (backgrounds, fixed images).
        - Be specific: "Send button at bottom-right of message composer" not "a button is visible".
        - Up to 10 clickable_elements, prioritized by likely user relevance.
        - Strict JSON. No prose outside the JSON object. No backticks, no markdown wrappers.\(hint)
        """

        do {
            let raw = try await GeminiVisionClient.shared.generate(
                prompt: prompt,
                imageJPEG: screenshotJPEG,
                timeout: 1.5
            )
            guard let data = raw.data(using: .utf8) else { return nil }
            let decoder = JSONDecoder()
            return try? decoder.decode(Result.self, from: data)
        } catch {
            return nil
        }
    }
}
