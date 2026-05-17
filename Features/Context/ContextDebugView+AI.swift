//
//  ContextDebugView+AI.swift
//  Agent in the Notch
//
//  Dev Tools "AI" pane: live feed of Gemini observation events with filters
//  and per-event drill-in. Reads ContextAIObservationLog.shared every 2s.
//

import SwiftUI

// MARK: - Pane root

struct ContextDebugAIView: View {
    @StateObject private var model = ContextDebugAIViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            countsRow
            Divider()
            list
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
            Text("Gemini Events")
                .font(.headline)
            Spacer()
            if let lastRefresh = model.lastRefresh {
                Text("Updated \(Self.timeFormatter.string(from: lastRefresh))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                Task { await model.clearLog() }
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Hide skipped", isOn: $model.hideSkipped)
                Toggle("Hide queued", isOn: $model.hideQueued)
                Toggle("Hide failed", isOn: $model.hideFailed)
                Spacer()
                Picker("Window", selection: $model.windowMinutes) {
                    Text("5m").tag(5)
                    Text("15m").tag(15)
                    Text("60m").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .toggleStyle(.checkbox)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Lanes:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ContextDebugAIViewModel.knownLanes, id: \.self) { lane in
                        let active = model.activeLanes.contains(lane)
                        Button {
                            model.toggleLane(lane)
                        } label: {
                            Text(lane)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(active ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.12))
                                .foregroundStyle(active ? Color.accentColor : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if !model.activeLanes.isEmpty {
                        Button("Clear") { model.clearLaneFilter() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var countsRow: some View {
        let counts = model.countsSummary
        return Text(counts.isEmpty ? "No events yet." : counts)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private var list: some View {
        Group {
            if model.filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.filtered, id: \.id) { event in
                            ContextAIEventRow(event: event)
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No Gemini events match the current filters.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - Row

private struct ContextAIEventRow: View {
    let event: ContextAIObservationEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                Text(Self.timeFormatter.string(from: event.happenedAt))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)

                statusPill
                lanePill

                Text(appLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)

                if let ms = event.latencyMilliseconds {
                    Text("\(ms)ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }

                Text(event.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                expansion
                    .padding(.leading, 22)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var appLabel: String {
        let window = event.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if window.isEmpty { return event.appName }
        return "\(event.appName) — \(window)"
    }

    private var statusPill: some View {
        let (color, label) = Self.statusStyle(event.status)
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .frame(width: 80, alignment: .leading)
    }

    private var lanePill: some View {
        let lane = event.laneName ?? "—"
        return Text(lane)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.16))
            .clipShape(Capsule())
            .frame(width: 120, alignment: .leading)
    }

    private static func statusStyle(_ status: ContextAIObservationEvent.Status) -> (Color, String) {
        switch status {
        case .queued: return (.blue, "queued")
        case .skipped: return (.yellow, "skipped")
        case .completed: return (.green, "completed")
        case .failed: return (.red, "failed")
        }
    }

    @ViewBuilder
    private var expansion: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaRow("model", event.model)
            metaRow("promptVersion", event.promptVersion)
            metaRow("trigger", event.trigger.rawValue)
            if let s = event.source { metaRow("source", s) }
            if let bytes = event.imageBytes { metaRow("imageBytes", formatBytes(bytes)) }
            if let m = event.requestMimeType { metaRow("requestMimeType", m) }
            if let r = event.requestMediaResolution { metaRow("mediaResolution", r) }
            if let t = event.requestThinkingLevel { metaRow("thinkingLevel", t) }
            if let o = event.ocrCount { metaRow("ocrCount", "\(o)") }

            if event.status == .completed {
                Divider().padding(.vertical, 2)
                if let surface = event.surfaceLabel { metaRow("surfaceLabel", surface) }
                if let summary = event.summary { metaRow("summary", summary) }
                if let st = event.screenType { metaRow("screenType", st) }
                if let pt = event.primaryTask { metaRow("primaryTask", pt) }
                if let ls = event.layoutSummary { metaRow("layoutSummary", ls) }
                if let cs = event.contentSummary { metaRow("contentSummary", cs) }
                metaRow("controlsCount", "\(event.controlsCount)")
                metaRow("affordancesCount", "\(event.affordancesCount)")
                metaRow("entitiesCount", "\(event.entitiesCount)")
                if let conf = event.confidence {
                    metaRow("confidence", String(format: "%.0f%%", conf * 100))
                }
            }
        }
        .font(.caption)
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024.0)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - View model

@MainActor
final class ContextDebugAIViewModel: ObservableObject {
    static let knownLanes: [String] = [
        "activity", "uiMap", "entityContent", "interaction",
        "reducer", "update", "modular", "dirty-detector"
    ]

    @Published var hideSkipped = false
    @Published var hideQueued = false
    @Published var hideFailed = false
    @Published var activeLanes: Set<String> = []
    @Published var windowMinutes: Int = 15
    @Published private(set) var events: [ContextAIObservationEvent] = []
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
        let fetched = await ContextAIObservationLog.shared.recentEvents(limit: 200)
        self.events = fetched
        self.lastRefresh = Date()
    }

    func clearLog() async {
        await ContextAIObservationLog.shared.clear()
        await refresh()
    }

    func toggleLane(_ lane: String) {
        if activeLanes.contains(lane) {
            activeLanes.remove(lane)
        } else {
            activeLanes.insert(lane)
        }
    }

    func clearLaneFilter() {
        activeLanes.removeAll()
    }

    var filtered: [ContextAIObservationEvent] {
        let cutoff = Date().addingTimeInterval(-Double(windowMinutes) * 60)
        return events.filter { event in
            if event.happenedAt < cutoff { return false }
            if hideSkipped && event.status == .skipped { return false }
            if hideQueued && event.status == .queued { return false }
            if hideFailed && event.status == .failed { return false }
            if !activeLanes.isEmpty {
                let lane = event.laneName ?? ""
                if !activeLanes.contains(lane) { return false }
            }
            return true
        }
    }

    var countsSummary: String {
        guard !filtered.isEmpty else { return "" }
        var completedByLane: [String: Int] = [:]
        var failed = 0
        var skipped = 0
        var queued = 0
        for event in filtered {
            switch event.status {
            case .completed:
                let lane = event.laneName ?? "—"
                completedByLane[lane, default: 0] += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            case .queued: queued += 1
            }
        }
        let completedPart: String
        if completedByLane.isEmpty {
            completedPart = "completed: 0"
        } else {
            let sorted = completedByLane.sorted { $0.key < $1.key }
            completedPart = "completed: " + sorted.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        return "\(completedPart)  |  failed: \(failed)  |  skipped: \(skipped)  |  queued: \(queued)"
    }
}
