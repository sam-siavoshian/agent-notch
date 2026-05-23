//
//  ContextDebugView+Harness.swift
//  Agent in the Notch
//
//  Dev Tools "Harness Detail" pane: deep-dive into recent ComputerUseHarness
//  runs. Shows the system blocks sent (with cache markers), the per-turn
//  Anthropic request/response timeline, and per-turn tool calls + results.
//  Prompt cache hit/miss is the headline signal — cache_read_input_tokens is
//  called out prominently for every turn.
//

import SwiftUI

struct ContextDebugHarnessPane: View {
    @StateObject private var model = ContextDebugHarnessViewModel()
    @State private var selectedRunID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HSplitView {
                runList
                    .frame(minWidth: 280, idealWidth: 320)
                detail
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
            Text("Harness Detail")
                .font(.headline)
            Spacer()
            if let last = model.lastRefresh {
                Text("Updated \(Self.timeFormatter.string(from: last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var runList: some View {
        Group {
            if model.runs.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No harness runs captured yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedRunID) {
                    ForEach(model.runs) { run in
                        runRow(run)
                            .tag(Optional(run.id))
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func runRow(_ run: HarnessRunDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: run.startedAt))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                statusPill(run.finalStatus)
            }
            Text(run.transcript.isEmpty ? "(empty transcript)" : run.transcript)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Text("\(run.turns.count) turn\(run.turns.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let ended = run.endedAt {
                    let ms = max(0, Int(ended.timeIntervalSince(run.startedAt) * 1000))
                    Text("· \(ms)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let verb = run.resolvedIntentVerb, !verb.isEmpty {
                    Text("· intent: \(verb)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusPill(_ status: String?) -> some View {
        let label = status ?? "running"
        let color = Self.statusColor(for: label)
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private static func statusColor(for status: String) -> Color {
        if status.contains("completed") { return .green }
        if status.contains("stopped") { return .yellow }
        if status.contains("error") || status.contains("max_turns") { return .red }
        return .blue
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedRunID, let run = model.runs.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    systemBlocksSection(run)
                    Divider()
                    turnsSection(run)
                }
                .padding(12)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a run to inspect its system blocks, per-turn tokens, and tool calls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func systemBlocksSection(_ run: HarnessRunDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System blocks (\(run.systemBlocks.count))")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(run.systemBlocks.enumerated()), id: \.offset) { _, block in
                systemBlockRow(block)
            }
        }
    }

    private func systemBlockRow(_ block: HarnessRunDetail.SystemBlockSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(block.cached ? "CACHED" : "uncached")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((block.cached ? Color.green : Color.gray).opacity(0.18))
                    .foregroundStyle(block.cached ? Color.green : Color.secondary)
                    .clipShape(Capsule())
                Text("\(block.charCount) chars")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(block.preview)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func turnsSection(_ run: HarnessRunDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-turn timeline (\(run.turns.count))")
                .font(.subheadline.weight(.semibold))
            if run.turns.isEmpty {
                Text("No turns recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(run.turns) { turn in
                    turnRow(turn)
                }
            }
        }
    }

    private func turnRow(_ turn: HarnessTurnRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                metaRow("model", turn.model)
                if let s = turn.stopReason { metaRow("stop_reason", s) }
                metaRow("input_tokens", "\(turn.inputTokens ?? 0)")
                metaRow("output_tokens", "\(turn.outputTokens ?? 0)")
                HStack(alignment: .top, spacing: 8) {
                    Text("cache_read_input_tokens")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 200, alignment: .leading)
                    Text("\(turn.cacheReadInputTokens ?? 0)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle((turn.cacheReadInputTokens ?? 0) > 0 ? Color.green : Color.orange)
                        .textSelection(.enabled)
                }
                metaRow("cache_creation_input_tokens", "\(turn.cacheCreationInputTokens ?? 0)")
                metaRow("cache_hit_ratio", Self.cacheHitRatioString(turn))
                if !turn.toolCalls.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Tool calls (\(turn.toolCalls.count))")
                        .font(.caption.weight(.semibold))
                    ForEach(turn.toolCalls) { call in
                        toolCallRow(call)
                    }
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } label: {
            HStack(spacing: 8) {
                Text("turn \(turn.turnIndex)")
                    .font(.caption.weight(.semibold))
                    .frame(width: 56, alignment: .leading)
                Text(turn.stopReason ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                cacheBadge(turn)
                Text("in \(turn.inputTokens ?? 0) / out \(turn.outputTokens ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(turn.toolCalls.count) tool\(turn.toolCalls.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// cache_read / (cache_read + cache_creation + uncached input).
    /// 0.65+ on turn 3 confirms the rolling-breakpoint strategy is working.
    static func cacheHitRatioString(_ turn: HarnessTurnRecord) -> String {
        let read = Double(turn.cacheReadInputTokens ?? 0)
        let create = Double(turn.cacheCreationInputTokens ?? 0)
        let input = Double(turn.inputTokens ?? 0)
        let denom = read + create + input
        guard denom > 0 else { return "—" }
        let pct = (read / denom) * 100
        return String(format: "%.1f%% (%.0f / %.0f)", pct, read, denom)
    }

    private func cacheBadge(_ turn: HarnessTurnRecord) -> some View {
        let read = turn.cacheReadInputTokens ?? 0
        let create = turn.cacheCreationInputTokens ?? 0
        let (label, color): (String, Color)
        if read > 0 {
            label = "cache hit \(read)"
            color = .green
        } else if create > 0 {
            label = "cache write \(create)"
            color = .blue
        } else {
            label = "no cache"
            color = .orange
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func toolCallRow(_ call: HarnessTurnRecord.ToolCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(call.name)
                    .font(.caption.weight(.semibold))
                if let action = call.action {
                    Text(action)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.16))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Spacer()
                if call.resultIsError {
                    Text("ERROR")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.18))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
            }
            Text(call.inputSummary)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .foregroundStyle(.secondary)
            if !call.resultTextPreview.isEmpty {
                Text(call.resultTextPreview)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(call.resultIsError ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(6)
        .background(Color.gray.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

@MainActor
final class ContextDebugHarnessViewModel: ObservableObject {
    @Published private(set) var runs: [HarnessRunDetail] = []
    @Published private(set) var lastRefresh: Date?

    private var pollTask: Task<Void, Never>?

    func start() async {
        await refresh()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let fetched = await HarnessRunDetailStore.shared.recentRuns(limit: 5)
        self.runs = fetched
        self.lastRefresh = Date()
    }
}
