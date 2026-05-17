//
//  ContextDebugView+Memory.swift
//  Agent in the Notch
//
//  Memory pane for the Dev Tools window. A hierarchical browser over the
//  learned UI memory model (apps → surfaces → facts/controls/entities, plus
//  transitions and negative notes). Refreshes every 3 seconds while visible.
//
//  Owner contract: this file only contributes `memoryPane` on
//  `ContextDebugView`. The root shell + every other pane is owned by Agent A;
//  do not add navigation or window code here.
//

import SwiftUI

extension ContextDebugView {
    public var memoryPane: some View {
        MemoryPaneView()
    }
}

// MARK: - Root pane

private struct MemoryPaneView: View {
    @StateObject private var model = MemoryPaneModel()
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.startAutoRefresh()
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.purple)
            Text("Learned UI Memory")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            searchField
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter apps", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 180)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshNow() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help("Refresh now")
    }

    private var content: some View {
        Group {
            if model.isLoadingInitial {
                placeholder(
                    icon: "hourglass",
                    title: "Loading memory…",
                    detail: "Reading persisted app memories from disk."
                )
            } else if model.apps.isEmpty {
                placeholder(
                    icon: "tray",
                    title: "No learned memory yet",
                    detail: "Memory is built from screen captures + Gemini observations. Use the app for a bit and surfaces, controls, and entities will start showing up here."
                )
            } else if filteredApps.isEmpty {
                placeholder(
                    icon: "magnifyingglass",
                    title: "No apps match",
                    detail: "Clear the filter to see every learned app."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredApps, id: \.appName) { app in
                            AppMemorySection(app: app)
                                .padding(.horizontal, 12)
                        }
                        if let stamp = model.lastRefreshAt {
                            Text("Refreshed \(MemoryFormat.relative(stamp))")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 4)
                                .padding(.bottom, 10)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var filteredApps: [ContextAppMemory] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return model.apps }
        return model.apps.filter { $0.appName.lowercased().contains(trimmed) }
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - App row

private struct AppMemorySection: View {
    let app: ContextAppMemory
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                CurrentWorkSubsection(app: app)
                RecentActivitySubsection(app: app)
                UISurfacesSubsection(app: app)
                EntitiesSubsection(app: app)
                HabitsSubsection(app: app)
                TaskRecipesSubsection(app: app)
                TransitionsSubsection(app: app)
                NegativeNotesSubsection(app: app)
            }
            .padding(.top, 6)
        } label: {
            appHeader
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var appHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
            Text(app.appName)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            CountPill(icon: "rectangle.stack", value: app.surfaces.count, color: .purple, label: "surfaces")
            CountPill(icon: "person.2", value: totalEntityCount, color: .green, label: "entities")
            CountPill(icon: "arrow.right.arrow.left", value: app.transitions.count, color: .orange, label: "transitions")
            Text(MemoryFormat.relative(app.lastSeen))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var totalEntityCount: Int {
        app.surfaces.reduce(0) { $0 + $1.entities.count }
    }
}

// MARK: - Subsections

private struct CurrentWorkSubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(title: "Current Work", icon: "bolt.fill", tint: .yellow) {
            if let surface = currentSurface {
                VStack(alignment: .leading, spacing: 4) {
                    KeyValueRow(key: "App", value: app.appName)
                    KeyValueRow(key: "Surface", value: surface.title)
                    if let task = inferredTask(from: surface) {
                        KeyValueRow(key: "Task", value: task)
                    }
                    if !topEntities(from: surface).isEmpty {
                        KeyValueRow(
                            key: "Top entities",
                            value: topEntities(from: surface).joined(separator: ", ")
                        )
                    }
                    KeyValueRow(key: "Updated", value: MemoryFormat.absolute(surface.lastSeen))
                }
            } else {
                EmptyHint(text: "No active surface yet — memory hasn't seen a recent capture.")
            }
        }
    }

    private var currentSurface: ContextSurfaceMemory? {
        app.surfaces.sorted { $0.lastSeen > $1.lastSeen }.first
    }

    private func inferredTask(from surface: ContextSurfaceMemory) -> String? {
        if let taskFact = surface.facts.first(where: { $0.category == "task" }) {
            return taskFact.text
        }
        return surface.semanticHighlights.first
    }

    private func topEntities(from surface: ContextSurfaceMemory) -> [String] {
        Array(
            surface.entities
                .sorted { $0.evidenceCount > $1.evidenceCount }
                .prefix(5)
                .map { $0.text }
        )
    }
}

