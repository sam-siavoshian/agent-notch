//
//  CursorCompanionView.swift
//  Agent in the Notch
//
//  Two render paths gated by `viewModel.mode`:
//
//    .companion — calm soft-pill glass dot beside the real cursor.
//                 Replaces the old duplicate cursorarrow sprite which read
//                 as a second pointer competing with the OS arrow. The new
//                 dot is small (11pt), restrained (2% breathe, 1.10 listen
//                 pulse), uses a single soft ring + single thinking arc.
//
//    .glow      — invisible at rest. While the agent is active (long-press
//                 or AgentState.activity != .idle) a soft radial glow fades
//                 in directly under the real cursor and hue-shifts with the
//                 agent state via SoftPill.activityHue(...). `.plusLighter`
//                 blend so it warms whatever pixels sit beneath without
//                 hard-overlaying them.
//

import SwiftUI

struct CursorCompanionView: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @ObservedObject private var agentState = AgentState.shared

    var body: some View {
        Group {
            switch viewModel.mode {
            case .companion: CompanionDot(viewModel: viewModel)
            case .glow:      CursorGlow(viewModel: viewModel, agentState: agentState)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Companion mode (soft-pill glass dot)

private struct CompanionDot: View {
    @ObservedObject var viewModel: CursorCompanionViewModel

    @State private var listenPulse: CGFloat = 1.0
    @State private var thinkPhase: Double = 0.0

    private static let dotSize: CGFloat = 11
    private static let ringRadius: CGFloat = 14

    private var isIdle: Bool { !viewModel.isListening && !viewModel.isThinking }

    var body: some View {
        ZStack {
            listeningRing
            thinkingArc
            dotBody
                .scaleEffect(viewModel.isListening ? listenPulse : 1.0)
        }
        .frame(width: Self.dotSize * 4, height: Self.dotSize * 4)
        .onChange(of: viewModel.isListening) { _, listening in
            if listening {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    listenPulse = 1.10
                }
            } else {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) { listenPulse = 1.0 }
                withAnimation(.easeOut(duration: 0.25)) { listenPulse = 1.0 }
            }
        }
        .onChange(of: viewModel.isThinking) { _, thinking in
            if thinking {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    thinkPhase = 360
                }
            } else {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) { thinkPhase = 0 }
            }
        }
    }

    private var dotBody: some View {
        let gradient = RadialGradient(
            colors: [softPillLight, softPillMid, softPillDeep.opacity(0.0)],
            center: UnitPoint(x: 0.38, y: 0.34),
            startRadius: 0,
            endRadius: Self.dotSize * 0.7
        )
        let glowOpacity: Double = viewModel.isListening ? 0.55 : 0.35
        let glowRadius: CGFloat = viewModel.isListening ? 8 : 5
        let restOpacity: Double = isIdle ? 0.95 : 1.0

        return Circle()
            .fill(gradient)
            .overlay(innerHighlight)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .shadow(color: Color.black.opacity(0.22), radius: 1.5, x: 0, y: 0.8)
            .shadow(color: softPillMid.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
            .opacity(restOpacity)
    }

    // Single warm inner highlight (top-left light leak) — sells the
    // soft-pill dimensional feel without the old 4-layer SF-Symbol stack.
    private var innerHighlight: some View {
        Circle()
            .fill(Color.white.opacity(0.55))
            .frame(width: Self.dotSize * 0.42, height: Self.dotSize * 0.42)
            .blur(radius: 1.6)
            .offset(x: -Self.dotSize * 0.18, y: -Self.dotSize * 0.20)
            .blendMode(.plusLighter)
    }

    @ViewBuilder
    private var listeningRing: some View {
        if viewModel.isListening {
            Circle()
                .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
                .frame(width: Self.ringRadius * 2 * listenPulse,
                       height: Self.ringRadius * 2 * listenPulse)
                .blur(radius: 0.3)
                .shadow(color: softPillMid.opacity(0.45), radius: 5)
                .opacity(2.2 - Double(listenPulse))   // 1.20 at rest pulse → 1.0 at peak
        }
    }

    @ViewBuilder
    private var thinkingArc: some View {
        if viewModel.isThinking {
            Circle()
                .trim(from: 0.72, to: 1.0)
                .stroke(
                    AngularGradient(
                        colors: [softPillMid.opacity(0.0), softPillMid.opacity(0.85)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
                .frame(width: Self.ringRadius * 2, height: Self.ringRadius * 2)
                .rotationEffect(.degrees(thinkPhase))
                .shadow(color: softPillMid.opacity(0.55), radius: 3)
        }
    }

    // MARK: palette — picks the user's chosen swatch (Sam's original spec)

    private var softPillMid: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.953, green: 0.478, blue: 0.478) // #F37A7A
        case .blue:   return Color(red: 0.357, green: 0.486, blue: 0.980) // #5B7CFA
        case .green:  return Color(red: 0.490, green: 0.831, blue: 0.604) // #7DD49A
        case .yellow: return Color(red: 0.961, green: 0.725, blue: 0.278) // #F5B947
        }
    }

    private var softPillLight: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.985, green: 0.700, blue: 0.700)
        case .blue:   return Color(red: 0.640, green: 0.715, blue: 0.992)
        case .green:  return Color(red: 0.730, green: 0.920, blue: 0.780)
        case .yellow: return Color(red: 0.992, green: 0.860, blue: 0.560)
        }
    }

    private var softPillDeep: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.780, green: 0.380, blue: 0.380)
        case .blue:   return Color(red: 0.280, green: 0.385, blue: 0.820)
        case .green:  return Color(red: 0.385, green: 0.700, blue: 0.490)
        case .yellow: return Color(red: 0.820, green: 0.605, blue: 0.215)
        }
    }
}

