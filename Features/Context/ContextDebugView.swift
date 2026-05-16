//
//  ContextDebugView.swift
//  Agent in the Notch
//
//  Live inspection surface for the native context and UI-memory system.
//

import AppKit
import SwiftUI

struct ContextDebugView: View {
    @State private var diagnosticsSummary = "Loading context..."
    @State private var snapshots: [ContextDebugSnapshot] = []
    @State private var aiEvents: [ContextAIObservationEvent] = []
    @State private var activationPreview = ""
    @State private var performanceReport = ""
    @State private var aiStatus = "No AI observations yet."
    @State private var status = ""
    @State private var mode: ContextDebugMode = .packet

    private var geminiStatus: String {
        ContextGeminiObservationService.isAPIKeyConfigured
            ? "Gemini 3.1 Flash Lite: live"
            : "Gemini 3.1 Flash Lite: waiting for key"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(diagnosticsSummary)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)

            HStack(alignment: .top, spacing: 10) {
                recentCaptureList
                    .frame(width: 225)

                inspector
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .task {
            await refreshLoop()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Context", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))

            Text(geminiStatus)
                .font(.caption2.weight(.medium))
                .foregroundStyle(ContextGeminiObservationService.isAPIKeyConfigured ? .green.opacity(0.9) : .yellow.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                )

            Spacer(minLength: 8)

            iconButton("camera.metering.center.weighted", help: "Capture current screen now") {
                Task { await captureNow() }
            }

            iconButton("arrow.clockwise", help: "Refresh context debug panel") {
                Task { await refresh() }
            }

            iconButton("folder", help: "Open learned UI memory") {
                openDirectory(ContextMemoryStore.defaultDirectoryURL)
            }

            iconButton("shippingbox", help: "Open Gemini observation cache") {
                openDirectory(ContextGeminiObservationService.defaultCacheDirectoryURL)
            }

            iconButton("waveform.path.ecg", help: "Open AI observation log") {
                openDirectory(ContextAIObservationLog.defaultDirectoryURL)
            }
        }
    }

    private var recentCaptureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Captures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

