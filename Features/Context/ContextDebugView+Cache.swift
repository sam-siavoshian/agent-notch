//
//  ContextDebugView+Cache.swift
//  Agent in the Notch
//
//  Dev Tools pane: Gemini per-lane cachedContents state. Counters at the
//  top, one row per lane below, with invalidate + refresh actions.
//

import SwiftUI

struct ContextDebugCachePane: View {
    @StateObject private var model = CachePaneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            table
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Gemini cache")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Invalidate all") {
                    Task { await model.invalidateAll() }
                }
                .buttonStyle(.bordered)
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 14) {
                CacheCounter(label: "hits", value: "\(model.counters.hitCount)", color: .green)
                CacheCounter(label: "misses", value: "\(model.counters.missCount)", color: .yellow)
                CacheCounter(label: "rejected", value: "\(model.counters.permanentRejectCount)", color: .red)
                CacheCounter(label: "hit rate", value: String(format: "%.0f%%", model.counters.hitRate * 100), color: .accentColor)
            }
            if ContextGeminiCacheManager.isDisabled {
                Text("Cache is disabled via AGENTNOTCH_GEMINI_DISABLE_CACHE.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            CacheRowHeader()
            Divider()
            ForEach(model.lanes, id: \.lane) { lane in
                CacheRow(state: lane)
                Divider().opacity(0.4)
            }
            if model.lanes.isEmpty {
                Text("No lanes registered yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
        }
    }
}

private struct CacheCounter: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct CacheRowHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Lane")
                .frame(width: 110, alignment: .leading)
            Text("Status")
                .frame(width: 140, alignment: .leading)
            Text("Cache name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Created")
                .frame(width: 110, alignment: .leading)
            Text("Expires in")
                .frame(width: 90, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

private struct CacheRow: View {
    let state: ContextGeminiCacheManager.LaneState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(state.lane.label)
                    .frame(width: 110, alignment: .leading)
                CacheStatusPill(status: state.status)
                    .frame(width: 140, alignment: .leading)
                Text(displayName)
                    .font(.callout.monospaced())
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(createdRelative)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(expiresLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
            }
            if state.status == .permanentlyRejected {
                Text("Instruction too small to cache (Gemini requires ≥1024 tokens).")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.leading, 122)
            }
        }
        .padding(.vertical, 8)
    }

    private var displayName: String {
        guard let name = state.name, !name.isEmpty else { return "—" }
        if name.count > 36 {
            let prefix = name.prefix(18)
            let suffix = name.suffix(12)
            return "\(prefix)…\(suffix)"
        }
        return name
    }

    private var createdRelative: String {
        guard let createdAt = state.createdAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    private var expiresLabel: String {
        guard let seconds = state.expiresInSeconds else { return "—" }
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}

private struct CacheStatusPill: View {
    let status: ContextGeminiCacheManager.CacheStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .active: return .green
        case .permanentlyRejected: return .red
        case .none: return .secondary
        }
    }
}

@MainActor
private final class CachePaneModel: ObservableObject {
    @Published private(set) var lanes: [ContextGeminiCacheManager.LaneState] = []
    @Published private(set) var counters = ContextGeminiCacheManager.Counters(
        hitCount: 0,
        missCount: 0,
        permanentRejectCount: 0
    )

    private var timer: Timer?

    func start() async {
        await refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        let lanes = await ContextGeminiCacheManager.shared.state()
        let counters = await ContextGeminiCacheManager.shared.counters()
        self.lanes = lanes
        self.counters = counters
    }

    func invalidateAll() async {
        await ContextGeminiCacheManager.shared.invalidateAll()
        await refresh()
    }
}
