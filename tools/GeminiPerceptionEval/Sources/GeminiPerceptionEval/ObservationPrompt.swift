import Foundation

/// The Gemini perception prompt — copied verbatim from
/// `Features/Context/GeminiObserver.swift`'s `prompt(frontmostHint:)` function
/// so the eval CLI exercises the same instruction the live observer would send.
///
/// Keep this in sync with the observer. The eval is meaningless if the prompt drifts.
public enum ObservationPrompt {

    /// Build the full prompt string for a given frontmost-app hint.
    /// Verbatim copy of `GeminiObserver.prompt(frontmostHint:)`.
    public static func prompt(frontmostHint: String?) -> String {
        let hint = frontmostHint.map { "\nCurrently frontmost app: \($0)" } ?? ""
        return """
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
        - Strict JSON. No backticks. No prose outside the JSON.\(hint)
        """
    }
}
