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
                let leftScore = activationScore(lhs)
                let rightScore = activationScore(rhs)
                if leftScore == rightScore {
                    return lhs.lastSeen > rhs.lastSeen
                }
                return leftScore > rightScore
            }
            .prefix(3)
            .map { surface in
                var parts = ["- \(surface.title)"]
                let facts = surface.facts
                    .filter { activationFactCategories.contains($0.category) && $0.durability != "transient" }
                    .prefix(5)
                    .compactMap { factText($0, includeCategory: true) }
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
                let entities = cleanValues(surface.entities.map(\.text)).prefix(6).joined(separator: " | ")
                if !entities.isEmpty {
                    parts.append("Entities: \(entities).")
                }
                let text = cleanValues(surface.textHighlights).prefix(4).joined(separator: " | ")
                if surface.facts.isEmpty, !text.isEmpty {
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
                        .compactMap { factText($0, includeCategory: false) }
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

        return """
        App: \(memory.appName)
        Agent-useful UI memory:
        \(surfaces.isEmpty ? "- No durable surfaces yet." : surfaces.joined(separator: "\n"))
        Known transitions:
        \(transitions.isEmpty ? "- No learned transitions yet." : transitions.joined(separator: "\n"))
        """
    }

    static func markdown(for memory: ContextAppMemory) -> String {
        let surfaces = memory.surfaces
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { surface in
                let stableFacts = surface.facts.filter { $0.durability != "transient" }
                let transientFacts = surface.facts.filter { $0.durability == "transient" }
                let recipes = recipeLines(from: surface)
                var lines = [
                    "- **\(surface.title)**: last seen \(iso(surface.lastSeen))."
                ]
                lines.append("  - Debug capture stats: \(surface.observationCount) captures, \(surface.clickCount) clicks, \(surface.activationCount) activations.")
                if !stableFacts.isEmpty {
                    let values = stableFacts.prefix(12).compactMap { factText($0, includeCategory: true) }
                    if !values.isEmpty {
                        lines.append("  - Durable facts: \(values.joined(separator: " | "))")
                    }
                }
                if !surface.controls.isEmpty {
                    lines.append("  - Controls: \(surface.controls.prefix(12).map { controlText($0, includeEvidence: true) }.joined(separator: " | "))")
                }
                if !recipes.isEmpty {
                    lines.append("  - Task recipes / workflows: \(recipes.prefix(8).joined(separator: " | "))")
                }
                if !surface.entities.isEmpty {
                    let values = cleanValues(surface.entities.map(\.text)).prefix(12).joined(separator: " | ")
                    if !values.isEmpty {
                        lines.append("  - Entities: \(values)")
                    }
                }
                if !transientFacts.isEmpty {
                    let values = transientFacts.prefix(8).compactMap { factText($0, includeCategory: true) }
                    if !values.isEmpty {
                        lines.append("  - Recent/transient state: \(values.joined(separator: " | "))")
                    }
                }
                if !surface.textHighlights.isEmpty {
                    let values = cleanValues(surface.textHighlights).prefix(8).joined(separator: " | ")
                    if !values.isEmpty {
                        lines.append("  - OCR fallback highlights: \(values)")
                    }
                }
                if !surface.semanticHighlights.isEmpty {
                    let values = cleanValues(surface.semanticHighlights).prefix(3).joined(separator: " | ")
                    if !values.isEmpty {
                        lines.append("  - Learned summaries: \(values)")
                    }
                }
                if !surface.uncertaintyHighlights.isEmpty {
                    let values = cleanValues(surface.uncertaintyHighlights).prefix(6).joined(separator: " | ")
                    if !values.isEmpty {
                        lines.append("  - Uncertain: \(values)")
                    }
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
                "- **\(note.surfaceTitle)**: \(note.note) Capped evidence \(note.evidenceCount)x, last seen \(iso(note.lastSeen))."
            }
            .joined(separator: "\n")

        let recipes = memory.surfaces
            .flatMap(recipeLines(from:))
            .reduce(into: [String]()) { output, value in
                guard !output.contains(value) else { return }
                output.append(value)
            }
            .prefix(12)
            .map { "- \($0)" }
            .joined(separator: "\n")

        return """
        # \(memory.appName) UI Memory

        Last updated: \(iso(memory.lastSeen))
        First seen: \(iso(memory.firstSeen))

        ## App Profile

        Learned from screenshot captures. Durable UI operation facts are separated from recent content/state. Treat this as soft memory, not exact click coordinates.

        ## Surfaces Seen

        \(surfaces.isEmpty ? "- None yet." : surfaces)

        ## Transitions

        \(transitions.isEmpty ? "- None yet." : transitions)

        ## Task Recipes

        \(recipes.isEmpty ? "- No reusable workflows learned yet." : recipes)

        ## Cautions And Weak Negative Memory

        \(negative.isEmpty ? "- None yet." : negative)

        ## Stale Or Uncertain Notes

        - Surface identity combines local app/window snapshots with Gemini surface IDs. Raw OCR-only surfaces can still be noisy until a semantic observation merges or replaces them.
        """
    }

    private static let activationFactCategories: Set<String> = [
        "layout",
        "data-region",
        "navigation",
        "workflow",
        "affordance",
        "memory"
    ]

    private static func activationScore(_ surface: ContextSurfaceMemory) -> Int {
        let durableFacts = surface.facts.filter { $0.durability != "transient" }.count
        return durableFacts * 4
            + surface.controls.count * 3
            + surface.entities.count
            + surface.affordanceHighlights.count * 2
            + surface.transitionsProxyScore
    }

    private static func controlText(_ control: ContextControlMemory, includeEvidence: Bool = false) -> String {
        let label = ContextTextSignalFilter.redacted(control.label)
        let role = ContextTextSignalFilter.redacted(control.role)
        let region = ContextTextSignalFilter.redacted(control.region)
        let actionHint = ContextTextSignalFilter.memoryText(control.actionHint) ?? ""
        let hint = actionHint.isEmpty ? "" : ": \(actionHint)"
        let evidence = includeEvidence ? ", evidence \(control.evidenceCount)x" : ""
        return "\(label) (\(role), \(region)\(evidence))\(hint)"
    }

    private static func factText(_ fact: ContextMemoryFact, includeCategory: Bool) -> String? {
        guard let text = ContextTextSignalFilter.memoryText(fact.text) else { return nil }
        return includeCategory ? "[\(fact.category)] \(text)" : text
    }

    private static func recipeLines(from surface: ContextSurfaceMemory) -> [String] {
        let factRecipes = surface.facts
            .filter { $0.category == "workflow" || $0.category == "navigation" || $0.category == "affordance" }
            .map(\.text)
        return unique(factRecipes + surface.affordanceHighlights)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let cleaned = ContextTextSignalFilter.memoryText(value) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
        }
        return output
    }

    private static func cleanValues(_ values: [String]) -> [String] {
        unique(values)
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

private extension ContextSurfaceMemory {
    var transitionsProxyScore: Int {
        clickCount > 0 ? 1 : 0
    }
}
