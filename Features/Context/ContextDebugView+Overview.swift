//
//  ContextDebugView+Overview.swift
//  Agent in the Notch
//
//  Pipeline-summary tab: capture/OCR/Gemini/memory/injection counts plus a
//  preview of the latest snapshot and the first lines of the injected packet.
//

import SwiftUI
import AppKit

extension ContextDebugView {
    var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pipelineCards
                latestSnapshotCard
                packetPreviewCard
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var pipelineCards: some View {
        let captures = diagnostics?.snapshotCount ?? snapshots.count
        let latestOCR = diagnostics?.latestRecognizedTextCount ?? (snapshots.last?.recognizedText.count ?? 0)
        let memoryLabel = (diagnostics?.hasLearnedMemory ?? false) ? "Ready" : "Warming"
        let injectionLabel = activationPreview.isEmpty ? "Empty" : "\(activationPreview.split(separator: "\n").count) lines"

        return VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline")
                .font(.headline)
            HStack(spacing: 10) {
                summaryCard(title: "Capture", value: "\(captures)", caption: "snapshots", systemImage: "camera.viewfinder")
                summaryCard(title: "OCR", value: "\(latestOCR)", caption: "items (latest)", systemImage: "text.viewfinder")
                summaryCard(title: "Gemini", value: "—", caption: "events pending", systemImage: "brain.head.profile")
                summaryCard(title: "Memory", value: memoryLabel, caption: "learned UI", systemImage: "rectangle.stack.badge.person.crop")
                summaryCard(title: "Injection", value: injectionLabel, caption: "activation packet", systemImage: "tray.and.arrow.up")
            }
        }
    }

    private func summaryCard(title: String, value: String, caption: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var latestSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest snapshot")
                .font(.headline)
            if let latest = snapshots.last {
                HStack(alignment: .top, spacing: 12) {
                    snapshotThumbnail(latest, maxWidth: 320, maxHeight: 200)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latest.appName.isEmpty ? "Unknown app" : latest.appName)
                            .font(.system(size: 13, weight: .semibold))
                        Text(latest.windowTitle.isEmpty ? "Untitled" : latest.windowTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("Trigger: \(latest.trigger.rawValue)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Captured \(ContextDebugFormat.relativeTimestamp(latest.capturedAt)) (\(ContextDebugFormat.absoluteTimestamp(latest.capturedAt)))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("Size: \(latest.width)×\(latest.height)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        if let cursor = latest.cursorLocation {
                            Text("Cursor: x=\(Int(cursor.x)), y=\(Int(cursor.y))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text("OCR items: \(latest.recognizedText.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("No snapshots captured yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var packetPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activation packet (first 18 lines)")
                .font(.headline)
            let lines = activationPreview.split(separator: "\n", omittingEmptySubsequences: false).prefix(18)
            if lines.isEmpty {
                Text("No activation packet available yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    func snapshotThumbnail(_ snapshot: ContextSnapshot, maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        Group {
            if let image = NSImage(data: snapshot.jpegData) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .overlay(Text("No image").font(.caption).foregroundStyle(.secondary))
            }
        }
    }
}
