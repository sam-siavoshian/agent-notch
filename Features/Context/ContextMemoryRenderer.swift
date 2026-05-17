//
//  ContextMemoryRenderer.swift
//  Agent in the Notch
//
//  Renders learned UI memory into human-readable files and compact agent
//  prompt snippets. Emits clean markdown sections per memory layer; no pipe
//  joins, no `[category/durability]` prefixes.
//

import Foundation

enum ContextMemoryRenderer {
    static func activationSnippet(for memory: ContextAppMemory) -> String {
        var sections: [String] = []

        if let currentTask = currentTaskLine(memory) {
            sections.append("""
            ## Current Task
            \(currentTask)
            """)
        }

        let primary = primarySurface(memory)
        if let surface = primary {
            sections.append(currentSurfaceSection(surface, appName: memory.appName))
        }

        let affordanceBullets = affordanceVerbBullets(memory)
        if !affordanceBullets.isEmpty {
            sections.append("""
            ## Affordances Here
            \(affordanceBullets.joined(separator: "\n"))
            """)
        }

        if let surface = primary {
            let likelyBullets = likelyActionBullets(for: surface, memory: memory)
            if !likelyBullets.isEmpty {
                sections.append("""
                ## Likely Next Actions
                \(likelyBullets.joined(separator: "\n"))
                """)
            }
        }

        let recipeBullets = recipeBullets(for: primary, memory: memory)
        if !recipeBullets.isEmpty {
            sections.append("""
            ## Task Recipes
            \(recipeBullets.joined(separator: "\n"))
            """)
        }

        let recentBullets = recentActivityBullets(memory)
        if !recentBullets.isEmpty {
            sections.append("""
            ## Recent Activity
            \(recentBullets.joined(separator: "\n"))
            """)
        }

        let entityBullets = entityBullets(memory)
        if !entityBullets.isEmpty {
            sections.append("""
            ## Entities In Play
            \(entityBullets.joined(separator: "\n"))
            """)
        }

        let navHints = navigationHints(memory)
        if !navHints.isEmpty {
            sections.append("""
            ## Navigation Hints
            \(navHints.joined(separator: "\n"))
            """)
        }

        let habitsLine = habitsLine(memory)
        if !habitsLine.isEmpty {
            sections.append("""
            ## Habits
            \(habitsLine)
            """)
        }

        if sections.isEmpty {
            return "## Current Task\n- No durable UI memory for \(memory.appName) yet."
        }
        return sections.joined(separator: "\n\n")
    }

