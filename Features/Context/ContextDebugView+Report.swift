//
//  ContextDebugView+Report.swift
//  Agent in the Notch
//
//  Dev Tools pane: harness run metrics. Top summary + per-run rows with
//  per-run disclosure to drill into action counts.
//

import SwiftUI

struct ContextDebugReportPane: View {
    @StateObject private var model = ReportPaneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.runs.isEmpty {
                        Text("No harness runs recorded yet. Fire one (long-press cursor and speak) to populate this report.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(20)
                    } else {
                        ForEach(model.runs, id: \.id) { run in
                            RunRow(run: run)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Run metrics")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 14) {
                SummaryChip(label: "runs", value: "\(model.summary.totalRuns)")
                SummaryChip(label: "completed", value: String(format: "%.0f%%", model.summary.completedFraction * 100))
                SummaryChip(label: "p50 dur", value: "\(model.summary.p50DurationMs)ms")
                SummaryChip(label: "p90 dur", value: "\(model.summary.p90DurationMs)ms")
                SummaryChip(label: "p50 turns", value: "\(model.summary.p50Turns)")
                SummaryChip(label: "p50 tools", value: "\(model.summary.p50Tools)")
                SummaryChip(label: "fallback", value: String(format: "%.0f%%", model.summary.fallbackFraction * 100))
            }
        }
    }
}

private struct SummaryChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct RunRow: View {
    let run: AgentRunMetricsRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .frame(width: 14)

                Text(timestamp(run.startedAt))
                    .font(.caption.monospacedDigit())
                    .frame(width: 110, alignment: .leading)

                Text(modelLabel)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 220, alignment: .leading)

                StatusPill(status: run.finalStatus)
                    .frame(width: 180, alignment: .leading)

                Text("\(run.durationMs)ms")
                    .font(.caption.monospacedDigit())
                    .frame(width: 80, alignment: .leading)

                Text("\(run.turnCount)t / \(run.toolCallCount)c (\(run.screenshotToolCallCount) shot)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 180, alignment: .leading)

                Spacer()
            }

            HStack(spacing: 8) {
                MetricPill(label: "1st tool", value: run.timeToFirstToolCallMs.map { "\($0)ms" } ?? "—")
                MetricPill(label: "1st action", value: run.timeToFirstNonScreenshotActionMs.map { "\($0)ms" } ?? "—")
                MetricPill(label: "transcript", value: "\(run.transcriptLength) chars")
                MetricPill(label: "context", value: "\(run.contextLength) chars")
                if run.contextIncluded {
                    Label("context", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Label("no context", systemImage: "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 26)

            if let message = run.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            }

            if expanded {
                actionCountsView
                    .padding(.leading, 26)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
    }

    private var modelLabel: String {
        run.usedFallback ? "\(run.modelID) → \(run.fallbackModelID)" : run.modelID
    }

    private var actionCountsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Action counts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let pairs = run.actionCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            let maxValue = pairs.map(\.value).max() ?? 1
            ForEach(pairs, id: \.key) { pair in
                HStack(spacing: 8) {
                    Text(pair.key)
                        .font(.caption.monospaced())
                        .frame(width: 160, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.55))
                                .frame(width: geo.size.width * CGFloat(pair.value) / CGFloat(maxValue))
                        }
                    }
                    .frame(height: 10)
                    Text("\(pair.value)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct StatusPill: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case "completed_without_tool", "completed_after_tools", "completed_fast_path":
            return .green
        case "anthropic_error", "network_error", "fatal_error":
            return .red
        case "max_turns", "stopped_by_user":
            return .yellow
        default:
            return .accentColor
        }
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }
}

struct RunSummary: Sendable {
    var totalRuns: Int = 0
    var completedFraction: Double = 0
    var p50DurationMs: Int = 0
    var p90DurationMs: Int = 0
    var p50Turns: Int = 0
    var p50Tools: Int = 0
    var fallbackFraction: Double = 0
}

@MainActor
private final class ReportPaneModel: ObservableObject {
    @Published private(set) var runs: [AgentRunMetricsRecord] = []
    @Published private(set) var summary = RunSummary()

    private var timer: Timer?

    func start() async {
        await refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        let runs = await AgentRunMetricsStore.shared.recentRuns(limit: 50)
        self.runs = runs
        self.summary = Self.summarize(runs)
    }

    static func summarize(_ runs: [AgentRunMetricsRecord]) -> RunSummary {
        guard !runs.isEmpty else { return RunSummary() }
        let completed = runs.filter {
            $0.finalStatus.hasPrefix("completed")
        }.count
        let fallback = runs.filter(\.usedFallback).count
        let durations = runs.map(\.durationMs).sorted()
        let turns = runs.map(\.turnCount).sorted()
        let tools = runs.map(\.toolCallCount).sorted()
        return RunSummary(
            totalRuns: runs.count,
            completedFraction: Double(completed) / Double(runs.count),
            p50DurationMs: percentile(durations, p: 0.5),
            p90DurationMs: percentile(durations, p: 0.9),
            p50Turns: percentile(turns, p: 0.5),
            p50Tools: percentile(tools, p: 0.5),
            fallbackFraction: Double(fallback) / Double(runs.count)
        )
    }

    static func percentile(_ values: [Int], p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let rank = max(0, min(values.count - 1, Int((Double(values.count - 1) * p).rounded())))
        return values[rank]
    }
}
