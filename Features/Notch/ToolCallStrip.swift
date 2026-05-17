//
//  ToolCallStrip.swift
//  Agent in the Notch
//
//  Inline tool-call ticker that sits inside the live-activity notch surface
//  while the agent is running. Pure typography — no badges, no capsules. A
//  live label on the left with a breathing emerald dot, then the most recent
//  prior calls laid out as a dot-separated ghost trail to its right.
//

import SwiftUI

struct ToolCallStrip: View {
    @ObservedObject private var state = AgentState.shared

    var body: some View {
        HStack(spacing: 0) {
            if let live = liveEntry {
                LiveLabel(name: prettify(live.name))
            }

            if !recent.isEmpty {
                if liveEntry != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 0.5, height: 12)
                        .padding(.horizontal, 9)
                }

                GhostTrail(names: recent.map { prettify($0.name) })
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 1)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derivation

    private struct Entry {
        let name: String
        let detail: String
    }

    private var liveEntry: Entry? {
        if case .toolCall(let name) = state.activity {
            return Entry(name: name, detail: state.detail)
        }
        return nil
    }

    private var recent: [Entry] {
        var out: [Entry] = []
        for log in state.activityLog {
            guard case .toolCall(let name) = log.activity else { continue }
            out.append(Entry(name: name, detail: log.detail))
            if out.count >= 5 { break }
        }
        return out
    }

    private func prettify(_ s: String) -> String {
        var t = s
        if t.hasPrefix("computer_") { t.removeFirst("computer_".count) }
        return t.replacingOccurrences(of: "_", with: " ").lowercased()
    }
}

// MARK: - Live label (shimmering text)

private struct LiveLabel: View {
    let name: String

    var body: some View {
        ShiningText(text: name)
            .lineLimit(1)
    }
}

/// SwiftUI port of the `shining-text` Motion component: a horizontal gradient
/// sweep that travels across the text, masked by the glyphs themselves. Bands
/// match the source CSS — `#404040` base with a white peak — and the sweep
/// runs continuously without a timer thanks to `TimelineView(.animation)`.
struct ShiningText: View {
    let text: String
    var font: Font = .system(size: 11, weight: .medium, design: .monospaced)
    var duration: Double = 2.0

    private let base = Color(red: 0x40 / 255, green: 0x40 / 255, blue: 0x40 / 255)
    private let bright = Color.white

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let cycle = (t.truncatingRemainder(dividingBy: duration)) / duration
            // CSS animates background-position 200% → -200% (right-to-left).
            // Track the peak from just off the right edge to just off the left
            // edge so the highlight enters and exits cleanly.
            let peak = 1.2 - cycle * 1.4

            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(
                        stops: stops(for: peak),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    private func stops(for peak: Double) -> [Gradient.Stop] {
        let band = 0.18
        let l1 = max(0, min(1, peak - band))
        let l2 = max(0, min(1, peak))
        let l3 = max(0, min(1, peak + band))
        return [
            .init(color: base, location: 0),
            .init(color: base, location: l1),
            .init(color: bright, location: l2),
            .init(color: base, location: l3),
            .init(color: base, location: 1)
        ]
    }
}

// MARK: - Ghost trail (recent calls, dot-separated)

private struct GhostTrail: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { idx, name in
                if idx > 0 {
                    Text("·")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.22))
                        .padding(.horizontal, 6)
                }
                Text(name)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(fade(for: idx))
                    .lineLimit(1)
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.75),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    /// Older entries fade toward the #404040 base used by the live shimmer's
    /// flanks, so the live label is the only thing that catches the eye.
    private func fade(for idx: Int) -> Color {
        let base = Color(red: 0x40 / 255, green: 0x40 / 255, blue: 0x40 / 255)
        let steps: [Double] = [1.0, 0.85, 0.72, 0.60, 0.50]
        let a = idx < steps.count ? steps[idx] : 0.45
        return base.opacity(a)
    }
}
