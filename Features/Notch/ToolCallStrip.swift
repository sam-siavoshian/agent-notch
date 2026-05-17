//
//  ToolCallStrip.swift
//  Agent in the Notch
//
//  Pure-black extension that grows out of the notch's bottom edge while the
//  agent is actively working. Renders a compact horizontal row of the live
//  and recent computer-use tool calls. The shape's top is square and tucks
//  behind the notch body so the two surfaces read as one.
//

import SwiftUI

/// Transparent strip of tool-call chips. Renders no background — the
/// surrounding NotchShape provides one continuous black surface, so this
/// view is just chips on top.
struct ToolCallStrip: View {
    @ObservedObject private var state = AgentState.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(entries) { entry in
                ToolChip(entry: entry)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .leading).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: entries)
    }

    // MARK: - State derivation

    private var entries: [Entry] {
        var out: [Entry] = []
        if case .toolCall(let name) = state.activity {
            out.append(Entry(id: "live", name: name, detail: state.detail, live: true))
        }
        for log in state.activityLog {
            guard case .toolCall(let name) = log.activity else { continue }
            out.append(Entry(id: log.id.uuidString, name: name, detail: log.detail, live: false))
            if out.count >= 4 { break }
        }
        return out
    }

    fileprivate struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
        let live: Bool
    }
}

// MARK: - Chip

private struct ToolChip: View {
    let entry: ToolCallStrip.Entry

    private var icon: String {
        let n = entry.name.lowercased()
        if n.contains("screenshot") || n.contains("screen_capture") { return "camera.viewfinder" }
        if n.contains("double_click")                          { return "cursorarrow.click.2" }
        if n.contains("click")                                 { return "cursorarrow.click" }
        if n.contains("type") || n.contains("text")            { return "keyboard" }
        if n.contains("key")                                   { return "command" }
        if n.contains("scroll")                                { return "scroll" }
        if n.contains("wait")                                  { return "hourglass" }
        if n.contains("drag")                                  { return "hand.draw" }
        if n.contains("move") || n.contains("cursor")          { return "arrow.up.left" }
        if n.contains("open_url") || n.contains("url")         { return "link" }
        if n.contains("bash") || n.contains("shell")           { return "chevron.left.slash.chevron.right" }
        return "wrench.and.screwdriver"
    }

    private var label: String {
        var t = entry.name
        if t.hasPrefix("computer_") { t.removeFirst("computer_".count) }
        return t.replacingOccurrences(of: "_", with: "_")
    }

    private var tint: Color {
        entry.live
            ? Color(red: 0x6D / 255, green: 0xE0 / 255, blue: 0x8E / 255)
            : Color.white.opacity(0.55)
    }

    var body: some View {
        HStack(spacing: 5) {
            if entry.live {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
            }
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .strokeBorder(
                    entry.live ? tint.opacity(0.55) : Color.white.opacity(0.10),
                    lineWidth: 0.6
                )
        )
        .help(entry.detail.isEmpty ? entry.name : entry.detail)
    }
}
