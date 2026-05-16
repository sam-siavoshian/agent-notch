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
    @State private var diagnostics: ContextDiagnostics?
    @State private var snapshots: [ContextDebugSnapshot] = []
    @State private var aiSummary: ContextAIObservationSummary?
    @State private var aiEvents: [ContextAIObservationEvent] = []
    @State private var memories: [ContextAppMemory] = []
    @State private var activationPreview = ""
    @State private var performanceReport = ""
    @State private var status = ""
    @State private var mode: ContextDebugMode = .overview
    @State private var isGatheringPaused = false

    private var geminiStatus: String {
        ContextGeminiObservationService.isAPIKeyConfigured
            ? "Gemini 3.1 Flash Lite: live"
            : "Gemini 3.1 Flash Lite: waiting for key"
    }

    private var gatheringStatus: String {
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

    private var header: some View {
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

    private var statusStrip: some View {
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

    private var sidebar: some View {
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

    private var contentPanel: some View {
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
    private var content: some View {
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

    private var overviewDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pipeline") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                    pipelineCard("1. Capture", "\(snapshots.count) recent", "Screenshots stored with trigger, app, window, cursor, and OCR.", "camera.viewfinder", .cyan)
                    pipelineCard("2. OCR", "\(diagnostics?.latestRecognizedTextCount ?? 0) latest", "Vision text recognition produces the local text layer before AI.", "text.viewfinder", .mint)
                    pipelineCard("3. Gemini", aiSummary?.latestStatusLine ?? "No AI observation yet", "Prompt/response paths are kept for inspecting input/output quality.", "brain.head.profile", .purple)
                    pipelineCard("4. Memory", "\(memories.count) apps", "Durable UI knowledge is merged into app memories for future context packets.", "rectangle.stack.badge.person.crop", .orange)
                    pipelineCard("5. Injection", "\(activationPreview.count) chars", "This is the packet the computer-use agent sees at activation.", "text.badge.checkmark", .green)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                section("Latest Screen") {
                    VStack(alignment: .leading, spacing: 8) {
                        latestScreenshotPreview
                        if let latest = snapshots.first {
                            captureMetadata(latest)
                            Text(latest.textPreview.isEmpty ? "No useful OCR preview." : latest.textPreview)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(4)
                                .textSelection(.enabled)
                        } else {
                            mutedText("No screenshot captured yet.")
                        }
                    }
                }

                section("Latest Gemini Output") {
                    if let event = aiEvents.first(where: { $0.status == .completed }) {
                        aiEventSummary(event)
                    } else {
                        mutedText("No completed Gemini observation yet.")
                    }
                }
            }

            section("Injected Context Preview") {
                debugText(firstLines(activationPreview, maxLines: 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var capturesInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshots.isEmpty {
                mutedText("No captures yet. Use the camera button or interact with the Mac while gathering is live.")
            } else {
                ForEach(snapshots) { snapshot in
                    captureCard(snapshot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var aiInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(aiSummary?.statusLine ?? "No AI observations yet.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .textSelection(.enabled)

            if aiEvents.isEmpty {
                mutedText("No Gemini events yet. Use the camera button or interact with the Mac after configuring GEMINI_API_KEY.")
            } else {
                ForEach(aiEvents) { event in
                    aiEventRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var memoryInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if memories.isEmpty {
                mutedText("No app memory yet. Capture screens with OCR/Gemini enabled and this pane will show learned surfaces, controls, transitions, and negative memory.")
            } else {
                ForEach(memories, id: \.appName) { memory in
                    memoryCard(memory)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var latestScreenshotPreview: some View {
        if let data = snapshots.first?.jpegData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 115)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("Latest screenshot")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.58))
                        .foregroundStyle(.white.opacity(0.84))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(6)
                }
        } else {
            mutedText("No screenshot preview yet.")
                .frame(maxWidth: .infinity, minHeight: 78)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
        }
    }

    private func metricCard(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color.opacity(0.9))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 2)
            }

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(color.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func pipelineCard(_ title: String, _ value: String, _ detail: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color.opacity(0.86))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
                Spacer(minLength: 2)
            }

            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(4)
        }
        .padding(10)
        .frame(minHeight: 116, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func captureCard(_ snapshot: ContextDebugSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = NSImage(data: snapshot.jpegData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 86)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                captureMetadata(snapshot)
                Text(snapshot.textPreview.isEmpty ? "No useful OCR text captured." : snapshot.textPreview)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(9)
        .background(rowBackground)
    }

    private func captureMetadata(_ snapshot: ContextDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusPill(snapshot.trigger.rawValue, color: .cyan)
                Text(snapshot.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                Text("\(snapshot.recognizedTextCount) OCR")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
            }

            Text(snapshot.appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)

            Text(snapshot.windowTitle.isEmpty ? "Untitled window" : snapshot.windowTitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
        }
    }

    private func compactCaptureRow(_ snapshot: ContextDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                statusPill(snapshot.trigger.rawValue, color: .cyan)
                Text(relativeTime(snapshot.capturedAt))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Text(snapshot.appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Text(snapshot.textPreview.isEmpty ? "No useful OCR preview." : snapshot.textPreview)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(2)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private func aiEventSummary(_ event: ContextAIObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                statusPill(event.status.rawValue, color: statusColor(event.status))
                if let latency = event.latencyMilliseconds {
                    statusPill("\(latency)ms", color: .blue)
                }
                if let confidence = event.confidence {
                    statusPill("conf \(String(format: "%.2f", confidence))", color: .green)
                }
            }

            detailLine("Surface", event.surfaceLabel)
            detailLine("Task", event.primaryTask)
            detailLine("Summary", event.summary)
            detailList("Controls", event.controls)
            detailList("Affordances", event.affordances)
            detailList("Memory candidates", event.memoryCandidates)
        }
    }

    private func aiEventRow(_ event: ContextAIObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                statusPill(event.status.rawValue.uppercased(), color: statusColor(event.status))
                Text(event.happenedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))

                Spacer(minLength: 6)

                if let latency = event.latencyMilliseconds {
                    statusPill("\(latency)ms", color: .blue)
                }

                if let source = event.source {
                    statusPill(source, color: source == ContextGeminiObservation.Source.cache.rawValue ? .orange : .green)
                }
            }

            Text("\(event.trigger.rawValue) - \(event.appName)\(event.windowTitle.isEmpty ? "" : " - \(event.windowTitle)")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)

            Text(primaryEventText(event))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(4)
                .textSelection(.enabled)

            if event.status == .completed {
                Text("\(event.controlsCount) controls - \(event.affordancesCount) affordances - \(event.entitiesCount) entities\(confidenceText(event.confidence))\(imageText(event))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }

            VStack(alignment: .leading, spacing: 4) {
                detailLine("Model", event.model)
                detailLine("Prompt version", event.promptVersion)
                detailLine("Surface", event.surfaceLabel)
                detailLine("Screen type", event.screenType)
                detailLine("Task", event.primaryTask)
                detailLine("Layout", event.layoutSummary)
                detailLine("Content", event.contentSummary)
                detailList("Controls", event.controls)
                detailList("Landmarks", event.landmarks)
                detailList("State", event.stateIndicators)
                detailList("Navigation", event.navigationPaths)
                detailList("Data", event.dataRegions)
                detailList("Workflow", event.workflowHints)
                detailList("Memory", event.memoryCandidates)
                detailList("Entities", event.entities)
                detailList("Affordances", event.affordances)
                detailList("Negative", event.negativeCues)
                detailList("Uncertain", event.uncertainty)
                detailLine("Image hash", event.imageHash)
                detailLine("Capture image", event.captureImagePath)
                detailLine("Capture JSON", event.captureJSONPath)
                detailLine("Prompt", event.promptPath)
                detailLine("Raw response", event.rawResponsePath)
                detailLine("Error", event.errorPath)
            }
        }
        .padding(9)
        .background(rowBackground)
    }

    private func memoryCard(_ memory: ContextAppMemory) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .foregroundStyle(.orange.opacity(0.86))
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.appName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("First seen \(relativeTime(memory.firstSeen)) - last seen \(relativeTime(memory.lastSeen))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer(minLength: 6)
                statusPill("\(memory.surfaces.count) surfaces", color: .orange)
                statusPill("\(memory.transitions.count) transitions", color: .cyan)
                statusPill("\(memory.negativeNotes.count) negative", color: .yellow)
            }

            if memory.surfaces.isEmpty {
                mutedText("No surfaces learned yet.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(memory.surfaces.sorted { $0.lastSeen > $1.lastSeen }.prefix(4)) { surface in
                        surfaceMemoryRow(surface)
                    }
                }
            }

            if !memory.transitions.isEmpty {
                detailList(
                    "Transitions",
                    memory.transitions
                        .sorted { $0.lastSeen > $1.lastSeen }
                        .prefix(6)
                        .map { "\($0.fromTitle) -> \($0.toTitle) via \($0.trigger.rawValue) (\($0.evidenceCount)x)" }
                )
            }

            if !memory.negativeNotes.isEmpty {
                detailList(
                    "Negative memory",
                    memory.negativeNotes
                        .sorted { $0.lastSeen > $1.lastSeen }
                        .prefix(6)
                        .map { "\($0.surfaceTitle): \($0.note) (\($0.evidenceCount)x)" }
                )
            }
        }
        .padding(10)
        .background(rowBackground)
    }

    private func surfaceMemoryRow(_ surface: ContextSurfaceMemory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(surface.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
                statusPill("\(surface.observationCount)x", color: .white)
                if surface.clickCount > 0 {
                    statusPill("\(surface.clickCount) clicks", color: .cyan)
                }
                if surface.activationCount > 0 {
                    statusPill("\(surface.activationCount) activations", color: .green)
                }
            }

            detailList("UI facts", surface.semanticHighlights)
            detailList("Controls", surface.controlHighlights)
            detailList("Affordances", surface.affordanceHighlights)
            detailList("Text", surface.textHighlights)
            detailList("Uncertain", surface.uncertaintyHighlights)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.032))
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func debugText(_ text: String) -> some View {
        Text(text.isEmpty ? "Nothing to show yet." : text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func mutedText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.42))
            .textSelection(.enabled)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 25)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.74))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .help(help)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            )
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.045), lineWidth: 1)
            )
    }

    private var copyText: String {
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

    private var overviewText: String {
        [
            "Context Dev Tools overview",
            diagnosticsSummary,
            aiSummary?.statusLine ?? "No AI observations yet.",
            "\(memories.count) learned app memories.",
            "",
            firstLines(activationPreview, maxLines: 24)
        ].joined(separator: "\n")
    }

    private var captureLogText: String {
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

    private var memoryLogText: String {
        if memories.isEmpty {
            return "No learned UI memory yet."
        }

        return memories.map { memory in
            ContextMemoryRenderer.markdown(for: memory)
        }.joined(separator: "\n\n---\n\n")
    }

    private var aiLogText: String {
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

    private func refreshLoop() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    private func refresh() async {
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

    private func toggleGatheringPause() async {
        let paused = ContextCoordinator.shared.toggleGatheringPaused()
        await MainActor.run {
            isGatheringPaused = paused
            status = paused
                ? "Paused automatic context gathering. Manual capture still works."
                : "Resumed automatic context gathering."
        }
        await refresh()
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

    private func primaryEventText(_ event: ContextAIObservationEvent) -> String {
        if let summary = event.summary, !summary.isEmpty {
            return summary
        }
        return event.reason
    }

    private func statusColor(_ eventStatus: ContextAIObservationEvent.Status) -> Color {
        switch eventStatus {
        case .queued:
            return .blue
        case .skipped:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func confidenceText(_ confidence: Double?) -> String {
        guard let confidence else { return "" }
        return " - conf \(String(format: "%.2f", confidence))"
    }

    private func imageText(_ event: ContextAIObservationEvent) -> String {
        var parts: [String] = []
        if let imageBytes = event.imageBytes {
            parts.append("\(imageBytes / 1024)KB img")
        }
        if let ocrCount = event.ocrCount {
            parts.append("\(ocrCount) OCR")
        }
        return parts.isEmpty ? "" : " - \(parts.joined(separator: ", "))"
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func firstLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n..."
    }

    @ViewBuilder
    private func detailLine(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("\(label): \(value)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func detailList(_ label: String, _ values: [String]?) -> some View {
        let cleanValues = (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanValues.isEmpty {
            Text("\(label): \(cleanValues.prefix(10).joined(separator: " | "))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(5)
                .textSelection(.enabled)
        }
    }

    private func appendDetails(for event: ContextAIObservationEvent, to lines: inout [String]) {
        append("screenType", event.screenType, to: &lines)
        append("primaryTask", event.primaryTask, to: &lines)
        append("layoutSummary", event.layoutSummary, to: &lines)
        append("contentSummary", event.contentSummary, to: &lines)
        append("controls", event.controls, to: &lines)
        append("landmarks", event.landmarks, to: &lines)
        append("stateIndicators", event.stateIndicators, to: &lines)
        append("navigationPaths", event.navigationPaths, to: &lines)
        append("dataRegions", event.dataRegions, to: &lines)
        append("workflowHints", event.workflowHints, to: &lines)
        append("memoryCandidates", event.memoryCandidates, to: &lines)
        append("entities", event.entities, to: &lines)
        append("affordances", event.affordances, to: &lines)
        append("negativeCues", event.negativeCues, to: &lines)
        append("uncertainty", event.uncertainty, to: &lines)
        append("imageHash", event.imageHash, to: &lines)
        append("captureImagePath", event.captureImagePath, to: &lines)
        append("captureJSONPath", event.captureJSONPath, to: &lines)
        append("promptPath", event.promptPath, to: &lines)
        append("rawResponsePath", event.rawResponsePath, to: &lines)
        append("errorPath", event.errorPath, to: &lines)
    }

    private func append(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append("  \(label): \(value)")
    }

    private func append(_ label: String, _ values: [String]?, to lines: inout [String]) {
        let cleanValues = (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanValues.isEmpty else { return }
        lines.append("  \(label):")
        for value in cleanValues.prefix(16) {
            lines.append("    - \(value)")
        }
    }
}

private enum ContextDebugMode: String, CaseIterable, Identifiable {
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
