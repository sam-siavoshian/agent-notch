//
//  ToolCallStrip.swift
//  Agent in the Notch
//
//  Inline tool-call ticker that sits inside the live-activity notch surface
//  while the agent is running. Pure typography — no badges, no capsules. A
//  live label on the left with a breathing emerald dot, then the most recent
//  prior calls laid out as a dot-separated ghost trail to its right.
//

import AppKit
import SwiftUI

struct ToolCallStrip: View {
    private let state = AgentState.shared
    @StateObject private var frontmost = FrontmostAppObserver()

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            if let icon = frontmost.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(.trailing, 7)
            }

            if let live = liveEntry {
                LiveLabel(name: self.displayName(for: live))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, NotchSizing.notchHeight(for: NSScreen.main) + 1)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

    /// Maps a raw `(toolName, action)` pair onto the label the user reads in
    /// the strip. Anthropic's computer-use API names the tool `computer` and
    /// puts the verb in the `action` field — so `name="computer"` collapses
    /// onto the action, with a hand-curated short label per verb.
    private func displayName(for entry: Entry) -> String {
        if entry.name == "computer" {
            let action = entry.detail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if action.isEmpty { return "computer" }
            return Self.actionLabel(action)
        }
        var t = entry.name
        if t.hasPrefix("computer_") { t.removeFirst("computer_".count) }
        return t.replacingOccurrences(of: "_", with: " ").lowercased()
    }

    /// Strips coordinate/argument suffixes from `detail` ("left_click (420, 300)"
    /// → "left_click") then maps onto a UI-friendly short verb.
    private static func actionLabel(_ raw: String) -> String {
        let head = raw
            .split(whereSeparator: { " (".contains($0) })
            .first
            .map(String.init) ?? raw

        switch head {
        case "screenshot":            return "screenshot"
        case "left_click",
             "left_mouse_down",
             "left_mouse_up":         return "click"
        case "right_click":           return "right click"
        case "middle_click":          return "middle click"
        case "double_click":          return "double click"
        case "triple_click":          return "triple click"
        case "left_click_drag",
             "drag":                  return "drag"
        case "mouse_move",
             "cursor_position":       return "move"
        case "type":                  return "type"
        case "key":                   return "key"
        case "hold_key":              return "hold key"
        case "scroll":                return "scroll"
        case "wait":                  return "wait"
        default:
            return head.replacingOccurrences(of: "_", with: " ")
        }
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

    private static let base = Color(red: 0x40 / 255, green: 0x40 / 255, blue: 0x40 / 255)
    private static let bright = Color.white
    private static let band = 0.18

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let cycle = (t.truncatingRemainder(dividingBy: duration)) / duration
            // CSS animates background-position 200% → -200% (right-to-left).
            // Track the peak from just off the right edge to just off the left
            // edge so the highlight enters and exits cleanly.
            let peak = 1.2 - cycle * 1.4
            let l1 = max(0, min(1, peak - Self.band))
            let l2 = max(0, min(1, peak))
            let l3 = max(0, min(1, peak + Self.band))

            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Self.base,   location: 0),
                            .init(color: Self.base,   location: l1),
                            .init(color: Self.bright, location: l2),
                            .init(color: Self.base,   location: l3),
                            .init(color: Self.base,   location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .drawingGroup()
    }
}