    static func tailoredActivationSnippet(
        for memory: ContextAppMemory?,
        hint: ActivationContextHint?,
        otherApps: [ContextAppMemory] = []
    ) -> String {
        var sections: [String] = []

        if let hint, let goal = hint.inferredGoal, !goal.isEmpty {
            var goalBlock = "## Resolved Goal\n- \(goal)"
            if let verb = hint.verb, !verb.isEmpty {
                goalBlock += "\n- Verb: **\(verb)**"
            }
            if let target = hint.target, !target.isEmpty {
                goalBlock += "\n- Target as phrased: \"\(target)\""
            }
            if hint.confidence > 0 {
                let pct = Int((hint.confidence * 100).rounded())
                goalBlock += "\n- Intent confidence: \(pct)%"
            }
            sections.append(goalBlock)
        }

        guard let memory else {
            if sections.isEmpty {
                return "## Current Task\n- No durable UI memory captured yet."
            }
            return sections.joined(separator: "\n\n")
        }

        if let currentTask = currentTaskLine(memory) {
            sections.append("## Current Task\n\(currentTask)")
        }

        if let surface = primarySurface(memory) {
            sections.append(currentSurfaceSection(surface, appName: memory.appName))
        }

        let affordances = affordanceVerbBullets(memory)
        if !affordances.isEmpty {
            sections.append("## Affordances Here\n\(affordances.joined(separator: "\n"))")
        }

        let rankedRecipes = rankRecipes(in: memory, hint: hint)
        if !rankedRecipes.isEmpty {
            sections.append("## Task Recipes\n\(rankedRecipes.joined(separator: "\n"))")
        }

        let entities = rankedEntities(in: memory, hint: hint)
        if !entities.isEmpty {
            sections.append("## Entities In Play\n\(entities.joined(separator: "\n"))")
        }

        if let surface = primarySurface(memory) {
            let likely = likelyActionBullets(for: surface, memory: memory)
            if !likely.isEmpty {
                sections.append("## Likely Next Actions\n\(likely.joined(separator: "\n"))")
            }
        }

        let recent = recentActivityBullets(memory).prefix(highConfidenceIntent(hint) ? 3 : 6)
        if !recent.isEmpty {
            sections.append("## Recent Activity\n\(Array(recent).joined(separator: "\n"))")
        }

        for other in otherApps where other.appName != memory.appName {
            let bullets = crossAppBullets(other)
            guard !bullets.isEmpty else { continue }
            sections.append("## Cross-App Memory — \(other.appName)\n\(bullets.joined(separator: "\n"))")
        }

        if !highConfidenceIntent(hint) {
            let navHints = navigationHints(memory)
            if !navHints.isEmpty {
                sections.append("## Navigation Hints\n\(navHints.joined(separator: "\n"))")
            }
            let habits = habitsLine(memory)
            if !habits.isEmpty {
                sections.append("## Habits\n\(habits)")
            }
        }

        if sections.isEmpty {
            return "## Current Task\n- No durable UI memory for \(memory.appName) yet."
        }
        return sections.joined(separator: "\n\n")
    }

    private static func highConfidenceIntent(_ hint: ActivationContextHint?) -> Bool {
        guard let hint else { return false }
        return hint.confidence >= 0.7 && !(hint.verb ?? "").isEmpty
    }

