//
//  ContextGeminiObservationService+Prompts.swift
//  Agent in the Notch
//

import Foundation

extension ContextGeminiObservationService {

    static func prompt(for input: ContextGeminiObservationInput) -> String {
        let metadataLines = metadataLines(for: input)
        return """
        You are building a reusable UI/UX memory layer for a macOS computer-use agent.
        Observe this screenshot like a careful operator learning how the visible app works.
        Extract durable, action-relevant facts that would reduce future exploration.

        Prioritize:
        - visible navigation structure, tabs, panels, sidebars, toolbar regions, overlays, tables, forms, lists, modals, search fields, and status chips
        - exact visible control labels and what using them likely does
        - page/surface state: selected tabs, filters, active records, empty/error/loading states, warnings, disabled controls
        - visible data objects/entities that may be referenced later
        - workflow hints: how a user would accomplish tasks from this surface
        - negative cues: things that look clickable but are probably status text, no-op areas, stale overlays, debug chrome, or unrelated background windows
        - memory candidates: durable facts a future computer-use agent should remember

        Use only visible evidence plus the metadata. Prefer uncertainty over guessing.
        Do not describe private content beyond short visible labels/entities needed for UI operation.
        If an AgentNotch context/debug overlay is visible, separate overlay facts from the underlying app facts.
        Reject generic observations. Do not say "there is a sidebar" unless you name what is in it and why it matters.
        Prefer action memory over visual description.

        Return strict JSON only with these fields:
        appLabel: string
        windowTitle: string
        surfaceID: short stable slug for this visible surface, based on visible app/product/screen, not transient window text
        surfaceLabel: short human label for the surface
        screenType: short category such as dashboard, document, chat, terminal, browser-page, settings, modal, table, form, editor, overlay
        primaryTask: what the user appears able to do here, one short sentence
        layoutSummary: concise map of important regions and what each region contains
        contentSummary: concise summary of visible page/content state, avoiding noisy OCR fragments
        summary: one dense sentence combining what this screen is and why it matters operationally
        visibleControls: array of { "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }
        landmarks: array of short strings
        entities: array of short strings
        affordances: array of short strings
        stateIndicators: array of short strings
        navigationPaths: array of short strings, e.g. "left sidebar > Settings opens preferences"
        dataRegions: array of short strings, e.g. "center table lists deployments with status chips"
        workflowHints: array of short strings, e.g. "Use Filters to narrow failed deployments"
        negativeCues: array of short strings, e.g. "debug overlay partially obscures page"
        memoryCandidates: array of short durable facts formatted like "stable: Settings is in the left sidebar" or "transient: debug overlay is covering the page"
        uncertainty: array of short strings
        confidence: number from 0 to 1

        Use approximate regions such as top-bar, top-right, left-sidebar, center-table, right-panel, bottom-sheet, modal, overlay, browser-chrome, terminal.
        Keep each string short but information-dense. Return up to 20 controls, 16 landmarks, 24 entities, and 12 items for each other array.
        Every workflowHint should name a visible control, region, or state. Every negativeCue should explain what mistaken action it prevents.
        Do not invent hidden controls. If metadata conflicts with the image, mention that in uncertainty.

        Metadata:
        \(metadataLines)
        """
    }

