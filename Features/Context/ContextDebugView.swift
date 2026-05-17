//
//  ContextDebugView.swift
//  Agent in the Notch
//
//  Root view for the Dev Tools window. Sidebar + main-area dispatch with a
//  2-second polling refresh so the panes stay live without manual reloads.
//

import SwiftUI

public enum ContextDebugMode: String, CaseIterable, Identifiable {
    case newSystem, packet, captures, memory, intent, dirty, report, harness

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newSystem: return "New System"
        case .packet:   return "Brief Inspector"
        case .captures: return "Captures"
        case .memory:   return "Memory"
        case .intent:   return "Intent History"
        case .dirty:    return "Dirty Detector"
        case .report:   return "Run Metrics"
        case .harness:  return "Harness Detail"
        }
    }

    public var systemImage: String {
        switch self {
        case .newSystem: return "sparkles.square.filled.on.square"
        case .packet:   return "text.badge.checkmark"
        case .captures: return "camera.viewfinder"
        case .memory:   return "rectangle.stack.badge.person.crop"
        case .intent:   return "wand.and.stars"
        case .dirty:    return "viewfinder.circle"
        case .report:   return "chart.bar.doc.horizontal"
        case .harness:  return "bubble.left.and.bubble.right"
        }
    }
}

public struct ContextDebugView: View {
    @State var mode: ContextDebugMode = .newSystem
    @State var snapshots: [ContextSnapshot] = []
    @State var activationPreview: String = ""
    @State var diagnostics: ContextDiagnostics?
    @State var isPaused: Bool = false
    @State var lastRefreshed: Date = .distantPast
    @State private var refreshTick: Int = 0

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: refreshTick) {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    private var sidebar: some View {
        List(ContextDebugMode.allCases, selection: $mode) { entry in
            Label(entry.title, systemImage: entry.systemImage)
                .tag(entry)
        }
        .navigationTitle("Dev Tools")
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    let paused = await ContextCoordinator.shared.toggleGatheringPaused()
                    await MainActor.run { self.isPaused = paused }
                }
            } label: {
                Label(isPaused ? "Resume gathering" : "Pause gathering",
                      systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .help(isPaused ? "Resume context gathering" : "Pause context gathering")

            Button {
                refreshTick &+= 1
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Force-refresh all panes")

            Spacer()

            statusPill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusPill: some View {
        let stateLabel: String = {
            guard let diagnostics else { return isPaused ? "Paused" : "Live" }
            return diagnostics.isGatheringPaused ? "Paused" : "Live"
        }()
        let snapCount = diagnostics?.snapshotCount ?? snapshots.count
        let timeText: String = {
            guard lastRefreshed > .distantPast else { return "—" }
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return formatter.string(from: lastRefreshed)
        }()
        return HStack(spacing: 6) {
            Circle()
                .fill((diagnostics?.isGatheringPaused ?? isPaused) ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text("\(stateLabel) · \(snapCount) snapshots · refreshed \(timeText)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .newSystem: ContextDebugNewSystemView()
        case .packet:   packetPane
        case .captures: capturesPane
        case .memory:   memoryPane
        case .intent:   intentPane
        case .dirty:    dirtyPane
        case .report:   reportPane
        case .harness:  harnessPane
        }
    }

    private func refresh() async {
        async let snaps = ContextCoordinator.shared.recentSnapshots()
        async let preview = ContextCoordinator.shared.currentActivationPreview()
        async let diag = ContextCoordinator.shared.diagnostics()

        let snapsValue = await snaps
        let previewValue = await preview
        let diagValue = await diag

        await MainActor.run {
            self.snapshots = snapsValue
            self.activationPreview = previewValue
            self.diagnostics = diagValue
            self.isPaused = diagValue.isGatheringPaused
            self.lastRefreshed = Date()
        }
    }
}

enum ContextDebugFormat {
    static func relativeTimestamp(_ date: Date, reference: Date = Date()) -> String {
        let interval = reference.timeIntervalSince(date)
        if interval < 1 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    static func absoluteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
