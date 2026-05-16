//
//  ContextMemoryRenderer.swift
//  Agent in the Notch
//
//  Renders learned UI memory into human-readable files and compact agent
//  prompt snippets.
//

import Foundation

enum ContextMemoryRenderer {
    static func activationSnippet(for memory: ContextAppMemory) -> String {
        let surfaces = memory.surfaces
            .sorted { lhs, rhs in
                if lhs.lastSeen == rhs.lastSeen {
                    return lhs.observationCount > rhs.observationCount
                }
                return lhs.lastSeen > rhs.lastSeen
            }
            .prefix(5)
            .map { surface in
                var parts = ["- \(surface.title)"]
                let facts = surface.facts
                    .filter { $0.durability != "transient" }
                    .prefix(4)
                    .map { "\($0.category): \($0.text)" }
                    .joined(separator: " | ")
                if !facts.isEmpty {
                    parts.append("Facts: \(facts).")
                }
                let controls = surface.controls.prefix(6).map { control in
                    let hint = control.actionHint.isEmpty ? "" : " -> \(control.actionHint)"
                    return "\(control.label) (\(control.role), \(control.region))\(hint)"
                }.joined(separator: " | ")
                if !controls.isEmpty {
                    parts.append("Controls: \(controls).")
                }
                let entities = surface.entities.prefix(6).map(\.text).joined(separator: " | ")
                if !entities.isEmpty {
                    parts.append("Entities: \(entities).")
                }
                let text = surface.textHighlights.prefix(6).joined(separator: " | ")
                if !text.isEmpty {
                    parts.append("Visible text: \(text).")
                }
                let semantic = surface.facts.isEmpty
                    ? surface.semanticHighlights.prefix(2).joined(separator: " ")
                    : ""
                if !semantic.isEmpty {
                    parts.append("Learned UI: \(semantic)")
                }
                let affordances = surface.controls.isEmpty
                    ? surface.affordanceHighlights.prefix(3).joined(separator: " | ")
                    : surface.facts
                        .filter { $0.category == "workflow" || $0.category == "navigation" || $0.category == "affordance" }
                        .prefix(3)
                        .map(\.text)
                        .joined(separator: " | ")
                if !affordances.isEmpty {
                    parts.append("Affordances: \(affordances).")
                }
                let rest = parts.dropFirst().joined(separator: " ")
                return rest.isEmpty ? parts[0] : "\(parts[0]): \(rest)"
            }

        let transitions = memory.transitions
            .sorted { lhs, rhs in
                if lhs.evidenceCount == rhs.evidenceCount {
                    return lhs.lastSeen > rhs.lastSeen
                }
                return lhs.evidenceCount > rhs.evidenceCount
            }
            .prefix(4)
            .map { transition in
                "- \(transition.fromTitle) -> \(transition.toTitle) after \(transition.trigger.rawValue)."
            }

        let negative = memory.negativeNotes
            .sorted { lhs, rhs in
                if lhs.evidenceCount == rhs.evidenceCount {
                    return lhs.lastSeen > rhs.lastSeen
                }
                return lhs.evidenceCount > rhs.evidenceCount
            }
            .prefix(3)
            .map { note in
                "- \(note.surfaceTitle): \(note.note)"
            }

        return """
        App: \(memory.appName)
        Known surfaces:
        \(surfaces.isEmpty ? "- No durable surfaces yet." : surfaces.joined(separator: "\n"))
        Known transitions:
        \(transitions.isEmpty ? "- No learned transitions yet." : transitions.joined(separator: "\n"))
        Cautions:
        \(negative.isEmpty ? "- No same-surface click cautions yet." : negative.joined(separator: "\n"))
        """
    }

    static func markdown(for memory: ContextAppMemory) -> String {
        let surfaces = memory.surfaces
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { surface in
                var lines = [
                    "- **\(surface.title)**: seen \(surface.observationCount)x, clicks \(surface.clickCount)x, activations \(surface.activationCount)x, last seen \(iso(surface.lastSeen))."
                ]
                if !surface.textHighlights.isEmpty {
                    lines.append("  - Text highlights: \(surface.textHighlights.prefix(12).joined(separator: " | "))")
                }
                if !surface.semanticHighlights.isEmpty {
                    lines.append("  - Learned UI summaries: \(surface.semanticHighlights.prefix(4).joined(separator: " | "))")
                }
                if !surface.facts.isEmpty {
                    lines.append("  - Structured facts: \(surface.facts.prefix(12).map { "[\($0.category)/\($0.durability)] \($0.text)" }.joined(separator: " | "))")
                }
                if !surface.controls.isEmpty {
                    lines.append("  - Structured controls: \(surface.controls.prefix(12).map { "\($0.label) (\($0.role), \($0.region), evidence \($0.evidenceCount)x)" }.joined(separator: " | "))")
                }
                if !surface.entities.isEmpty {
                    lines.append("  - Structured entities: \(surface.entities.prefix(12).map(\.text).joined(separator: " | "))")
                }
                if !surface.controlHighlights.isEmpty {
                    lines.append("  - Controls: \(surface.controlHighlights.prefix(10).joined(separator: " | "))")
                }
                if !surface.affordanceHighlights.isEmpty {
                    lines.append("  - Affordances: \(surface.affordanceHighlights.prefix(8).joined(separator: " | "))")
                }
                if !surface.uncertaintyHighlights.isEmpty {
                    lines.append("  - Uncertain: \(surface.uncertaintyHighlights.prefix(6).joined(separator: " | "))")
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")

        let transitions = memory.transitions
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { transition in
                "- **\(transition.fromTitle)** -> **\(transition.toTitle)** after \(transition.trigger.rawValue), evidence \(transition.evidenceCount)x, last seen \(iso(transition.lastSeen))."
            }
            .joined(separator: "\n")

        let negative = memory.negativeNotes
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { note in
                "- **\(note.surfaceTitle)**: \(note.note) Evidence \(note.evidenceCount)x, last seen \(iso(note.lastSeen))."
            }
            .joined(separator: "\n")

        return """
        # \(memory.appName) UI Memory

        Last updated: \(iso(memory.lastSeen))
        First seen: \(iso(memory.firstSeen))

        ## App Profile

        Learned from native screen captures. Treat this as soft UI memory, not a source of exact click coordinates.

        ## Surfaces Seen

        \(surfaces.isEmpty ? "- None yet." : surfaces)

        ## Transitions

        \(transitions.isEmpty ? "- None yet." : transitions)

        ## Task Recipes

        - Pending: VLM summaries should promote repeated successful transition chains into task recipes.

        ## Negative Memory

        \(negative.isEmpty ? "- None yet." : negative)

        ## Stale Or Uncertain Notes

        - Surface identity is currently based on app name and window title. Screenshot/VLM recognition should refine this for native apps, browser apps, documents, editors, settings screens, and layout drift.
        """
    }

    private static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m ago"
        }
        return "\(seconds / 3600)h ago"
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
