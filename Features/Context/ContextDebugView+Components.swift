//
//  ContextDebugView+Components.swift
//  Agent in the Notch
//

import AppKit
import SwiftUI

extension ContextDebugView {

    func mutedText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.42))
            .textSelection(.enabled)
    }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func debugText(_ text: String) -> some View {
        Text(text.isEmpty ? "Nothing to show yet." : text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
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

    func statusPill(_ text: String, color: Color) -> some View {
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

    var panelBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            )
    }

    var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.045), lineWidth: 1)
            )
    }

    @ViewBuilder
    func detailLine(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("\(label): \(value)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    func detailList(_ label: String, _ values: [String]?) -> some View {
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

    func appendDetails(for event: ContextAIObservationEvent, to lines: inout [String]) {
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
        append("requestMimeType", event.requestMimeType, to: &lines)
        append("requestMediaResolution", event.requestMediaResolution, to: &lines)
        append("requestThinkingLevel", event.requestThinkingLevel, to: &lines)
        append("laneName", event.laneName, to: &lines)
        append("attemptID", event.attemptID?.uuidString, to: &lines)
        append("imageHash", event.imageHash, to: &lines)
        append("requestImagePath", event.requestImagePath, to: &lines)
        append("requestMetadataPath", event.requestMetadataPath, to: &lines)
        append("captureImagePath", event.captureImagePath, to: &lines)
        append("captureJSONPath", event.captureJSONPath, to: &lines)
        append("promptPath", event.promptPath, to: &lines)
        append("rawResponsePath", event.rawResponsePath, to: &lines)
        append("errorPath", event.errorPath, to: &lines)
    }

    func append(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append("  \(label): \(value)")
    }

    func append(_ label: String, _ values: [String]?, to lines: inout [String]) {
        let cleanValues = (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanValues.isEmpty else { return }
        lines.append("  \(label):")
        for value in cleanValues.prefix(16) {
            lines.append("    - \(value)")
        }
    }

    func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func firstLines(_ text: String, maxLines: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n..."
    }

    func fileText(_ path: String, maxCharacters: Int) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        if text.count <= maxCharacters {
            return text
        }
        let prefix = String(text.prefix(maxCharacters))
        return "\(prefix)\n\n... truncated in Dev Tools preview ..."
    }

    func primaryEventText(_ event: ContextAIObservationEvent) -> String {
        if let summary = event.summary, !summary.isEmpty {
            return summary
        }
        return event.reason
    }

    func statusColor(_ eventStatus: ContextAIObservationEvent.Status) -> Color {
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

    func confidenceText(_ confidence: Double?) -> String {
        guard let confidence else { return "" }
        return " - conf \(String(format: "%.2f", confidence))"
    }

    func imageText(_ event: ContextAIObservationEvent) -> String {
        var parts: [String] = []
        if let imageBytes = event.imageBytes {
            parts.append("\(imageBytes / 1024)KB img")
        }
        if let ocrCount = event.ocrCount {
            parts.append("\(ocrCount) OCR")
        }
        return parts.isEmpty ? "" : " - \(parts.joined(separator: ", "))"
    }
}
