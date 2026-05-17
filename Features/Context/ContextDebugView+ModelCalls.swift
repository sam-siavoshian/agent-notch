import SwiftUI

/// Every Mercury + Gemini call captured in the observability log, newest first.
public struct ContextDebugModelCallsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, mercury, gemini
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .mercury: return "Mercury"
            case .gemini: return "Gemini"
            }
        }
    }

    @State private var calls: [AgentObservabilityLog.Event] = []
    @State private var refreshTimer: Timer?
    @State private var filter: Filter = .all

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let filtered = applyFilter(calls)
                    if filtered.isEmpty {
                        Text("No model calls yet.").foregroundColor(.secondary).padding()
                    } else {
                        ForEach(filtered) { event in
                            callCard(event)
                        }
                    }
                }
                .padding(12)
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { f in
                Button {
                    filter = f
                } label: {
                    Text(f.title)
                        .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(filter == f ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08))
                        )
                        .foregroundColor(filter == f ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(applyFilter(calls).count) calls")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func applyFilter(_ events: [AgentObservabilityLog.Event]) -> [AgentObservabilityLog.Event] {
        switch filter {
        case .all:     return events
        case .mercury: return events.filter { if case .mercuryCall = $0 { return true }; return false }
        case .gemini:  return events.filter { if case .geminiCall = $0 { return true }; return false }
        }
    }

    @ViewBuilder
    private func callCard(_ event: AgentObservabilityLog.Event) -> some View {
        switch event {
        case let .mercuryCall(_, t, role, req, resp, latency, success, _, _):
            mercuryCard(t: t, role: role, req: req, resp: resp, latency: latency, success: success)
        case let .geminiCall(_, t, model, prompt, imageBytes, resp, latency, success, httpStatus):
            geminiCard(t: t, model: model, prompt: prompt, imageBytes: imageBytes, resp: resp, latency: latency, success: success, httpStatus: httpStatus)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func mercuryCard(t: Date, role: AgentObservabilityLog.MercuryRole, req: String, resp: String, latency: Double, success: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                providerPill("MERCURY", color: .purple)
                Text(role.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(success ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(4)
                Text(String(format: "%.2fs", latency))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(t.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            DisclosureGroup("Request") {
                Text(req).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            DisclosureGroup("Response") {
                Text(resp).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func geminiCard(t: Date, model: String, prompt: String, imageBytes: Int, resp: String, latency: Double, success: Bool, httpStatus: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                providerPill("GEMINI", color: .indigo)
                Text(model)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(success ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(4)
                Text(String(format: "%.2fs", latency))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text(formatBytes(imageBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                if !success, let status = httpStatus {
                    Text("HTTP \(status)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.25))
                        .foregroundColor(.red)
                        .cornerRadius(3)
                }
                Spacer()
                Text(t.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            DisclosureGroup("Request") {
                Text(prompt).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            DisclosureGroup("Response") {
                Text(resp).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    private func providerPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(3)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B image" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1fKB image", kb) }
        let mb = kb / 1024.0
        return String(format: "%.2fMB image", mb)
    }

    private func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }
    private func stop() { refreshTimer?.invalidate(); refreshTimer = nil }
    private func refresh() {
        let merged = AgentObservabilityLog.shared.mercuryCalls() + AgentObservabilityLog.shared.geminiCalls()
        calls = merged.sorted { $0.timestamp > $1.timestamp }
    }
}