    private static func rankRecipes(in memory: ContextAppMemory, hint: ActivationContextHint?) -> [String] {
        guard !memory.recipes.isEmpty else { return [] }
        let keywords = hintKeywords(hint)
        let scored = memory.recipes.map { recipe -> (ContextTaskRecipe, Int) in
            let recipeWords = Set(recipe.intentKeywords.map { $0.lowercased() })
            let nameWords = Set(recipe.name.lowercased().split(separator: " ").map(String.init))
            let overlap = keywords.intersection(recipeWords).count + keywords.intersection(nameWords).count
            return (recipe, overlap)
        }
        let sorted = scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.confidence > $1.0.confidence
        }
        let limit = highConfidenceIntent(hint) ? 4 : 8
        return sorted.prefix(limit).map { (recipe, score) in
            let marker = score > 0 ? "🎯 " : ""
            let confidencePct = Int((recipe.confidence * 100).rounded())
            let steps = recipe.stepsProse.joined(separator: " Then ")
            return "- \(marker)**\(recipe.name)** (seen \(recipe.evidenceCount)x, \(confidencePct)%): \(steps)"
        }
    }

    private static func rankedEntities(in memory: ContextAppMemory, hint: ActivationContextHint?) -> [String] {
        guard !memory.entities.isEmpty else { return [] }
        let mentioned = Set((hint?.mentionedEntityLabels ?? []).map { $0.lowercased() })
        let scored = memory.entities.map { entity -> (ContextEntityMemory, Int) in
            let label = entity.label.isEmpty ? entity.text : entity.label
            let lower = label.lowercased()
            var score = 0
            if mentioned.contains(lower) { score += 100 }
            for token in mentioned where lower.contains(token) || token.contains(lower) {
                score += 50
            }
            score += min(entity.mentionCount, 20)
            return (entity, score)
        }
        let sorted = scored.sorted { $0.1 > $1.1 }
        let limit = highConfidenceIntent(hint) ? 6 : 10
        return sorted.prefix(limit).map { (entity, score) in
            let label = entity.label.isEmpty ? entity.text : entity.label
            let marker = score >= 100 ? "🎯 " : ""
            return "- \(marker)\(label) (\(entity.type), mentions \(entity.mentionCount)x)"
        }
    }

    private static func crossAppBullets(_ memory: ContextAppMemory) -> [String] {
        var bullets: [String] = []
        if let current = memory.current, !current.task.isEmpty {
            bullets.append("- Last context: \(current.task) on \(current.surfaceTitle)")
        }
        if let topSurface = primarySurface(memory) {
            bullets.append("- Most-used surface: \(topSurface.title)")
            let affordances = affordanceVerbBullets(memory).prefix(3)
            if !affordances.isEmpty {
                bullets.append("- Notable affordances: \(affordances.joined(separator: " · "))")
            }
        }
        let recentEntities = memory.entities
            .sorted { $0.mentionCount > $1.mentionCount }
            .prefix(3)
            .map { $0.label.isEmpty ? $0.text : $0.label }
        if !recentEntities.isEmpty {
            bullets.append("- Recent entities: \(recentEntities.joined(separator: ", "))")
        }
        return bullets
    }

    private static func hintKeywords(_ hint: ActivationContextHint?) -> Set<String> {
        guard let hint else { return [] }
        var words = Set<String>()
        if let verb = hint.verb?.lowercased(), !verb.isEmpty { words.insert(verb) }
        for keyword in hint.keywords {
            let k = keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { words.insert(k) }
        }
        if let target = hint.target?.lowercased() {
            for token in target.split(separator: " ") where token.count > 2 {
                words.insert(String(token))
            }
        }
        return words
    }

    static func markdown(for memory: ContextAppMemory) -> String {
        var lines: [String] = []
        lines.append("# \(memory.appName) UI Memory")
        lines.append("")
        lines.append("Last updated: \(iso(memory.lastSeen))")
        lines.append("First seen: \(iso(memory.firstSeen))")
        lines.append("")
        lines.append("## App Profile")
        lines.append("")
        lines.append("Learned from screenshot captures. Durable UI operation facts are separated from recent content/state. Treat this as soft memory, not exact click coordinates.")
        lines.append("")

        lines.append("## Current Work")
        lines.append("")
        if let current = memory.current {
            lines.append("- App: \(current.app)")
            lines.append("- Surface: \(current.surfaceTitle)")
            if !current.task.isEmpty {
                lines.append("- Task: \(current.task)")
            }
            if !current.topEntities.isEmpty {
                lines.append("- Top entities: \(current.topEntities.joined(separator: ", "))")
            }
            lines.append("- Updated: \(iso(current.updatedAt))")
        } else {
            lines.append("- None recorded yet.")
        }
        lines.append("")

        lines.append("## Recent Activity")
        lines.append("")
        let recent = memory.recent.suffix(10).reversed()
        if recent.isEmpty {
            lines.append("- None yet.")
        } else {
            for entry in recent {
                lines.append("- \(relativeAge(entry.timestamp)): \(entry.summary) on \(entry.surfaceTitle) (\(entry.trigger.rawValue))")
            }
        }
        lines.append("")

        lines.append("## Surfaces Seen")
        lines.append("")
        let surfaces = memory.surfaces.sorted { $0.lastSeen > $1.lastSeen }
        if surfaces.isEmpty {
            lines.append("- None yet.")
        } else {
            for surface in surfaces {
                lines.append(contentsOf: surfaceMarkdownLines(surface))
            }
        }
        lines.append("")

        lines.append("## Entities")
        lines.append("")
        if memory.entities.isEmpty {
            lines.append("- None yet.")
        } else {
            for entity in memory.entities.sorted(by: { $0.mentionCount > $1.mentionCount }).prefix(20) {
                let labelText = entity.label.isEmpty ? entity.text : entity.label
                lines.append("- **\(labelText)** (\(entity.type), mentions \(entity.mentionCount)x, last seen \(iso(entity.lastSeen)))")
            }
        }
        lines.append("")

        lines.append("## Habits")
        lines.append("")
        let habits = memory.habits
        lines.append("- Total visits: \(habits.totalVisits)")
        if habits.totalDwellMs > 0 {
            lines.append("- Total dwell: \(habits.totalDwellMs / 1000)s")
        }
        if !habits.topSurfaces.isEmpty {
            for surface in habits.topSurfaces.prefix(5) {
                lines.append("- Top surface: \(surface.title) (\(surface.count) visits)")
            }
        }
        if !habits.commonTransitions.isEmpty {
            for transition in habits.commonTransitions.prefix(5) {
                lines.append("- Common transition: \(transition.fromTitle) -> \(transition.toTitle) (\(transition.count)x)")
            }
        }
        if !habits.timeOfDayBuckets.isEmpty {
            let formatted = habits.timeOfDayBuckets
                .sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            lines.append("- Time-of-day: \(formatted)")
        }
        lines.append("")

        lines.append("## Task Recipes")
        lines.append("")
        if memory.recipes.isEmpty {
            lines.append("- None yet — recipes are promoted from transitions seen 3+ times.")
        } else {
            for recipe in memory.recipes.sorted(by: { $0.confidence > $1.confidence }) {
                let confidencePct = Int((recipe.confidence * 100).rounded())
                lines.append("- **\(recipe.name)** — from surface `\(recipe.fromSurfaceID)`, seen \(recipe.evidenceCount)x, confidence \(confidencePct)%, last used \(iso(recipe.lastUsed))")
                if !recipe.intentKeywords.isEmpty {
                    lines.append("  - Intent keywords: \(recipe.intentKeywords.joined(separator: ", "))")
                }
                for step in recipe.stepsProse {
                    lines.append("  - Step: \(step)")
                }
            }
        }
        lines.append("")

        lines.append("## Transitions")
        lines.append("")
        let transitions = memory.transitions.sorted { $0.lastSeen > $1.lastSeen }
        if transitions.isEmpty {
            lines.append("- None yet.")
        } else {
            for transition in transitions {
                lines.append("- **\(transition.fromTitle)** -> **\(transition.toTitle)** after \(transition.trigger.rawValue), evidence \(transition.evidenceCount)x, last seen \(iso(transition.lastSeen))")
            }
        }
        lines.append("")

        lines.append("## Cautions And Weak Negative Memory")
        lines.append("")
        let negative = memory.negativeNotes.sorted { $0.lastSeen > $1.lastSeen }
        if negative.isEmpty {
            lines.append("- None yet.")
        } else {
            for note in negative {
                lines.append("- **\(note.surfaceTitle)**: \(note.note) Capped evidence \(note.evidenceCount)x, last seen \(iso(note.lastSeen))")
            }
        }
        lines.append("")

        lines.append("## Stale Or Uncertain Notes")
        lines.append("")
        lines.append("- Surface identity is fingerprint-merged; similar surfaces are collapsed via OCR/landmark token overlap.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Activation helpers

    private static func currentTaskLine(_ memory: ContextAppMemory) -> String? {
        if let current = memory.current, !current.task.isEmpty {
            return current.task
        }
        let inferred = memory.surfaces
            .sorted { $0.lastSeen > $1.lastSeen }
            .flatMap(\.facts)
            .first(where: { $0.category == "task" || $0.category == "summary" })
        if let inferred, let text = ContextTextSignalFilter.memoryText(inferred.text) {
            return text
        }
        return nil
    }

    private static func primarySurface(_ memory: ContextAppMemory) -> ContextSurfaceMemory? {
        if let current = memory.current,
           let match = memory.surfaces.first(where: { $0.id == current.surfaceID }) {
            return match
        }
        let topRecent = memory.surfaces
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(3)
        let described = topRecent
            .filter { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let lhsLen = lhs.description.trimmingCharacters(in: .whitespacesAndNewlines).count
                let rhsLen = rhs.description.trimmingCharacters(in: .whitespacesAndNewlines).count
                return lhsLen > rhsLen
            }
        if let pick = described.first { return pick }
        return topRecent.first
    }

    private static func currentSurfaceSection(_ surface: ContextSurfaceMemory, appName: String) -> String {
        var lines: [String] = []
        lines.append("## Current Surface — \(surface.title)")

        // Layer 1: lead with the prose description of what this surface IS,
        // so the agent doesn't have to re-derive screen purpose from raw OCR.
        let description = surface.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            lines.append("What it is: \(description)")
        }

        let layout = surface.facts
            .filter { $0.category == "layout" }
            .compactMap { ContextTextSignalFilter.memoryText($0.text) }
        if let first = layout.first, description.range(of: first, options: .caseInsensitive) == nil {
            lines.append("Layout: \(first).")
        }

        let stableFacts = surface.facts
            .filter { $0.durability != "transient" && $0.category != "layout" }
            .prefix(6)
            .compactMap { ContextTextSignalFilter.memoryText($0.text) }
        if !stableFacts.isEmpty {
            lines.append("Stable facts:")
            for fact in stableFacts {
                lines.append("- \(fact)")
            }
        }

        let transientFacts = surface.facts
            .filter { $0.durability == "transient" && $0.category != "layout" }
            .prefix(4)
            .compactMap { ContextTextSignalFilter.memoryText($0.text) }
        if !transientFacts.isEmpty {
            lines.append("Recent state:")
            for fact in transientFacts {
                lines.append("- \(fact)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Layer 2: verb-shaped affordance inventory.
    /// Renders "Send button (footer) — sends the current message." not
    /// "Send (button, footer)."
    private static func affordanceVerbBullets(_ memory: ContextAppMemory) -> [String] {
        let surfaces = memory.surfaces.sorted { activationScore($0) > activationScore($1) }
        var seen = Set<String>()
        var bullets: [String] = []
        for surface in surfaces {
            for control in surface.controls.sorted(by: { $0.evidenceCount > $1.evidenceCount }) {
                let key = "\(control.label.lowercased())#\(control.role.lowercased())"
                guard seen.insert(key).inserted else { continue }
                let label = control.label.isEmpty ? "Unlabeled control" : control.label
                let role = control.role.isEmpty ? "control" : control.role
                let region = control.region.isEmpty ? "unknown region" : control.region
                let verb = control.verbPhrase.isEmpty ? fallbackVerb(label: label, role: role, actionHint: control.actionHint) : control.verbPhrase
                bullets.append("- **\(label)** \(role) (\(region)) — \(verb).")
                if bullets.count >= 10 { return bullets }
            }
        }
        return bullets
    }

    private static func fallbackVerb(label: String, role: String, actionHint: String) -> String {
        if !actionHint.isEmpty { return actionHint }
        let lowerRole = role.lowercased()
        switch lowerRole {
        case "button": return "press '\(label)'"
        case "tab": return "switch to the '\(label)' tab"
        case "link", "menu-item", "menuitem": return "navigate via '\(label)'"
        default: return "interact with '\(label)'"
        }
    }

    /// Layer 5: action ranking — combine app-level habits with current-surface
    /// outbound transitions, then explain why each is likely.
    private static func likelyActionBullets(for surface: ContextSurfaceMemory, memory: ContextAppMemory) -> [String] {
        let outbound = memory.transitions
            .filter { $0.fromSurfaceID == surface.id }
            .sorted { $0.evidenceCount > $1.evidenceCount }
        if outbound.isEmpty { return [] }

        var bullets: [String] = []
        for transition in outbound.prefix(4) {
            let share = max(1, transition.evidenceCount)
            bullets.append("- \(share)x: from here the user usually goes to '\(transition.toTitle)' after a \(transition.trigger.rawValue).")
        }
        return bullets
    }

    /// Layer 6: render task recipes anchored at the primary surface (or all if
    /// no current surface is known).
    private static func recipeBullets(for primary: ContextSurfaceMemory?, memory: ContextAppMemory) -> [String] {
        guard !memory.recipes.isEmpty else { return [] }
        let scoped: [ContextTaskRecipe]
        if let primary {
            let anchored = memory.recipes.filter { $0.fromSurfaceID == primary.id }
            scoped = anchored.isEmpty ? memory.recipes : anchored
        } else {
            scoped = memory.recipes
        }
        let ranked = scoped.sorted {
            ($0.confidence, $0.evidenceCount) > ($1.confidence, $1.evidenceCount)
        }
        var bullets: [String] = []
        for recipe in ranked.prefix(5) {
            let steps = recipe.stepsProse.isEmpty ? "Step prose unavailable." : recipe.stepsProse.joined(separator: " Then ")
            let confidencePct = Int((recipe.confidence * 100).rounded())
            bullets.append("- **\(recipe.name)** (seen \(recipe.evidenceCount)x, confidence \(confidencePct)%): \(steps)")
        }
        return bullets
    }

    private static func recentActivityBullets(_ memory: ContextAppMemory) -> [String] {
        let ordered = Array(memory.recent.suffix(20).reversed())
        var bullets: [String] = []
        var seenKeys = Set<String>()
        var lastNormalized: String?
        for entry in ordered {
            // Normalize so spinner-glyph variants of the same title (⠂ vs ⠐ vs ✳)
            // and trivial trigger/summary differences collapse to one entry.
            let normTitle = Self.normalizeTitleForDedup(entry.surfaceTitle)
            let trimmedSummary = Self.truncateSummary(entry.summary)
            let dedupKey = "\(normTitle)|\(trimmedSummary)|\(entry.trigger.rawValue)"
            if dedupKey == lastNormalized { continue }
            if seenKeys.contains(dedupKey) { continue }
            seenKeys.insert(dedupKey)
            lastNormalized = dedupKey

            // Suppress "captures" that are just the trigger name with no real
            // narrative — they read as noise to the agent.
            let isJustTriggerNoise = entry.summary == "\(entry.trigger.rawValue) capture"
            let displaySummary = isJustTriggerNoise
                ? "\(entry.trigger.rawValue) on \(entry.surfaceTitle)"
                : "\(trimmedSummary) on \(entry.surfaceTitle)"

            bullets.append("- \(relativeAge(entry.timestamp)): \(displaySummary)")
            if bullets.count >= 6 { break }
        }
        return bullets
    }

    /// Strip leading Unicode spinner/decoration glyphs so the same iTerm2 tab
    /// rendered with ⠂ / ⠐ / ⠠ / ✳ animation frames dedupes as one entity.
    private static func normalizeTitleForDedup(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop leading punctuation/symbol/spinner chars
        let cleaned = trimmed.drop { ch in
            ch.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) || $0.value == 0x2800 || (0x2800...0x28FF).contains($0.value) || $0.properties.generalCategory == .otherSymbol }
        }
        return String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Recent Activity is a quick-scan layer. Cap at one sentence or 100 chars.
    /// Verbose Gemini task descriptions get sent to per-surface memory instead.
    private static func truncateSummary(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 { return trimmed }
        // Prefer the first sentence boundary.
        if let dot = trimmed.firstIndex(of: "."), trimmed.distance(from: trimmed.startIndex, to: dot) < 140 {
            return String(trimmed[..<dot]) + "."
        }
        return String(trimmed.prefix(100)) + "…"
    }

    private static func entityBullets(_ memory: ContextAppMemory) -> [String] {
        memory.entities
            .sorted { $0.mentionCount > $1.mentionCount }
            .prefix(6)
            .map { entity in
                let labelText = entity.label.isEmpty ? entity.text : entity.label
                return "- \(labelText) (\(entity.type))"
            }
    }

    private static func navigationHints(_ memory: ContextAppMemory) -> [String] {
        var hints: [String] = []
        let transitions = memory.habits.commonTransitions.prefix(4)
        for transition in transitions {
            hints.append("- \(transition.fromTitle) -> \(transition.toTitle) (\(transition.count)x)")
        }
        let nav = memory.surfaces
            .flatMap(\.facts)
            .filter { $0.category == "navigation" || $0.category == "workflow" }
            .compactMap { ContextTextSignalFilter.memoryText($0.text) }
        var seen = Set<String>()
        for fact in nav {
            let key = fact.lowercased()
            guard seen.insert(key).inserted else { continue }
            hints.append("- \(fact)")
            if hints.count >= 6 { break }
        }
        return hints
    }

    private static func habitsLine(_ memory: ContextAppMemory) -> String {
        let habits = memory.habits
        guard habits.totalVisits > 0 else { return "" }
        var parts: [String] = ["Visits: \(habits.totalVisits)"]
        if let top = habits.topSurfaces.first {
            parts.append("Top surface: \(top.title) (\(top.count)x)")
        }
        if let bucket = habits.timeOfDayBuckets.max(by: { $0.value < $1.value }) {
            parts.append("Most active: \(bucket.key)")
        }
        return "- " + parts.joined(separator: " · ")
    }

    // MARK: - Markdown helpers

    private static func surfaceMarkdownLines(_ surface: ContextSurfaceMemory) -> [String] {
        var lines: [String] = []
        lines.append("- **\(surface.title)** — last seen \(iso(surface.lastSeen))")
        if !surface.description.isEmpty {
            lines.append("  - Description: \(surface.description)")
        }
        lines.append("  - Captures: \(surface.observationCount), clicks: \(surface.clickCount), activations: \(surface.activationCount)")
        if !surface.surfaceFingerprint.isEmpty {
            lines.append("  - Fingerprint: \(surface.surfaceFingerprint) (refreshed \(iso(surface.fingerprintRefreshedAt)))")
        }
        let stable = surface.facts.filter { $0.durability != "transient" }
        if !stable.isEmpty {
            lines.append("  - Durable facts:")
            for fact in stable.prefix(8) {
                guard let text = ContextTextSignalFilter.memoryText(fact.text) else { continue }
                lines.append("    - \(text) _(\(fact.category))_")
            }
        }
        if !surface.controls.isEmpty {
            lines.append("  - Affordances (verb-shaped):")
            for control in surface.controls.prefix(8) {
                let verb = control.verbPhrase.isEmpty ? fallbackVerb(label: control.label, role: control.role, actionHint: control.actionHint) : control.verbPhrase
                lines.append("    - **\(control.label)** \(control.role) (\(control.region)) — \(verb).")
            }
        }
        let recipes = recipeLines(from: surface)
        if !recipes.isEmpty {
            lines.append("  - Task recipes:")
            for recipe in recipes.prefix(6) {
                lines.append("    - \(recipe)")
            }
        }
        if !surface.entities.isEmpty {
            let values = cleanValues(surface.entities.map(\.text)).prefix(8)
            if !values.isEmpty {
                lines.append("  - Entities:")
                for value in values {
                    lines.append("    - \(value)")
                }
            }
        }
        let transient = surface.facts.filter { $0.durability == "transient" }
        if !transient.isEmpty {
            lines.append("  - Recent / transient state:")
            for fact in transient.prefix(6) {
                guard let text = ContextTextSignalFilter.memoryText(fact.text) else { continue }
                lines.append("    - \(text) _(\(fact.category))_")
            }
        }
        // textHighlights deliberately not rendered to the agent: they're raw
        // OCR fragments (mostly noise even after the new .accurate OCR layer)
        // and the structured semanticHighlights + Gemini-derived facts above
        // already carry the same info in cleaner form. Kept on the surface
        // for offline inspection in Dev Tools / Memory tab.
        if !surface.uncertaintyHighlights.isEmpty {
            let values = cleanValues(surface.uncertaintyHighlights).prefix(4)
            if !values.isEmpty {
                lines.append("  - Uncertain:")
                for value in values {
                    lines.append("    - \(value)")
                }
            }
        }
        return lines
    }

    private static func activationScore(_ surface: ContextSurfaceMemory) -> Int {
        let durableFacts = surface.facts.filter { $0.durability != "transient" }.count
        return durableFacts * 4
            + surface.controls.count * 3
            + surface.entities.count
            + surface.affordanceHighlights.count * 2
            + surface.transitionsProxyScore
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
        if seconds < 5 {
            return "now"
        }
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
