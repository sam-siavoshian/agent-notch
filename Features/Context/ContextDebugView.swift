//
//  ContextDebugView.swift
//  Agent in the Notch
//
//  Live inspection surface for the native context and UI-memory system.
//

import AppKit
import SwiftUI

struct ContextDebugView: View {
    @State var diagnosticsSummary = "Loading context..."
    @State var diagnostics: ContextDiagnostics?
    @State var snapshots: [ContextDebugSnapshot] = []
    @State var aiSummary: ContextAIObservationSummary?
    @State var aiEvents: [ContextAIObservationEvent] = []
    @State var memories: [ContextAppMemory] = []
    @State var activationPreview = ""
    @State var performanceReport = ""
    @State var status = ""
    @State var mode: ContextDebugMode = .overview
    @State var isGatheringPaused = false

    var geminiStatus: String {
        ContextGeminiObservationService.isAPIKeyConfigured
            ? "Gemini 3.1 Flash Lite: live"
            : "Gemini 3.1 Flash Lite: waiting for key"
    }

    var gatheringStatus: String {
        isGatheringPaused ? "Gathering paused" : "Gathering live"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusStrip

            HStack(alignment: .top, spacing: 12) {
                sidebar
                    .frame(width: 230)

                contentPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
        }
        .padding(2)
        .task {
            await refreshLoop()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Context Dev Tools", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("See the exact context packet, screenshots, OCR, Gemini inputs/outputs, and learned UI memory.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            statusPill(geminiStatus, color: ContextGeminiObservationService.isAPIKeyConfigured ? .green : .yellow)
            statusPill(gatheringStatus, color: isGatheringPaused ? .yellow : .green)

            iconButton(
                isGatheringPaused ? "play.fill" : "pause.fill",
                help: isGatheringPaused ? "Resume automatic context gathering" : "Pause automatic context gathering"
            ) {
                Task { await toggleGatheringPause() }
            }

            iconButton("camera.metering.center.weighted", help: "Capture current screen now") {
                Task { await captureNow() }
            }

            iconButton("rectangle.2.swap", help: "Compare latest screenshot across Gemini model configs") {
                Task { await compareLatestScreenshot() }
            }

            iconButton("arrow.clockwise", help: "Refresh context debug panel") {
                Task { await refresh() }
            }

            iconButton("folder", help: "Open learned UI memory folder") {
                openDirectory(ContextMemoryStore.defaultDirectoryURL)
            }

            iconButton("shippingbox", help: "Open Gemini prompt/response cache") {
                openDirectory(ContextGeminiObservationService.defaultCacheDirectoryURL)
            }

            iconButton("waveform.path.ecg", help: "Open AI observation log folder") {
                openDirectory(ContextAIObservationLog.defaultDirectoryURL)
            }

            iconButton("photo.stack", help: "Open persisted capture artifacts") {
                openDirectory(ContextDebugArtifactStore.defaultDirectoryURL)
            }
        }
    }