    static func lanePrompt(
        for lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        previousSnapshot: ContextSnapshot?
    ) -> String {
        let metadataLines = metadataLines(for: input)
        let previous = previousSnapshot.map(previousSnapshotLines) ?? "- No previous screen supplied."
        let base = """
        You are one lane in a modular screen-understanding pipeline for a macOS computer-use agent.
        Analyze the full-display screenshot, but separate the active/frontmost work surface from background windows and AgentNotch/dev overlays.
        Your job is to preprocess useful reasoning so the future computer-use model spends fewer tokens discovering what the user is doing or how the UI works.

        Rules:
        - Use only visible evidence plus metadata. Prefer uncertainty over guessing.
        - Be specific and operational. Do not write generic labels like "button" or "sidebar" without saying what it helps do.
        - Keep output compact. Short, dense strings are better than paragraphs.
        - Mention private content only as short visible labels/entities needed for operation.
        - Return strict JSON only.

        Metadata:
        \(metadataLines)

        Previous screen for interaction reasoning:
        \(previous)
        """

        switch lane {
        case .activity:
            return base + """

            Lane goal: understand what the user is actively doing, the current work state, and what the agent should know if asked to jump in.
            Focus on task, visible content, active app/page, current state, likely intent, and recent work context. Do not catalog every control.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, primaryTask, contentSummary,
            stateIndicators: [string],
            entities: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number
            """
        case .uiMap:
            return base + """

            Lane goal: learn how this UI can be operated so a future computer-use agent can act faster.
            Focus on visible regions, controls, navigation, workflows, successful next actions, and negative/no-op cues. Treat UI/UX memory as an accelerator, not a screenshot caption.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary,
            layoutRegions: [string],
            controls: [{ "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }],
            workflows: [string],
            navigation: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number

            Every workflow must name the visible control or region it would use and the expected result.
            Every negative cue must explain what wasted action it prevents.
            """
        case .entityContent:
            return base + """

            Lane goal: harvest useful content and entities from the screen.
            Focus on files, docs, URLs, people, tickets, records, errors, messages, terminal output, selected/current items, and app-specific objects. Capture what the user is working with, not just what app is open.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, contentSummary,
            layoutRegions: [string],
            entities: [string],
            stateIndicators: [string],
            memoryCards: [string],
            negativeCues: [string],
            uncertainty: [string],
            confidence: number
            """
        case .interaction:
            return base + """

            Lane goal: compare previous and current screen hints to infer what changed after the last click/app switch/manual capture.
            Focus on action effect, transition, changed state, likely clicked target, success/failure signal, and whether the action taught a reusable navigation/workflow fact.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary,
            primaryTask,
            workflows: [string],
            navigation: [string],
            stateIndicators: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number
            """
        case .reducer:
            return base + """

            Lane goal: merge previously extracted lane outputs. If you receive a screenshot here, still keep output compact and activation-ready.
            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, primaryTask, contentSummary,
            layoutRegions: [string],
            controls: [{ "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }],
            entities: [string],
            stateIndicators: [string],
            workflows: [string],
            navigation: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number
            """
        }
    }

    static func metadataLines(for input: ContextGeminiObservationInput) -> String {
        var lines: [String] = []
        if let appName = clean(input.appName) {
            lines.append("- App hint: \(appName)")
        }
        if let windowTitle = clean(input.windowTitle) {
            lines.append("- Window hint: \(windowTitle)")
        }
        if let width = input.width, let height = input.height {
            lines.append("- Screenshot size: \(width)x\(height)")
        }
        let ocrItems = regionOCRLines(from: input.recognizedText)
        if !ocrItems.isEmpty {
            lines.append("- OCR by screen region:")
            lines.append(contentsOf: ocrItems)
            lines.append("- Raw OCR item count: \(input.recognizedText.count)")
        }
        for key in input.metadata.keys.sorted() {
            guard let value = clean(input.metadata[key]) else { continue }
            lines.append("- \(key): \(value)")
        }
        return lines.isEmpty ? "- No metadata provided." : lines.joined(separator: "\n")
    }

    static func previousSnapshotLines(_ snapshot: ContextSnapshot) -> String {
        let text = ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: 10)
        var lines = [
            "- Previous app: \(snapshot.appName)",
            "- Previous window: \(snapshot.windowTitle)",
            "- Previous trigger: \(snapshot.trigger.rawValue)"
        ]
        if !text.isEmpty {
            lines.append("- Previous useful OCR: \(text.joined(separator: " | "))")
        }
        if let cursorLocation = snapshot.cursorLocation {
            lines.append("- Previous cursor: x=\(Int(cursorLocation.x)), y=\(Int(cursorLocation.y))")
        }
        return lines.joined(separator: "\n")
    }

    static func regionOCRLines(from recognizedText: [ContextRecognizedText]) -> [String] {
        guard !recognizedText.isEmpty else { return [] }
        let useful = recognizedText
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if abs(lhs.y - rhs.y) > 0.03 {
                    return lhs.y > rhs.y
                }
                return lhs.x < rhs.x
            }

        var buckets: [String: [String]] = [
            "top": [],
            "left": [],
            "center": [],
            "right": [],
            "bottom": []
        ]

        for item in useful {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bucket: String
            if item.y > 0.82 {
                bucket = "top"
            } else if item.y < 0.18 {
                bucket = "bottom"
            } else if item.x < 0.24 {
                bucket = "left"
            } else if item.x > 0.76 {
                bucket = "right"
            } else {
                bucket = "center"
            }
            if buckets[bucket, default: []].count < 12 {
                buckets[bucket, default: []].append(text)
            }
        }

        return ["top", "left", "center", "right", "bottom"].compactMap { key in
            let values = ContextTextSignalFilter.usefulText(
                from: buckets[key, default: []].map {
                    ContextRecognizedText(text: $0, confidence: 1, x: 0, y: 0, width: 0, height: 0)
                },
                maxCount: 10
            )
            guard !values.isEmpty else { return nil }
            return "  - \(key): \(values.joined(separator: " | "))"
        }
    }
}
