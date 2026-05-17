//
//  ContextDebugView+Dirty.swift
//  Agent in the Notch
//
//  Dev Tools pane: dirty-detector visualization. Live counters, recent
//  comparisons with thumbnails + bounding overlays, and a legend for the
//  classification bands.
//

import AppKit
import CoreGraphics
import SwiftUI

struct ContextDebugDirtyPane: View {
    @StateObject private var model = DirtyPaneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.entries.isEmpty {
                        Text("No dirty comparisons recorded yet. Trigger a screen capture (click anywhere or switch apps) to populate this list.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(20)
                    } else {
                        ForEach(model.entries, id: \.snapshotID) { entry in
                            DirtyRow(entry: entry)
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Divider()
            legend
                .padding(12)
        }
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dirty detector")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 16) {
                DirtyCounterChip(label: "unchanged", value: model.unchangedPercent, color: .green)
                DirtyCounterChip(label: "minor", value: model.minorPercent, color: .yellow)
                DirtyCounterChip(label: "major", value: model.majorPercent, color: .red)
                Text("over last \(model.windowCount) of \(model.totalSeen)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                ThresholdChip(label: "unchanged ≤", value: "h\(model.thresholds.unchangedHamming) / a\(formatPercent(model.thresholds.unchangedAreaFraction))")
                ThresholdChip(label: "minor ≤", value: "h\(model.thresholds.minorHamming) / a\(formatPercent(model.thresholds.minorAreaFraction))")
                ThresholdChip(label: "pixel noise", value: "\(model.thresholds.pixelNoiseThreshold)")
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bands")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("≤4 hamming AND <1% area = unchanged · ≤15 hamming or ≤8% area = minor · else major")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Masked regions: top 3 rows (menu bar / clock), bottom 4 rows (dock).")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

private struct DirtyRow: View {
    let entry: ContextCoordinator.DirtyComparisonRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DirtyThumbnail(jpegData: entry.jpegData, boundingRect: entry.dirtyBoundingRect)
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    DirtyClassificationPill(classification: entry.classification)
                    Text("h=\(entry.hamming)")
                        .font(.caption.monospaced())
                    Text(String(format: "area=%.1f%%", entry.changedArea * 100))
                        .font(.caption.monospaced())
                }
                Text(entry.appName)
                    .font(.callout.weight(.semibold))
                Text(entry.windowTitle.isEmpty ? "Untitled window" : entry.windowTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(relativeTime(from: entry.capturedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let rect = entry.dirtyBoundingRect {
                    Text(String(
                        format: "dirty rect (norm): x=%.2f y=%.2f w=%.2f h=%.2f",
                        rect.minX, rect.minY, rect.width, rect.height
                    ))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func relativeTime(from date: Date) -> String {
        Self.relFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct DirtyClassificationPill: View {
    let classification: ContextDirtyClassification

    var body: some View {
        Text(classification.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch classification {
        case .unchanged: return .green
        case .minorChange: return .yellow
        case .majorChange: return .red
        }
    }
}

private struct DirtyCounterChip: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct ThresholdChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced().weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct DirtyThumbnail: View {
    let jpegData: Data
    let boundingRect: CGRect?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image = NSImage(data: jpegData) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                    Text("Decode failed").font(.caption2).foregroundStyle(.secondary)
                }
                if let rect = boundingRect {
                    let size = geometry.size
                    Rectangle()
                        .fill(Color.red.opacity(0.28))
                        .overlay(
                            Rectangle().strokeBorder(Color.red.opacity(0.85), lineWidth: 1.5)
                        )
                        .frame(
                            width: max(2, rect.width * size.width),
                            height: max(2, rect.height * size.height)
                        )
                        .offset(
                            x: rect.minX * size.width,
                            y: rect.minY * size.height
                        )
                }
            }
            .clipped()
        }
    }
}

@MainActor
private final class DirtyPaneModel: ObservableObject {
    @Published private(set) var entries: [ContextCoordinator.DirtyComparisonRecord] = []
    @Published private(set) var thresholds = ContextDirtyThresholds()
    @Published private(set) var totalSeen: Int = 0
    @Published private(set) var windowCount: Int = 0
    @Published private(set) var unchangedPercent: Double = 0
    @Published private(set) var minorPercent: Double = 0
    @Published private(set) var majorPercent: Double = 0

    private var timer: Timer?

    func start() async {
        await refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        let recent = await ContextCoordinator.shared.recentDirtyComparisons(limit: 200)
        let thresholds = await ContextCoordinator.shared.dirtyThresholdsSnapshot()
        let totalSeen = recent.count
        let window = Array(recent.prefix(200))
        let unchanged = window.filter { $0.classification == .unchanged }.count
        let minor = window.filter { $0.classification == .minorChange }.count
        let major = window.filter { $0.classification == .majorChange }.count
        let n = max(1, window.count)
        self.entries = Array(recent.prefix(30))
        self.thresholds = thresholds
        self.totalSeen = totalSeen
        self.windowCount = window.count
        self.unchangedPercent = Double(unchanged) / Double(n)
        self.minorPercent = Double(minor) / Double(n)
        self.majorPercent = Double(major) / Double(n)
    }
}