private struct RecentActivitySubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(title: "Recent Activity", icon: "clock.arrow.circlepath", tint: .blue) {
            let entries = recentEntries
            if entries.isEmpty {
                EmptyHint(text: "No recent activity captured.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            ActivityEntryRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var recentEntries: [ActivityEntry] {
        app.surfaces
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(10)
            .map { surface in
                let summary: String
                if let fact = surface.facts.first(where: { $0.category == "summary" }) {
                    summary = fact.text
                } else if let highlight = surface.semanticHighlights.first {
                    summary = highlight
                } else if let text = surface.textHighlights.first {
                    summary = text
                } else {
                    let clicks = surface.clickCount
                    let activations = surface.activationCount
                    summary = "\(clicks) clicks, \(activations) activations"
                }
                let trigger: String
                if surface.clickCount > surface.activationCount {
                    trigger = "click"
                } else if surface.activationCount > 0 {
                    trigger = "activation"
                } else {
                    trigger = "observation"
                }
                return ActivityEntry(
                    id: surface.id + "@" + String(surface.lastSeen.timeIntervalSince1970),
                    when: surface.lastSeen,
                    summary: summary,
                    surfaceTitle: surface.title,
                    trigger: trigger
                )
            }
    }
}

private struct ActivityEntry: Identifiable {
    let id: String
    let when: Date
    let summary: String
    let surfaceTitle: String
    let trigger: String
}

private struct ActivityEntryRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(MemoryFormat.relative(entry.when))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary)
                    .font(.system(size: 11))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.surfaceTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    TypePill(label: entry.trigger, tint: triggerColor(entry.trigger))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func triggerColor(_ trigger: String) -> Color {
        switch trigger {
        case "click": return .green
        case "activation": return .blue
        default: return .gray
        }
    }
}

private struct UISurfacesSubsection: View {
    let app: ContextAppMemory

    private let maxSurfaces = 20

    var body: some View {
        Subsection(
            title: "UI Surfaces",
            icon: "rectangle.stack",
            tint: .purple,
            count: app.surfaces.count
        ) {
            let sorted = Array(app.surfaces.sorted { $0.lastSeen > $1.lastSeen }.prefix(maxSurfaces))
            if sorted.isEmpty {
                EmptyHint(text: "No surfaces learned yet.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sorted) { surface in
                        SurfaceRow(surface: surface)
                    }
                    if app.surfaces.count > maxSurfaces {
                        Text("Showing \(maxSurfaces) of \(app.surfaces.count) surfaces.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct SurfaceRow: View {
    let surface: ContextSurfaceMemory
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let desc = surfaceDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                if !surface.facts.isEmpty {
                    FactsByCategory(facts: surface.facts)
                }
                if !surface.controls.isEmpty {
                    ControlsList(controls: surface.controls)
                }
                if !surface.entities.isEmpty {
                    EntitiesInline(entities: surface.entities)
                }
                HighlightsBlock(title: "Affordances", values: surface.affordanceHighlights, tint: .orange)
                HighlightsBlock(title: "Semantic", values: surface.semanticHighlights, tint: .blue)
                HighlightsBlock(title: "Uncertainty", values: surface.uncertaintyHighlights, tint: .red)
            }
            .padding(.leading, 14)
            .padding(.top, 4)
            .padding(.bottom, 4)
        } label: {
            surfaceHeader
        }
        .padding(.vertical, 2)
    }

    private var surfaceHeader: some View {
        HStack(spacing: 8) {
            Text(surface.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let fingerprint = surfaceFingerprint {
                Text(fingerprint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            ForEach(surfaceTokens, id: \.self) { token in
                Text(token)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.purple.opacity(0.15))
                    )
                    .foregroundStyle(.purple)
            }
            Spacer()
            countBadges
            Text(MemoryFormat.relative(surface.lastSeen))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var countBadges: some View {
        HStack(spacing: 4) {
            countBadge(icon: "eye", value: surface.observationCount, tint: .gray)
            countBadge(icon: "hand.tap", value: surface.clickCount, tint: .green)
            countBadge(icon: "rectangle.on.rectangle", value: surface.activationCount, tint: .blue)
        }
    }

    private func countBadge(icon: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text("\(value)")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(tint)
    }

    private var surfaceFingerprint: String? {
        let id = surface.id
        guard !id.isEmpty else { return nil }
        return String(id.prefix(12))
    }

    private var surfaceTokens: [String] {
        let raw = surface.id
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return Array(raw.prefix(6))
    }

    private var surfaceDescription: String? {
        if let summary = surface.facts.first(where: { $0.category == "summary" })?.text {
            return summary
        }
        return surface.semanticHighlights.first
    }
}

private struct FactsByCategory: View {
    let facts: [ContextMemoryFact]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Facts")
            ForEach(groupedCategories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TypePill(label: category, tint: factCategoryColor(category))
                        Text("(\(grouped[category]?.count ?? 0))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(grouped[category] ?? []) { fact in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(fact.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text("×\(fact.evidenceCount)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 6)
                    }
                }
            }
        }
    }

    private var grouped: [String: [ContextMemoryFact]] {
        Dictionary(grouping: facts) { $0.category }
    }

    private var groupedCategories: [String] {
        grouped.keys.sorted()
    }
}

private struct ControlsList: View {
    let controls: [ContextControlMemory]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Controls (\(controls.count))")
            ForEach(controls) { control in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(control.label)
                                .font(.system(size: 11, weight: .medium))
                            TypePill(label: control.role, tint: .blue)
                            TypePill(label: control.region, tint: .gray)
                        }
                        if !control.actionHint.isEmpty {
                            Text(control.actionHint)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 6)
            }
        }
    }
}