// MARK: - Glow mode (radial halo under cursor while agent is active)

private struct CursorGlow: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @ObservedObject var agentState: AgentState

    @State private var renderedOpacity: Double = 0.0

    private static let glowDiameter: CGFloat = 100
    private static let pressAnchorSize: CGFloat = 3

    /// Glow is visible while the user is holding (isListening) OR while the
    /// agent is doing visible work after the press. Once the agent returns
    /// to idle the glow fades out even if the user is still holding — that
    /// matches the user mental model of "the agent is busy → glow on."
    private var shouldRender: Bool {
        if viewModel.isListening { return true }
        switch agentState.activity {
        case .idle: return false
        default:    return true
        }
    }

    private var hue: Color { SoftPill.activityHue(agentState.activity) }

    var body: some View {
        ZStack {
            // Soft radial halo. `.plusLighter` blends with whatever sits
            // beneath the cursor so the effect feels like light leaking onto
            // the desktop rather than an opaque sticker laid over it.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [hue.opacity(0.55), hue.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: Self.glowDiameter / 2
                    )
                )
                .frame(width: Self.glowDiameter, height: Self.glowDiameter)
                .blur(radius: 12)
                .blendMode(.plusLighter)

            // Tight center anchor pinned to the press point. Only when the
            // user is physically holding — gives the soft glow a hard "you
            // clicked here" focal point so the press location does not feel
            // ambiguous.
            if viewModel.isListening {
                Circle()
                    .fill(hue)
                    .frame(width: Self.pressAnchorSize, height: Self.pressAnchorSize)
                    .shadow(color: hue.opacity(0.7), radius: 2)
            }
        }
        .opacity(renderedOpacity)
        .onAppear { syncOpacity(animated: false) }
        .onChange(of: shouldRender) { _, _ in syncOpacity(animated: true) }
        .onChange(of: viewModel.mode) { _, _ in syncOpacity(animated: false) }
    }

    private func syncOpacity(animated: Bool) {
        let target: Double = shouldRender ? 1.0 : 0.0
        if animated {
            let duration = shouldRender ? 0.22 : 0.32
            let curve: Animation = shouldRender
                ? .easeOut(duration: duration)
                : .easeIn(duration: duration)
            withAnimation(curve) { renderedOpacity = target }
        } else {
            var tx = Transaction(animation: nil)
            tx.disablesAnimations = true
            withTransaction(tx) { renderedOpacity = target }
        }
    }
}
