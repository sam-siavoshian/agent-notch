import SwiftUI
import AppKit

/// Sequential timeline of the CURRENT (or most recent) long-press → Mercury → Claude
/// agent run. Reads from `AgentObservabilityLog.shared.currentRunEvents()`.
public struct ContextDebugAgentRunView: View {
    @State private var events: [AgentObservabilityLog.Event] = []
    @State private var refreshTimer: Timer?

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if events.isEmpty {
                        Text("No agent run yet — long-press the cursor companion to start one.")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(events) { event in
                            eventCard(event)
                                .id(event.id)
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: events.count) { _, _ in
                if let last = events.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private func eventCard(_ event: AgentObservabilityLog.Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label(for: event))
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color(for: event).opacity(0.2))
                    .foregroundColor(color(for: event))
                    .cornerRadius(4)
                Spacer()
                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            cardBody(event)
        }
        .padding(10)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    private func label(for event: AgentObservabilityLog.Event) -> String {
        switch event {
        case .longPressTranscript: return "TRANSCRIPT"
        case .l2Snapshot: return "L2 SNAPSHOT"
        case .selectorRun: return "SELECTOR"
        case .mercuryCall(_, _, let role, _, _, _, _, _, _): return "MERCURY · \(role.rawValue.uppercased())"
        case .geminiCall(_, _, let model, _, _, _, _, _, _): return "GEMINI · \(model)"
        case .harnessTurn(_, _, let idx, _, _, _, _, _, _, _, _): return "CLAUDE TURN #\(idx)"
        case .memoryMutation(_, _, let kind, _): return "MEMORY · \(kind.rawValue)"
        }
    }

    private func color(for event: AgentObservabilityLog.Event) -> Color {
        switch event {
        case .longPressTranscript: return .blue
        case .l2Snapshot: return .teal
        case .selectorRun, .mercuryCall: return .purple
        case .geminiCall: return .indigo
        case .harnessTurn: return .orange
        case .memoryMutation: return .green
        }
    }

    @ViewBuilder
    private func cardBody(_ event: AgentObservabilityLog.Event) -> some View {
        switch event {
        case let .longPressTranscript(_, _, transcript):
            Text("\"\(transcript)\"").italic()
        case let .l2Snapshot(_, _, app, window, axCount, ocrCount, screenshot):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(app) — \(window ?? "(no window)")").font(.system(size: 11))
                Text("\(axCount) AX elements · \(ocrCount) OCR lines").font(.system(size: 10)).foregroundColor(.secondary)
                if let jpeg = screenshot, let nsImage = NSImage(data: jpeg) {
                    Image(nsImage: nsImage)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 200)
                        .cornerRadius(4)
                }
            }
        case let .selectorRun(_, _, latency, degraded, model, verb, target, briefLen):
            Text("\(model ?? "<local>") · \(String(format: "%.2f", latency))s · verb=\(verb) target=\(target ?? "?")\(degraded ? " · DEGRADED" : "") · brief=\(briefLen) chars")
                .font(.system(size: 11))
        case let .mercuryCall(_, _, _, req, resp, latency, success, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(String(format: "%.2f", latency))s \(success ? "✓" : "✗")").font(.system(size: 11, weight: .semibold))
                DisclosureGroup("Request") {
                    Text(req).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                DisclosureGroup("Response") {
                    Text(resp).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        case let .geminiCall(_, _, model, prompt, imageBytes, resp, latency, success, httpStatus):
            VStack(alignment: .leading, spacing: 4) {
                let statusText = httpStatus.map { " · HTTP \($0)" } ?? ""
                Text("\(model) · \(String(format: "%.2f", latency))s \(success ? "✓" : "✗")\(statusText) · \(imageBytes) image bytes")
                    .font(.system(size: 11, weight: .semibold))
                DisclosureGroup("Request") {
                    Text(prompt).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                DisclosureGroup("Response") {
                    Text(resp).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
            }
        case let .harnessTurn(_, _, _, modelID, systemPreview, userPreview, assistantPreview, toolCalls, inTok, outTok, latency):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(modelID) · \(String(format: "%.2f", latency))s · in=\(inTok ?? -1) out=\(outTok ?? -1)").font(.system(size: 10)).foregroundColor(.secondary)
                DisclosureGroup("System block (preview)") { Text(systemPreview).font(.system(size: 10, design: .monospaced)) }
                DisclosureGroup("User content (preview)") { Text(userPreview).font(.system(size: 10, design: .monospaced)) }
                DisclosureGroup("Assistant (preview)") { Text(assistantPreview).font(.system(size: 10, design: .monospaced)) }
                if !toolCalls.isEmpty {
                    DisclosureGroup("Tool calls (\(toolCalls.count))") {
                        ForEach(0..<toolCalls.count, id: \.self) { i in
                            let tc = toolCalls[i]
                            VStack(alignment: .leading, spacing: 2) {
                                Text("→ \(tc.toolName)\(tc.durationS.map { " (" + String(format: "%.2f", $0) + "s)" } ?? "")").font(.system(size: 10, weight: .semibold))
                                Text("args: \(tc.argumentsPreview)").font(.system(size: 9, design: .monospaced))
                                Text("result: \(tc.resultPreview)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }
            }
        case let .memoryMutation(_, _, _, summary):
            Text(summary).font(.system(size: 11))
        }
    }

    private func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }
    private func stop() { refreshTimer?.invalidate(); refreshTimer = nil }
    private func refresh() { events = AgentObservabilityLog.shared.currentRunEvents() }
}