            latestScreenshotPreview

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if snapshots.isEmpty {
                        Text("No captures yet. Use the capture button or interact with the Mac.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.42))
                    } else {
                        ForEach(snapshots) { snapshot in
                            captureRow(snapshot)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    @ViewBuilder
    private var latestScreenshotPreview: some View {
        if let data = snapshots.first?.jpegData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("Latest screenshot")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55))
                        .foregroundStyle(.white.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
        } else {
            Text("No screenshot preview yet.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ContextDebugMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        Label(item.label, systemImage: item.icon)
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(mode == item ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(item.help)
                }

                Spacer(minLength: 4)

                iconButton("doc.on.doc", help: "Copy visible debug text") {
                    copy(copyText, label: mode.copyLabel)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                inspectorContent
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch mode {
        case .packet:
            debugText(activationPreview)
        case .report:
            debugText(performanceReport)
        case .ai:
            aiInspector
        }
    }

    private func debugText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var aiInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(aiStatus)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .textSelection(.enabled)

            if aiEvents.isEmpty {
                Text("No Gemini events yet. Use the camera button or interact with the Mac after configuring GEMINI_API_KEY.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .textSelection(.enabled)
            } else {
                ForEach(aiEvents) { event in
                    aiEventRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var copyText: String {
        switch mode {
        case .packet:
            return activationPreview
        case .report:
            return performanceReport
        case .ai:
            return aiLogText
        }
    }

    private var aiLogText: String {
        var lines = [
            "AI observation status:",
            aiStatus,
            "",
            "Recent AI events:"
        ]

        if aiEvents.isEmpty {
            lines.append("- No Gemini events recorded.")
        } else {
            for event in aiEvents {
                var line = "- \(event.happenedAt.formatted(date: .omitted, time: .standard)) [\(event.status.rawValue)] \(event.trigger.rawValue) \(event.appName)"
                if !event.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    line += " / \(event.windowTitle)"
                }
                line += ": \(event.reason)"
                if let latency = event.latencyMilliseconds {
                    line += " (\(latency)ms)"
                }
                if let source = event.source {
                    line += " source=\(source)"
                }
                if let confidence = event.confidence {
                    line += " confidence=\(String(format: "%.2f", confidence))"
                }
                if let summary = event.summary {
                    line += " summary=\"\(summary)\""
                }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func aiEventRow(_ event: ContextAIObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(event.status.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(event.status))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(statusColor(event.status).opacity(0.12))
                    )

                Text(event.happenedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))

                Spacer(minLength: 6)

                if let latency = event.latencyMilliseconds {
                    Text("\(latency)ms")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                }

                if let source = event.source {
                    Text(source)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                }
            }

            Text("\(event.trigger.rawValue) - \(event.appName)\(event.windowTitle.isEmpty ? "" : " - \(event.windowTitle)")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)

            if let surface = event.surfaceLabel {
                Text(surface)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }

            Text(event.summary ?? event.reason)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(3)
                .textSelection(.enabled)

            if event.status == .completed {
                Text("\(event.controlsCount) controls - \(event.affordancesCount) affordances - \(event.entitiesCount) entities\(confidenceText(event.confidence))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func captureRow(_ snapshot: ContextDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(snapshot.trigger.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                Text(snapshot.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
            }

            Text(snapshot.appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            Text(snapshot.windowTitle.isEmpty ? "Untitled window" : snapshot.windowTitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)

            let preview = snapshot.textPreview.isEmpty ? "No OCR text captured." : snapshot.textPreview
            Text("\(snapshot.recognizedTextCount) OCR: \(preview)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(2)
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.72))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .help(help)
    }

    private func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    private func refresh() async {
        let diagnostics = await ContextCoordinator.shared.diagnostics()
        let recentSnapshots = await ContextCoordinator.shared.debugSnapshots(limit: 8)
        let aiSummary = await ContextCoordinator.shared.aiObservationSummary()
        let recentAIEvents = await ContextCoordinator.shared.aiObservationEvents(limit: 18)
        let packet = await ContextCoordinator.shared.currentActivationPreview()
        let report = ContextPerformanceReporter().markdownReport()

        await MainActor.run {
            diagnosticsSummary = diagnostics.summary
            snapshots = recentSnapshots
            aiStatus = aiSummary.statusLine
            aiEvents = recentAIEvents
            activationPreview = packet.isEmpty ? "No activation packet available yet." : packet
            performanceReport = report
        }
    }

    private func captureNow() async {
        await ContextCoordinator.shared.captureCurrentScreenForDebug()
        await refresh()
        await MainActor.run {
            status = "Captured current screen and refreshed memory artifacts."
        }
    }

    private func openDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        status = "Opened \(url.lastPathComponent)."
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(label)."
    }

    private func statusColor(_ eventStatus: ContextAIObservationEvent.Status) -> Color {
        switch eventStatus {
        case .queued:
            return .blue.opacity(0.9)
        case .skipped:
            return .yellow.opacity(0.9)
        case .completed:
            return .green.opacity(0.9)
        case .failed:
            return .red.opacity(0.9)
        }
    }

    private func confidenceText(_ confidence: Double?) -> String {
        guard let confidence else { return "" }
        return " - conf \(String(format: "%.2f", confidence))"
    }
}

private enum ContextDebugMode: String, CaseIterable, Identifiable {
    case packet
    case report
    case ai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .packet: return "Injected"
        case .report: return "Metrics"
        case .ai: return "AI"
        }
    }

    var icon: String {
        switch self {
        case .packet: return "text.badge.checkmark"
        case .report: return "chart.xyaxis.line"
        case .ai: return "brain.head.profile"
        }
    }

    var help: String {
        switch self {
        case .packet: return "Show the context packet injected into the computer-use agent."
        case .report: return "Show local capture, memory, and run metrics."
        case .ai: return "Show Gemini queue, skip, cache, live, latency, and output telemetry."
        }
    }

    var copyLabel: String {
        switch self {
        case .packet: return "activation packet"
        case .report: return "performance report"
        case .ai: return "AI call log"
        }
    }
}