private struct EntitiesInline: View {
    let entities: [ContextEntityMemory]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Entities (\(entities.count))")
            FlowingTags(values: entities.prefix(20).map { $0.text }, tint: .green)
        }
    }
}

private struct EntitiesSubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(
            title: "Entities",
            icon: "person.2",
            tint: .green,
            count: aggregated.count
        ) {
            let top = Array(aggregated.prefix(25))
            if top.isEmpty {
                EmptyHint(text: "No entities have been learned yet.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(top) { row in
                        HStack(spacing: 6) {
                            Text(row.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            TypePill(label: row.type, tint: entityTypeColor(row.type))
                            Spacer()
                            Text("×\(row.mentionCount)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("\(row.surfaceCount) surfaces")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(MemoryFormat.relative(row.lastSeen))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var aggregated: [AggregatedEntity] {
        var bucket: [String: AggregatedEntity] = [:]
        for surface in app.surfaces {
            for entity in surface.entities {
                let key = entity.text.lowercased()
                if var existing = bucket[key] {
                    existing.mentionCount += entity.evidenceCount
                    existing.surfaceCount += 1
                    existing.firstSeen = min(existing.firstSeen, entity.firstSeen)
                    existing.lastSeen = max(existing.lastSeen, entity.lastSeen)
                    bucket[key] = existing
                } else {
                    bucket[key] = AggregatedEntity(
                        id: key,
                        label: entity.text,
                        type: classify(entity.text),
                        mentionCount: entity.evidenceCount,
                        surfaceCount: 1,
                        firstSeen: entity.firstSeen,
                        lastSeen: entity.lastSeen
                    )
                }
            }
        }
        return bucket.values.sorted { $0.mentionCount > $1.mentionCount }
    }

    private func classify(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") { return "url" }
        if lower.contains("@") && lower.contains(".") { return "person" }
        if lower.hasSuffix(".swift") || lower.hasSuffix(".md") || lower.hasSuffix(".json") || lower.hasSuffix(".txt") { return "file" }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") { return "error" }
        if lower.hasPrefix("#") || lower.contains("ticket") || lower.contains("issue") { return "ticket" }
        return "text"
    }
}

private struct AggregatedEntity: Identifiable {
    let id: String
    let label: String
    let type: String
    var mentionCount: Int
    var surfaceCount: Int
    var firstSeen: Date
    var lastSeen: Date
}

private struct HabitsSubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(title: "Habits", icon: "chart.bar.fill", tint: .orange) {
            VStack(alignment: .leading, spacing: 6) {
                let totalVisits = app.surfaces.reduce(0) { $0 + $1.observationCount }
                let dwellMinutes = max(1, app.lastSeen.timeIntervalSince(app.firstSeen) / 60.0)
                KeyValueRow(key: "Total visits", value: "\(totalVisits)")
                KeyValueRow(key: "Span", value: String(format: "%.1f min", dwellMinutes))
                topSurfaces
                topTransitions
                timeOfDayChart
            }
        }
    }

    private var topSurfaces: some View {
        let top = Array(
            app.surfaces
                .sorted { $0.observationCount > $1.observationCount }
                .prefix(5)
        )
        return VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: "Top surfaces")
            if top.isEmpty {
                EmptyHint(text: "No surfaces yet.")
            } else {
                ForEach(top) { surface in
                    HStack(spacing: 6) {
                        Text(surface.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text("\(surface.observationCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var topTransitions: some View {
        let top = Array(
            app.transitions
                .sorted { $0.evidenceCount > $1.evidenceCount }
                .prefix(5)
        )
        return VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: "Common transitions")
            if top.isEmpty {
                EmptyHint(text: "No transitions yet.")
            } else {
                ForEach(top) { transition in
                    HStack(spacing: 4) {
                        Text(transition.fromTitle)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(transition.toTitle)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Spacer()
                        Text("×\(transition.evidenceCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var timeOfDayChart: some View {
        let buckets = computeTimeBuckets()
        let maxValue = max(1, buckets.values.max() ?? 1)
        return VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: "Time of day")
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = buckets[String(format: "%02d", hour)] ?? 0
                    let frac = Double(count) / Double(maxValue)
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.orange.opacity(0.2 + frac * 0.8))
                            .frame(width: 8, height: CGFloat(2 + frac * 22))
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func computeTimeBuckets() -> [String: Int] {
        var bucket: [String: Int] = [:]
        let cal = Calendar.current
        for surface in app.surfaces {
            let hour = cal.component(.hour, from: surface.lastSeen)
            let key = String(format: "%02d", hour)
            bucket[key, default: 0] += surface.observationCount
        }
        return bucket
    }
}

private struct TaskRecipesSubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(title: "Task Recipes", icon: "list.number", tint: .indigo, count: synthesizedRecipes.count) {
            let recipes = synthesizedRecipes
            if recipes.isEmpty {
                EmptyHint(text: "No recipes synthesized yet — needs more workflow + navigation facts.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recipes) { recipe in
                        RecipeRow(recipe: recipe)
                    }
                }
            }
        }
    }

    private var synthesizedRecipes: [SynthRecipe] {
        var recipes: [SynthRecipe] = []
        for surface in app.surfaces {
            let workflow = surface.facts.filter { $0.category == "workflow" || $0.category == "navigation" }
            guard !workflow.isEmpty else { continue }
            let confidence = workflow.map { $0.confidence }.reduce(0, +) / Double(workflow.count)
            let intent = surface.facts.first { $0.category == "task" }?.text ?? surface.title
            let steps = workflow.map { $0.text }
            let evidence = workflow.reduce(0) { $0 + $1.evidenceCount }
            let lastUsed = workflow.map { $0.lastSeen }.max() ?? surface.lastSeen
            recipes.append(SynthRecipe(
                id: surface.id,
                fromSurfaceID: surface.id,
                name: intent,
                intentKeywords: tokenize(intent),
                stepsProse: steps,
                evidenceCount: evidence,
                confidence: confidence,
                lastUsed: lastUsed
            ))
        }
        return recipes.sorted { $0.confidence > $1.confidence }
    }

    private func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count > 3 }
            .prefix(6)
            .map(String.init)
    }
}

private struct SynthRecipe: Identifiable {
    let id: String
    let fromSurfaceID: String
    let name: String
    let intentKeywords: [String]
    let stepsProse: [String]
    let evidenceCount: Int
    let confidence: Double
    let lastUsed: Date
}

private struct RecipeRow: View {
    let recipe: SynthRecipe
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                KeyValueRow(key: "From surface", value: recipe.fromSurfaceID)
                ForEach(Array(recipe.stepsProse.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 4) {
                        Text("\(idx + 1).")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(step)
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(recipe.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if !recipe.intentKeywords.isEmpty {
                    Text(recipe.intentKeywords.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("e=\(recipe.evidenceCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.0f%%", recipe.confidence * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.indigo)
                Text(MemoryFormat.relative(recipe.lastUsed))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TransitionsSubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(title: "Transitions", icon: "arrow.right.arrow.left", tint: .orange, count: app.transitions.count) {
            let sorted = app.transitions.sorted { $0.lastSeen > $1.lastSeen }
            if sorted.isEmpty {
                EmptyHint(text: "No transitions learned yet.")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(sorted) { transition in
                        HStack(spacing: 6) {
                            Text(transition.fromTitle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(transition.toTitle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            TypePill(label: transition.trigger.rawValue, tint: triggerTint(transition.trigger))
                            Spacer()
                            Text("e=\(transition.evidenceCount)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(MemoryFormat.relative(transition.lastSeen))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func triggerTint(_ trigger: ContextCaptureTrigger) -> Color {
        switch trigger {
        case .click: return .green
        case .activation: return .blue
        case .appSwitch: return .purple
        case .manual: return .orange
        case .startup: return .gray
        }
    }
}

private struct NegativeNotesSubsection: View {
    let app: ContextAppMemory

    var body: some View {
        Subsection(title: "Negative Memory", icon: "exclamationmark.triangle", tint: .red, count: app.negativeNotes.count) {
            let sorted = app.negativeNotes.sorted { $0.lastSeen > $1.lastSeen }
            if sorted.isEmpty {
                EmptyHint(text: "No negative notes — agent hasn't flagged any anti-patterns.")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(sorted) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(note.surfaceTitle)
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text("e=\(note.evidenceCount)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(note.note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red.opacity(0.06))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Shared subviews

private struct Subsection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var count: Int? = nil
    @ViewBuilder var content: () -> Content
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .padding(.leading, 18)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if let count {
                    Text("(\(count))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CountPill: View {
    let icon: String
    let value: Int
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text("\(value)")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.12))
        )
        .help("\(value) \(label)")
    }
}

private struct TypePill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.15))
            )
    }
}

private struct HighlightsBlock: View {
    let title: String
    let values: [String]
    let tint: Color

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: title)
                FlowingTags(values: values, tint: tint)
            }
        }
    }
}

private struct FlowingTags: View {
    let values: [String]
    let tint: Color

    var body: some View {
        WrappingHStack(values: Array(values.prefix(20))) { value in
            Text(value)
                .font(.system(size: 10))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(0.12))
                )
                .foregroundStyle(tint)
        }
    }
}

private struct WrappingHStack<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(values: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = values
        self.content = content
    }

    var body: some View {
        var totalWidth = CGFloat.zero
        var totalHeight = CGFloat.zero
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.self) { item in
                    content(item)
                        .alignmentGuide(.leading) { d in
                            if abs(totalWidth - d.width) > geometry.size.width {
                                totalWidth = 0
                                totalHeight -= d.height + 4
                            }
                            let result = totalWidth
                            if item == items.last {
                                totalWidth = 0
                            } else {
                                totalWidth -= d.width + 4
                            }
                            return result
                        }
                        .alignmentGuide(.top) { _ in
                            let result = totalHeight
                            if item == items.last {
                                totalHeight = 0
                            }
                            return result
                        }
                }
            }
        }
        .frame(height: estimatedHeight)
    }

    private var estimatedHeight: CGFloat {
        // Rough estimate: 4 items per row, 20px per row. Cap at ~80px so the
        // surrounding ScrollView keeps reasonable bounds.
        let rows = max(1, Int(ceil(Double(items.count) / 6.0)))
        return CGFloat(min(rows, 4)) * 20
    }
}

private struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .italic()
    }
}

