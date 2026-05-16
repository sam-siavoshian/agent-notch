//
//  AgentStateView.swift
//  Agent in the Notch
//
//  Live readout of what the agent is doing. Reads from AgentState.shared.
//

import SwiftUI

struct AgentStateView: View {
    @ObservedObject private var state = AgentState.shared
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(state.activity.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var detailText: String {
        if !state.detail.isEmpty { return state.detail }
        if !state.lastTranscript.isEmpty { return "\u{201C}\(state.lastTranscript)\u{201D}" }
        return "Waiting for input"
    }

    private var accentColor: Color {
        switch state.activity {
        case .idle: return .gray
        case .listening: return .blue
        case .thinking: return .purple
        case .toolCall: return .green
        case .error: return .red
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.18))
                .frame(width: 32, height: 32)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .animation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: pulse
                )
            Image(systemName: state.activity.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
        }
        .onAppear { pulse = isAnimating }
        .onChange(of: state.activity) { _, _ in pulse = isAnimating }
    }

    private var isAnimating: Bool {
        switch state.activity {
        case .idle, .error: return false
        case .listening, .thinking, .toolCall: return true
        }
    }
}
