import SwiftUI
import AppKit

extension ContextDebugView {
    var packetPane: some View {
        BriefInspectorView()
    }
}

private struct BriefInspectorView: View {
    @State private var run: ContextSelector.Result?
    @State private var refreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let run {
                    header(run)
                    Divider()
                    briefSection(run)
                    Divider()
                    intentSection(run.intent)
                    Divider()
                    l2Section(run.l2)
                    if let jpeg = run.initiationScreenshot, let image = NSImage(data: jpeg) {
                        Divider()
                        screenshotSection(image)
                    }
                } else {
                    placeholder
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: - Header

    private func header(_ run: ContextSelector.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                Text("Last selector run")
                    .font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.brief, forType: .string)
                } label: {
                    Label("Copy brief", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the brief to the clipboard")
            }
            HStack(spacing: 12) {
                metricChip(label: "latency", value: String(format: "%.2fs", run.latencyS))
                metricChip(label: "model", value: run.modelUsed ?? "<local>")
                degradedChip(run.degraded)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No selector run yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Long-press the cursor companion and speak to trigger one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Brief

    private func briefSection(_ run: ContextSelector.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Brief", suffix: "\(run.brief.count) chars · \(run.brief.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
            ScrollView {
                Text(run.brief.isEmpty ? "(empty brief)" : run.brief)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 180, maxHeight: 400)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    // MARK: - Intent

    private func intentSection(_ intent: CIntent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Intent", suffix: String(format: "conf %.0f%%", intent.confidence * 100))
            VStack(alignment: .leading, spacing: 4) {
                kv("verb", intent.verb)
                kv("target", intent.target ?? "—")
                kv("resolved_target", intent.resolvedTarget ?? "—")
                if intent.entities.isEmpty {
                    kv("entities", "(none)")
                } else {
                    Text("entities")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(Array(intent.entities.enumerated()), id: \.offset) { _, e in
                        let resolved = e.resolvedTo.map { " → \($0)" } ?? ""
                        Text("  • \(e.label) [\(e.kind)]\(resolved)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
    }

    // MARK: - L2

    @State private var l2Expanded: Bool = false

    private func l2Section(_ l2: CL2Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                l2Expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: l2Expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("L2 snapshot")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(l2.ocrLines.count) OCR · \(l2.axElements.count) AX")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if l2Expanded {
                VStack(alignment: .leading, spacing: 4) {
                    kv("app", "\(l2.app) (\(l2.bundleID), pid \(l2.pid))")
                    kv("window", l2.windowTitle ?? "—")
                    kv("display", "id \(l2.displayID)")
                    kv("captured_at", l2.capturedAt.formatted(date: .omitted, time: .standard))
                    if let focused = l2.axElements.first(where: { $0.focused }) {
                        kv("focused", "\(focused.role)/\(focused.label ?? "—") @ \(focused.axPath ?? "—")")
                    } else {
                        kv("focused", "(none)")
                    }
                    if let sel = l2.selection, !sel.isEmpty {
                        kv("selection", sel.prefix(140) + (sel.count > 140 ? "…" : ""))
                    }
                    if let cb = l2.clipboard {
                        kv("clipboard", "\(cb.kind) · \(cb.bytes)B · age \(String(format: "%.1fs", cb.ageS))")
                    }
                    if let cursor = l2.cursor, cursor.count >= 2 {
                        kv("cursor", "x=\(cursor[0]), y=\(cursor[1])")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
        }
    }

    // MARK: - Screenshot

    private func screenshotSection(_ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Initiation screenshot", suffix: nil)
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 256)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    // MARK: - Small bits

    private func sectionHeader(_ title: String, suffix: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let suffix {
                Text(suffix)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func kv(_ key: String, _ value: Substring) -> some View {
        kv(key, String(value))
    }

    private func metricChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    private func degradedChip(_ degraded: Bool) -> some View {
        let label = degraded ? "DEGRADED (local fallback)" : "Mercury"
        let color: Color = degraded ? .orange : .green
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
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
        run = ContextSelector.shared.lastRun
    }
}