// MARK: - Color helpers

private func entityTypeColor(_ type: String) -> Color {
    switch type {
    case "person": return .green
    case "file": return .blue
    case "url": return .purple
    case "app": return .orange
    case "ticket": return .pink
    case "error": return .red
    default: return .gray
    }
}

private func factCategoryColor(_ category: String) -> Color {
    switch category {
    case "summary": return .blue
    case "task": return .green
    case "layout": return .purple
    case "content": return .indigo
    case "state": return .orange
    case "data-region": return .teal
    case "navigation": return .pink
    case "workflow": return .mint
    case "affordance": return .yellow
    case "memory": return .gray
    default: return .secondary
    }
}

// MARK: - Formatting

private enum MemoryFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }
}

// MARK: - View model

@MainActor
private final class MemoryPaneModel: ObservableObject {
    @Published private(set) var apps: [ContextAppMemory] = []
    @Published private(set) var isLoadingInitial: Bool = true
    @Published private(set) var lastRefreshAt: Date?

    private var refreshTask: Task<Void, Never>?

    func startAutoRefresh() async {
        await refreshNow()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshNow()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshNow() async {
        let snapshot = await ContextMemoryStore.shared.debugMemories(limit: 50)
        self.apps = snapshot
        self.isLoadingInitial = false
        self.lastRefreshAt = Date()
    }
}

#if DEBUG
#Preview {
    ContextDebugView()
        .frame(width: 760, height: 520)
}
#endif
