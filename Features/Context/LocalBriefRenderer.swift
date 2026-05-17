import Foundation

/// Deterministic offline brief renderer. Used when MercuryClient fails (no key,
/// timeout, malformed response). Produces a usable `{intent, brief}` from purely
/// local L2 + L3 + L5 data so the agent always gets *something*.
public enum LocalBriefRenderer {

    public static func render(
        transcript: String,
        l2: CL2Snapshot,
        activeTask: CActiveTask?,
        recipesForActiveApp: [CRecipe],
        recentResources: [CResourceRef]
    ) -> (intent: CIntent, brief: String) {
        let intent = inferIntent(transcript: transcript, activeTask: activeTask, recentResources: recentResources)
        let brief = composeBrief(
            transcript: transcript,
            intent: intent,
            l2: l2,
            activeTask: activeTask,
            recipes: recipesForActiveApp,
            recentResources: recentResources
        )
        return (intent, brief)
    }

    // MARK: - Intent inference (deterministic, no LLM)

    private static let actionVerbs = ["open", "send", "run", "close", "save", "find", "search", "show", "post", "share", "switch", "make", "create", "delete", "copy", "paste"]

    private static func inferIntent(transcript: String, activeTask: CActiveTask?, recentResources: [CResourceRef]) -> CIntent {
        let lower = transcript.lowercased()
        let verb = actionVerbs.first(where: { lower.contains($0) }) ?? "do"
        let trimmed = lower
            .replacingOccurrences(of: verb, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty ? nil : trimmed
        let resolved: String? = recentResources.first(where: { ref in
            if let label = ref.label?.lowercased(), trimmed.contains(label) { return true }
            return ref.uri.lowercased().contains(trimmed)
        })?.uri
        let entities: [CIntent.Entity] = activeTask?.entities
            .filter { lower.contains($0.label.lowercased()) } ?? []
        return CIntent(
            verb: verb,
            target: target,
            resolvedTarget: resolved,
            entities: entities,
            confidence: 0.4   // heuristic, not synthesis
        )
    }

    // MARK: - Brief composition

    private static func composeBrief(
        transcript: String,
        intent: CIntent,
        l2: CL2Snapshot,
        activeTask: CActiveTask?,
        recipes: [CRecipe],
        recentResources: [CResourceRef]
    ) -> String {
        var lines: [String] = []
        lines.append("> **Local fallback brief** (Mercury unavailable; this is a deterministic Swift render)")
        lines.append("")
        lines.append("## What the user wants")
        lines.append("Transcript: \"\(transcript)\". Inferred verb=\(intent.verb)\(intent.target.map { ", target=\($0)" } ?? "").")
        if let resolved = intent.resolvedTarget {
            lines.append("Resolved target: \(resolved)")
        }
        lines.append("")

        lines.append("## You are here")
        lines.append("- App: \(l2.app) — \(l2.windowTitle ?? "(no window title)")")
        let useful = l2.axElements.filter { ($0.label?.isEmpty == false) }.prefix(5)
        if !useful.isEmpty {
            lines.append("- Useful AX elements:")
            for el in useful {
                lines.append("  - \(el.role)[\(el.label ?? "?")]\(el.focused ? " (focused)" : "")")
            }
        }
        if let sel = l2.selection, !sel.isEmpty {
            lines.append("- Active selection: \(sel.prefix(120))")
        }
        if let cb = l2.clipboard, let preview = cb.preview, !preview.isEmpty {
            lines.append("- Recent clipboard (\(Int(cb.ageS))s old): \(preview.prefix(120))")
        }
        lines.append("")

        if !recipes.isEmpty {
            lines.append("## How to do it on \(l2.app)")
            let top = recipes.sorted { $0.seenCount > $1.seenCount }.prefix(3)
            for (i, recipe) in top.enumerated() {
                let stepsSummary = recipe.steps.map(stepSummary).joined(separator: " → ")
                lines.append("\(i+1). **\(recipe.name)** (seen \(recipe.seenCount)×): \(stepsSummary)")
            }
            lines.append("")
        }

        let entities = intent.entities
        if !entities.isEmpty {
            for ent in entities {
                lines.append("## What \"\(ent.label)\" means")
                lines.append("\(ent.kind)\(ent.resolvedTo.map { " — \($0)" } ?? "")")
                lines.append("")
            }
        }

        if let task = activeTask, !task.narrative.isEmpty {
            lines.append("## Recent context")
            lines.append(String(task.narrative.prefix(400)))
            lines.append("")
        }

        if !recentResources.isEmpty {
            lines.append("## Resources to consider")
            for ref in recentResources.prefix(5) {
                let label = ref.label ?? ref.uri
                lines.append("- \(label) — \(ref.uri)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func stepSummary(_ step: CRecipe.Step) -> String {
        switch step {
        case .shortcut(let keys):     return "`\(keys)`"
        case .type(let v):            return "type `\(v)`"
        case .key(let keys):          return "`\(keys)`"
        case .menu(let path):         return path.joined(separator: " → ")
        case .url(let v):             return "open `\(v)`"
        case .shellCmd(let v, _):     return "run `\(v)`"
        case .openFile(let v, _):     return "open `\(v)`"
        case .appleScript:            return "applescript"
        }
    }
}
