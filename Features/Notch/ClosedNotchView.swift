//
//  ClosedNotchView.swift
//  Agent in the Notch
//
//  Resting status indicator inside the closed notch. Hues come from the
//  soft-pill status palette.
//

import SwiftUI

struct ClosedNotchView: View {
    @ObservedObject private var state = AgentState.shared

    var body: some View {
        HStack(spacing: 5) {
            statusDot
            if case .listening = state.activity {
                WaveformBars(color: SoftPill.activityHue(.listening))
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
            IdleDot(color: SoftPill.activityHue(.idle))
        case .listening:
            PulsingDot(color: SoftPill.activityHue(.listening))
        case .thinking:
            ThinkingDot(color: SoftPill.activityHue(.thinking))
        case .toolCall:
            GlowDot(color: SoftPill.activityHue(.toolCall(name: "")))
        case .error:
            GlowDot(color: SoftPill.activityHue(.error(message: "")))
        }
    }
}

private struct IdleDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color.opacity(0.45))
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.4))
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var scale: CGFloat = 1.0
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.28)).frame(width: 16, height: 16).scaleEffect(scale).blur(radius: 2)
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color.opacity(0.9), radius: 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { scale = 1.55 }
        }
    }
}

private struct ThinkingDot: View {
    let color: Color
    @State private var angle: Double = 0
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.7)).frame(width: 6, height: 6).shadow(color: color.opacity(0.65), radius: 3)
            Circle()
                .trim(from: 0, to: 0.27)
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: 13, height: 13)
                .rotationEffect(.degrees(angle))
                .onAppear {
                    withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) { angle = 360 }
                }
        }
    }
}

private struct GlowDot: View {
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.28)).frame(width: 14, height: 14).blur(radius: 2)
            Circle().fill(color.opacity(0.95)).frame(width: 6, height: 6).shadow(color: color.opacity(0.7), radius: 4)
        }
    }
}

private struct WaveformBars: View {
    let color: Color
    @State private var phase = false
    private let durations: [Double] = [0.38, 0.44, 0.36]
    private let baseH: [CGFloat]   = [3, 7, 4]
    private let altH: [CGFloat]    = [8, 3, 7]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(0.85))
                    .frame(width: 1.5, height: phase ? altH[i] : baseH[i])
                    .animation(.easeInOut(duration: durations[i]).repeatForever(autoreverses: true), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
