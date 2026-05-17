//
//  ContextDebugView+Mercury.swift
//  Agent in the Notch
//
//  Filtered slice of `AgentObservabilityLog` showing every Mercury call —
//  selector, active_task_updater, recipe_naming, or other — newest first.
//  Each row exposes the request + response previews so the operator can
//  diff what we sent against what we got back.
//

import SwiftUI

/// Every Mercury call captured in the observability log, newest first.
/// Shows role, latency, success, request/response previews.
public struct ContextDebugMercuryView: View {
    @State private var calls: [AgentObservabilityLog.Event] = []
    @State private var refreshTimer: Timer?

    public init() {}

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if calls.isEmpty {
                    Text("No Mercury calls yet.").foregroundColor(.secondary).padding()
                } else {
                    ForEach(calls.reversed()) { event in
                        callCard(event)
                    }
                }
            }
            .padding(12)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private func callCard(_ event: AgentObservabilityLog.Event) -> some View {
        if case let .mercuryCall(_, t, role, req, resp, latency, success, _, _) = event {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(role.rawValue).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(success ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        .cornerRadius(4)
                    Text(String(format: "%.2fs", latency)).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Text(t.formatted(.dateTime.hour().minute().second())).font(.system(size: 10)).foregroundColor(.secondary)
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
    }

    private func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }
    private func stop() { refreshTimer?.invalidate(); refreshTimer = nil }
    private func refresh() { calls = AgentObservabilityLog.shared.mercuryCalls() }
}
