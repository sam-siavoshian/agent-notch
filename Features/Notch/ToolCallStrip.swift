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

// MARK: - Live label

private struct LiveLabel: View {
    let name: String
    @State private var pulse = false

    private let tint = Color(red: 0x6D / 255, green: 0xE0 / 255, blue: 0x8E / 255)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 1.0 : 0.45)
                .shadow(color: tint.opacity(0.65), radius: 3)

            Text(name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
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

    /// Older entries fade further out so the eye lands on the live label.
    private func fade(for idx: Int) -> Color {
        let steps: [Double] = [0.55, 0.42, 0.32, 0.24, 0.18]
        let a = idx < steps.count ? steps[idx] : 0.15
        return Color.white.opacity(a)
    }
}
