//
//  ClosedNotchView.swift
//  Agent in the Notch
//
//  The agent's resting face — a minimal dot inside the closed notch that
//  reflects live agent state without requiring the user to hover open.
//

import SwiftUI

struct ClosedNotchView: View {
    @ObservedObject private var state = AgentState.shared
    @ObservedObject private var store = AgentSettingsStore.shared

    var body: some View {
        HStack(spacing: 5) {
            statusDot
            if case .listening = state.activity {
                WaveformBars()
                    .transition(.opacity.animation(.easeIn(duration: 0.12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state.activity {
        case .idle:
            IdleDot(color: store.cursorColor.swatch)
        case .listening:
            PulsingDot(color: store.cursorColor.swatch)
        case .thinking:
            ThinkingDot()
        case .toolCall:
            GlowDot(color: .green)
        case .error:
            GlowDot(color: .red)
        }
    }
}

// MARK: – Dot variants

private struct IdleDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color.opacity(0.22))
            .frame(width: 6, height: 6)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 18, height: 18)
                .scaleEffect(scale)
                .blur(radius: 2)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                scale = 1.55
            }
        }
    }
}

private struct ThinkingDot: View {
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.purple.opacity(0.55))
                .frame(width: 7, height: 7)
                .shadow(color: .purple.opacity(0.55), radius: 3)
            Circle()
                .trim(from: 0, to: 0.27)
                .stroke(
                    Color.purple.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                )
                .frame(width: 15, height: 15)
                .rotationEffect(.degrees(angle))
                .onAppear {
                    withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                }
        }
    }
}

private struct GlowDot: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 16, height: 16)
                .blur(radius: 2)
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.6), radius: 4)
        }
    }
}

// MARK: – Waveform

private struct WaveformBars: View {
    @State private var phase = false

    private let durations: [Double] = [0.38, 0.44, 0.36]
    private let baseH: [CGFloat]   = [4, 8, 5]
    private let altH: [CGFloat]    = [9, 4, 8]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1.5, height: phase ? altH[i] : baseH[i])
                    .animation(
                        .easeInOut(duration: durations[i]).repeatForever(autoreverses: true),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}
