//
//  ContextDebugView+Report.swift
//  Agent in the Notch
//
//  Run Metrics: a tile-based dashboard over the new context system.
//  Aggregates from EventLog, PrivacyGate, L5Store, ContextSelector, and the
//  on-disk AnchorRecorder collections. Refreshes every 5s — these numbers
//  change slowly.
//

import SwiftUI

struct ContextDebugReportPane: View {

    @State private var data = ReportData()
    @State private var refreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                tilesGrid
                Divider()
                breakdowns
            }
            .padding(16)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .foregroundStyle(Color.accentColor)
            Text("Run metrics")
                .font(.headline)
            Spacer()
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private var tilesGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            MetricTile(label: "events / min", value: "\(data.eventsPerMin)", caption: "last 60s")
            MetricTile(label: "selector p50", value: data.p50LatencyS.map { String(format: "%.2fs", $0) } ?? "—", caption: "last \(data.selectorSampleCount) runs")
            MetricTile(label: "selector p95", value: data.p95LatencyS.map { String(format: "%.2fs", $0) } ?? "—", caption: "last \(data.selectorSampleCount) runs")
            MetricTile(label: "degraded", value: data.degradedPctText, caption: "of last \(data.selectorSampleCount) runs")
            MetricTile(label: "promoted recipes", value: "\(data.promotedRecipes)", caption: "across all apps")
            MetricTile(label: "candidate recipes", value: "\(data.candidateRecipes)", caption: "<3 observations")
            MetricTile(label: "redactions", value: "\(data.totalRedactions)", caption: "total since launch")
            MetricTile(label: "active task age", value: data.activeTaskAgeText, caption: data.activeTaskStaleText)
            MetricTile(label: "task narrative", value: "\(data.activeTaskNarrativeChars)", caption: "chars")
            MetricTile(label: "task resources", value: "\(data.activeTaskResources)", caption: "URIs")
        }
    }

    private var breakdowns: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Events by kind (last 60s)")
                    .font(.system(size: 12, weight: .semibold))
                if data.eventBreakdown.isEmpty {
                    Text("(none)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(data.eventBreakdown, id: \.kind) { row in
                        HStack {
                            Text(row.kind)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(row.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Redactions by reason (since launch)")
                    .font(.system(size: 12, weight: .semibold))
                if data.redactionBreakdown.isEmpty {
                    Text("(none)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(data.redactionBreakdown, id: \.reason) { row in
                        HStack {
                            Text(row.reason)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(row.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    // MARK: - Refresh

    private func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        data = ReportData.compute()
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - Data aggregation

private struct ReportData {
    var eventsPerMin: Int = 0
    var eventBreakdown: [(kind: String, count: Int)] = []

    var totalRedactions: Int = 0
    var redactionBreakdown: [(reason: String, count: Int)] = []

    var promotedRecipes: Int = 0
    var candidateRecipes: Int = 0

    var p50LatencyS: Double?
    var p95LatencyS: Double?
    var degradedFraction: Double = 0
    var selectorSampleCount: Int = 0

    var activeTaskAgeText: String = "—"
    var activeTaskStaleText: String = "no active task"
    var activeTaskNarrativeChars: Int = 0
    var activeTaskResources: Int = 0

    var degradedPctText: String {
        guard selectorSampleCount > 0 else { return "—" }
        return String(format: "%.0f%%", degradedFraction * 100)
    }

    static func compute() -> ReportData {
        var out = ReportData()

        // EventLog: events in last 60s + breakdown.
        let events = EventLog.shared.snapshot()
        let cutoff = Date().addingTimeInterval(-60)
        let recentEvents = events.filter { $0.t >= cutoff }
        out.eventsPerMin = recentEvents.count
        let grouped = Dictionary(grouping: recentEvents, by: { $0.kind.rawValue })
        out.eventBreakdown = grouped
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        // PrivacyGate redaction counts.
        let counts = PrivacyGate.shared.redactionCounts
        out.totalRedactions = counts.values.reduce(0, +)
        out.redactionBreakdown = counts
            .map { (reason: $0.key.rawValue, count: $0.value) }
            .sorted { $0.count > $1.count }

        // AnchorRecorder: walk per-app json files.
        let (promoted, candidates) = countRecipesOnDisk()
        out.promotedRecipes = promoted
        out.candidateRecipes = candidates

        // ContextSelector latency p50/p95 + degraded%.
        let runs = ContextSelector.shared.recentRuns
        out.selectorSampleCount = runs.count
        if !runs.isEmpty {
            let latencies = runs.map { $0.latencyS }.sorted()
            out.p50LatencyS = percentile(latencies, p: 0.5)
            out.p95LatencyS = percentile(latencies, p: 0.95)
            let degraded = runs.filter { $0.degraded }.count
            out.degradedFraction = Double(degraded) / Double(runs.count)
        }

        // L5 active task.
        if let task = L5Store.shared.loadActiveTask() {
            let age = Date().timeIntervalSince(task.startedAt)
            out.activeTaskAgeText = formatAge(age)
            if let stale = task.staleSince {
                let staleAge = Date().timeIntervalSince(stale)
                out.activeTaskStaleText = "STALE \(formatAge(staleAge))"
            } else {
                out.activeTaskStaleText = "fresh"
            }
            out.activeTaskNarrativeChars = task.narrative.count
            out.activeTaskResources = task.resources.count
        }

        return out
    }

    private static func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let rank = max(0, min(values.count - 1, Int((Double(values.count - 1) * p).rounded())))
        return values[rank]
    }

    private static func formatAge(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return String(format: "%.1fh", s / 3600) }
        return String(format: "%.1fd", s / 86_400)
    }

    /// Walk every per-app json under AnchorRecorder.storageRoot and sum
    /// `recipes.count` + `candidates.count`. Best-effort: skip files that
    /// don't decode.
    private static let recipeDecoder = JSONDecoder()

    private static func countRecipesOnDisk() -> (promoted: Int, candidates: Int) {
        let fm = FileManager.default
        let root = AnchorRecorder.storageRoot
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        var promoted = 0
        var candidates = 0
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let coll = try? recipeDecoder.decode(CAppRecipes.self, from: data) else { continue }
            promoted += coll.recipes.count
            candidates += coll.candidates.count
        }
        return (promoted, candidates)
    }
}