    var statusStrip: some View {
        HStack(spacing: 8) {
            metricCard(
                title: "Captures",
                value: "\(diagnostics?.snapshotCount ?? 0)",
                detail: diagnosticsSummary,
                icon: "camera.viewfinder",
                color: .cyan
            )

            metricCard(
                title: "Latest OCR",
                value: "\(diagnostics?.latestRecognizedTextCount ?? 0)",
                detail: diagnostics?.latestWindowTitle.isEmpty == false ? diagnostics?.latestWindowTitle ?? "" : "No visible text yet",
                icon: "text.viewfinder",
                color: .mint
            )

            metricCard(
                title: "Gemini",
                value: "\(aiSummary?.recentEventCount ?? 0)",
                detail: aiSummary?.statusLine ?? "No AI observations yet.",
                icon: "brain.head.profile",
                color: .purple
            )

            metricCard(
                title: "Knowledge",
                value: "\(memories.count)",
                detail: memories.first.map { "Latest: \($0.appName), \(relativeTime($0.lastSeen))" } ?? "No learned app memory yet",
                icon: "rectangle.stack.badge.person.crop",
                color: .orange
            )
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ContextDebugMode.allCases) { item in
                    Button {
                        mode = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                    .font(.caption.weight(.semibold))
                                Text(item.shortHelp)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.38))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .foregroundStyle(mode == item ? .white.opacity(0.9) : .white.opacity(0.58))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(mode == item ? Color.white.opacity(0.11) : Color.white.opacity(0.035))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(item.help)
                }
            }

            latestScreenshotPreview

            VStack(alignment: .leading, spacing: 6) {
                Text("Recent Captures")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        if snapshots.isEmpty {
                            mutedText("No captures yet.")
                        } else {
                            ForEach(snapshots.prefix(5)) { snapshot in
                                compactCaptureRow(snapshot)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(10)
        .background(panelBackground)
    }

    var contentPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(mode.label, systemImage: mode.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))

                Text(mode.help)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)

                Spacer(minLength: 8)

                iconButton("doc.on.doc", help: "Copy this pane") {
                    copy(copyText, label: mode.copyLabel)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                content
                    .padding(10)
            }
            .background(panelBackground)
        }
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .overview:
            overviewDashboard
        case .packet:
            debugText(activationPreview)
        case .captures:
            capturesInspector
        case .ai:
            aiInspector
        case .memory:
            memoryInspector
        case .report:
            debugText(performanceReport)
        }
    }

    var copyText: String {
        switch mode {
        case .overview:
            return overviewText
        case .packet:
            return activationPreview
        case .captures:
            return captureLogText
        case .ai:
            return aiLogText
        case .memory:
            return memoryLogText
        case .report:
            return performanceReport
        }
    }

    var overviewText: String {
        [
            "Context Dev Tools overview",
            diagnosticsSummary,
            aiSummary?.statusLine ?? "No AI observations yet.",
            "\(memories.count) learned app memories.",
            "",
            firstLines(activationPreview, maxLines: 24)
        ].joined(separator: "\n")
    }

    var captureLogText: String {
        if snapshots.isEmpty {
            return "No captures recorded."
        }

        return snapshots.map { snapshot in
            """
            \(snapshot.capturedAt.formatted(date: .omitted, time: .standard)) [\(snapshot.trigger.rawValue)] \(snapshot.appName) / \(snapshot.windowTitle)
            OCR \(snapshot.recognizedTextCount): \(snapshot.textPreview)
            """
        }.joined(separator: "\n\n")
    }

    var memoryLogText: String {
        if memories.isEmpty {
            return "No learned UI memory yet."
        }

        return memories.map { memory in
            ContextMemoryRenderer.markdown(for: memory)
        }.joined(separator: "\n\n---\n\n")
    }

    var aiLogText: String {
        var lines = [
            "AI observation status:",
            aiSummary?.statusLine ?? "No AI observations yet.",
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
                if let laneName = event.laneName {
                    line += " lane=\(laneName)"
                }
                if let attemptID = event.attemptID {
                    line += " attempt=\(attemptID.uuidString)"
                }
                if let confidence = event.confidence {
                    line += " confidence=\(String(format: "%.2f", confidence))"
                }
                if let summary = event.summary {
                    line += " summary=\"\(summary)\""
                }
                lines.append(line)
                appendDetails(for: event, to: &lines)
            }
        }

        return lines.joined(separator: "\n")
    }

    func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    func refresh() async {
        let diagnostics = await ContextCoordinator.shared.diagnostics()
        let recentSnapshots = await ContextCoordinator.shared.debugSnapshots(limit: 12)
        let aiSummary = await ContextCoordinator.shared.aiObservationSummary()
        let recentAIEvents = await ContextCoordinator.shared.aiObservationEvents(limit: 28)
        let appMemories = await ContextMemoryStore.shared.debugMemories(limit: 16)
        let packet = await ContextCoordinator.shared.currentActivationPreview()
        let report = ContextPerformanceReporter().markdownReport()

        await MainActor.run {
            self.diagnostics = diagnostics
            diagnosticsSummary = diagnostics.summary
            snapshots = recentSnapshots
            self.aiSummary = aiSummary
            aiEvents = recentAIEvents
            memories = appMemories
            activationPreview = packet.isEmpty ? "No activation packet available yet." : packet
            performanceReport = report
            isGatheringPaused = diagnostics.isGatheringPaused
        }
    }

    func toggleGatheringPause() async {
        let paused = ContextCoordinator.shared.toggleGatheringPaused()
        await MainActor.run {
            isGatheringPaused = paused
            status = paused
                ? "Paused automatic context gathering. Manual capture still works."
                : "Resumed automatic context gathering."
        }
        await refresh()
    }

    func captureNow() async {
        await ContextCoordinator.shared.captureCurrentScreenForDebug()
        await refresh()
        await MainActor.run {
            status = "Captured current screen and refreshed memory artifacts."
        }
    }

    func compareLatestScreenshot() async {
        await ContextCoordinator.shared.compareLatestScreenshotForDebug()
        await refresh()
        await MainActor.run {
            status = "Queued same-screenshot Gemini comparison. Check the Gemini pane for compare-* lanes."
        }
    }

    func openDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        status = "Opened \(url.lastPathComponent)."
    }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied \(label)."
    }
}

enum ContextDebugMode: String, CaseIterable, Identifiable {
    case overview
    case packet
    case captures
    case ai
    case memory
    case report

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Overview"
        case .packet: return "Injected"
        case .captures: return "Captures"
        case .ai: return "Gemini"
        case .memory: return "Memory"
        case .report: return "Metrics"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .packet: return "text.badge.checkmark"
        case .captures: return "photo.on.rectangle.angled"
        case .ai: return "brain.head.profile"
        case .memory: return "rectangle.stack.badge.person.crop"
        case .report: return "chart.xyaxis.line"
        }
    }

    var shortHelp: String {
        switch self {
        case .overview: return "System health"
        case .packet: return "Injected prompt"
        case .captures: return "Screens + OCR"
        case .ai: return "Inputs + outputs"
        case .memory: return "Learned UI"
        case .report: return "Raw metrics"
        }
    }

    var help: String {
        switch self {
        case .overview: return "Show the full context pipeline at a glance."
        case .packet: return "Show the context packet injected into the computer-use agent."
        case .captures: return "Show screenshots, triggers, OCR counts, and visual previews."
        case .ai: return "Show Gemini queue, skip, cache, live, latency, prompt paths, raw responses, and output telemetry."
        case .memory: return "Show learned app surfaces, controls, affordances, transitions, and negative memory."
        case .report: return "Show local capture, memory, and run metrics."
        }
    }

    var copyLabel: String {
        switch self {
        case .overview: return "overview"
        case .packet: return "activation packet"
        case .captures: return "capture log"
        case .ai: return "AI call log"
        case .memory: return "learned memory"
        case .report: return "performance report"
        }
    }
}
