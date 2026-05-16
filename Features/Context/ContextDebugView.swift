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
    @State private var activationPreview = ""
    @State private var performanceReport = ""
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
                    copy(mode == .packet ? activationPreview : performanceReport, label: mode.copyLabel)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(mode == .packet ? activationPreview : performanceReport)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
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
        let packet = await ContextCoordinator.shared.currentActivationPreview()
        let report = ContextPerformanceReporter().markdownReport()

        await MainActor.run {
            diagnosticsSummary = diagnostics.summary
            snapshots = recentSnapshots
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
}

private enum ContextDebugMode: String, CaseIterable, Identifiable {
    case packet
    case report

    var id: String { rawValue }

    var label: String {
        switch self {
        case .packet: return "Injected"
        case .report: return "Metrics"
        }
    }

    var icon: String {
        switch self {
        case .packet: return "text.badge.checkmark"
        case .report: return "chart.xyaxis.line"
        }
    }

    var help: String {
        switch self {
        case .packet: return "Show the context packet injected into the computer-use agent."
        case .report: return "Show local capture, memory, and run metrics."
        }
    }

    var copyLabel: String {
        switch self {
        case .packet: return "activation packet"
        case .report: return "performance report"
        }
    }
}
