//
//  ContextDebugView+Intent.swift
//  Agent in the Notch
//
//  Intent History: walks ContextSelector.shared.recentRuns (newest first)
//  and renders one row per selector run with verb, target → resolved_target,
//  confidence, degraded flag, model, and latency. Polls every 1s.
//

import SwiftUI

struct ContextDebugIntentView: View {
    @State private var runs: [ContextSelector.Result] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
            Text("Selector intent history")
                .font(.headline)
            Spacer()
            Text("\(runs.count) runs (max 20)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if runs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("No selector runs yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("Long-press the cursor companion and speak to trigger one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(runs.reversed().enumerated()), id: \.offset) { _, run in
                        IntentRow(run: run)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Refresh

    private func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        runs = ContextSelector.shared.recentRuns
    }
}

private struct IntentRow: View {
    let run: ContextSelector.Result
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Text(timeLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)

                verbPill

                Text(targetSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if run.degraded {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help("Degraded: local fallback used")
                }

                Text("\(Int(run.intent.confidence * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(run.degraded ? .orange : .secondary)
                    .frame(width: 42, alignment: .trailing)

                Text(run.modelUsed ?? "<local>")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 160, alignment: .leading)

                Text(String(format: "%.2fs", run.latencyS))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                expansion
                    .padding(.leading, 26)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var timeLabel: String {
        // recentRuns doesn't carry a wall-clock timestamp on the Result.
        // The wall-clock for "now" is more useful than nothing — but to keep
        // a stable display, show the L2 capturedAt time (which is the same
        // instant the selector started, within ~400ms).
        return Self.timeFormatter.string(from: run.l2.capturedAt)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var targetSummary: String {
        let target = run.intent.target?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = run.intent.resolvedTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (target, resolved) {
        case let (t?, r?) where !t.isEmpty && !r.isEmpty && t != r:
            return "\(t) → \(r)"
        case let (t?, _) where !t.isEmpty:
            return t
        case let (_, r?) where !r.isEmpty:
            return "→ \(r)"
        default:
            return "—"
        }
    }

    private var verbPill: some View {
        Text(run.intent.verb.isEmpty ? "?" : run.intent.verb)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
            .frame(minWidth: 60, alignment: .leading)
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Entities")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            if run.intent.entities.isEmpty {
                Text("(none)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(run.intent.entities.enumerated()), id: \.offset) { _, e in
                    let resolved = e.resolvedTo.map { " → \($0)" } ?? ""
                    Text("• \(e.label) [\(e.kind)]\(resolved)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            Text("L2")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("\(run.l2.app) — \(run.l2.windowTitle ?? "")")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Text("OCR \(run.l2.ocrLines.count) lines · AX \(run.l2.axElements.count) elements")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
