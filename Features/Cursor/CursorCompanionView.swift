//
//  CursorCompanionView.swift
//  Agent in the Notch
//
//  Two render paths gated by `viewModel.mode`:
//
//    .companion — soft-pill luminous orb that floats beside the real cursor.
//                 Coral by default; tints with the agent state (listening
//                 blue / thinking amber / toolCall green / error red).
//                 Idle breath + listening ripples + thinking orbiters + a
//                 200ms heart microburst when a tool call completes.
//
//    .glow      — invisible at rest. While the user is holding (listening)
//                 OR the agent is doing visible work, a soft radial aura
//                 fades in directly under the real cursor. Painted via
//                 `Canvas` for true continuous falloff that extends well
//                 past the visible edge (no hard rect leak — fixes the
//                 prior "big square" bug). `.plusLighter` blend so the
//                 aura warms pixels beneath without overlaying them.
//

import SwiftUI

// MARK: - Palette

private enum CursorPalette {
    /// Default warm coral matching the soft-pill CTA gradient family.
    static let coralWarm = Color(red: 1.00, green: 0.70, blue: 0.42)     // #FFB36B
    static let coralPink = Color(red: 1.00, green: 0.48, blue: 0.71)     // #FF7AB6
    static let coralCore = Color(red: 1.00, green: 0.85, blue: 0.70)     // light core
    static let coralDeep = Color(red: 0.78, green: 0.32, blue: 0.42)     // shadow depth

    /// Per-state primary hue. Idle → coral. Active states tint accordingly.
    static func primary(for activity: AgentActivity) -> Color {
        switch activity {
        case .idle:        return coralPink
        case .listening:   return Color(red: 0.357, green: 0.486, blue: 0.980)   // #5B7CFA
        case .thinking:    return Color(red: 0.961, green: 0.725, blue: 0.278)   // #F5B947
        case .toolCall:    return Color(red: 0.490, green: 0.831, blue: 0.604)   // #7DD49A
        case .error:       return Color(red: 0.953, green: 0.478, blue: 0.478)   // #F37A7A
        }
    }

    /// Subtle bias from the user's `CursorColor` setting — applied as an
    /// overlay tint, not a full replacement, so the orb always feels coral
    /// first.
    static func bias(for color: CursorColor) -> Color {
        switch color {
        case .red:    return Color(red: 0.953, green: 0.478, blue: 0.478)
        case .blue:   return Color(red: 0.357, green: 0.486, blue: 0.980)
        case .green:  return Color(red: 0.490, green: 0.831, blue: 0.604)
        case .yellow: return Color(red: 0.961, green: 0.725, blue: 0.278)
        }
    }
}

// MARK: - Top-level shell

struct CursorCompanionView: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    private let agentState = AgentState.shared

    /// Fires on `.toolCall → .idle` transitions; `HeartBurst` reads this to
    /// animate. Cleared automatically after the burst lifetime.
    @State private var burstStart: Date?

    var body: some View {
        ZStack {
            switch viewModel.mode {
            case .companion:
                CompanionOrb(viewModel: viewModel, activity: agentState.activity)
            case .glow:
                CursorAura(viewModel: viewModel, activity: agentState.activity)
            }
            HeartBurst(start: burstStart)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
        .background(Color.clear)
        .onChange(of: agentState.activity) { oldValue, newValue in
            if case .toolCall = oldValue, case .idle = newValue {
                burstStart = Date()
                // Auto-clear so a future transition can re-fire.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    burstStart = nil
                }
            }
        }
    }
}

// MARK: - Companion mode (soft-pill luminous orb)

private struct CompanionOrb: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    let activity: AgentActivity

    private static let coreSize: CGFloat = 12
    private static let glowSize: CGFloat = 36
    private static let satelliteRadius: CGFloat = 12

    private var hue: Color {
        // Blend the state hue with the user's color bias so the user's
        // CursorColor setting still affects the look without overriding
        // state semantics.
        let stateHue = CursorPalette.primary(for: activity)
        if case .idle = activity {
            return blend(stateHue, CursorPalette.bias(for: viewModel.color), t: 0.35)
        }
        return stateHue
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = breathScale(t)
            let listeningPulse = viewModel.isListening ? (1.0 + 0.06 * sin(t * 2 * .pi * 1.2)) : 1.0
            let combined = breath * listeningPulse
            let errorShake: CGFloat = isError ? CGFloat(sin(t * 24)) * 2 : 0

            ZStack {
                glowHalo
                if viewModel.isListening {
                    rippleRings(time: t)
                }
                if showThinkingSatellites {
                    thinkingSatellites(time: t)
                }
                coreOrb
            }
            .scaleEffect(combined)
            .offset(x: errorShake, y: 0)
            .compositingGroup()
            .frame(width: 60, height: 60)
        }
    }

    // MARK: - Layers

    private var glowHalo: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: hue.opacity(0.45), location: 0.0),
                        .init(color: hue.opacity(0.18), location: 0.45),
                        .init(color: hue.opacity(0.0),  location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: Self.glowSize / 2
                )
            )
            .frame(width: Self.glowSize, height: Self.glowSize)
            .blur(radius: 3)
            .blendMode(.plusLighter)
    }

    private var coreOrb: some View {
        ZStack {
            // Soft-pill dimensional fill: light core offset toward top-left,
            // warm mid-tone falloff, transparent edge.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: CursorPalette.coralCore, location: 0.0),
                            .init(color: hue,                     location: 0.55),
                            .init(color: CursorPalette.coralDeep.opacity(0.0), location: 1.0)
                        ]),
                        center: UnitPoint(x: 0.38, y: 0.34),
                        startRadius: 0,
                        endRadius: Self.coreSize * 0.7
                    )
                )
                .frame(width: Self.coreSize, height: Self.coreSize)

            // Top-left inner highlight — sells the dimensional feel.
            Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: Self.coreSize * 0.42, height: Self.coreSize * 0.42)
                .blur(radius: 1.6)
                .offset(x: -Self.coreSize * 0.18, y: -Self.coreSize * 0.20)
                .blendMode(.plusLighter)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 1.5, x: 0, y: 0.8)
        .shadow(color: hue.opacity(0.55), radius: viewModel.isListening ? 8 : 5, x: 0, y: 0)
    }

    @ViewBuilder
    private func rippleRings(time t: TimeInterval) -> some View {
        // Two ripples, phase-offset by 0.5s, period 1.0s.
        ForEach(0..<2, id: \.self) { i in
            let phase = (t.truncatingRemainder(dividingBy: 1.0) + Double(i) * 0.5).truncatingRemainder(dividingBy: 1.0)
            let scale = 0.6 + phase * 1.4                    // 0.6 → 2.0
            let opacity = max(0, 0.65 * (1.0 - phase))       // 0.65 → 0
            Circle()
                .stroke(hue.opacity(opacity), lineWidth: 1.2)
                .frame(width: Self.coreSize * scale, height: Self.coreSize * scale)
                .blendMode(.plusLighter)
        }
    }

    private var showThinkingSatellites: Bool {
        if case .thinking = activity { return true }
        return viewModel.isThinking
    }

    @ViewBuilder
    private func thinkingSatellites(time t: TimeInterval) -> some View {
        let baseAngle = (t * 360.0 / 1.4).truncatingRemainder(dividingBy: 360)
        ForEach(0..<3, id: \.self) { i in
            let angle = baseAngle + Double(i) * 120
            let rad = angle * .pi / 180
            let x = cos(rad) * Self.satelliteRadius
            let y = sin(rad) * Self.satelliteRadius
            // Per-satellite breathing offset by 120°.
            let breath = 0.6 + 0.4 * (sin(t * 2 * .pi + Double(i) * 2.094) * 0.5 + 0.5)
            Circle()
                .fill(hue.opacity(breath))
                .frame(width: 2.4, height: 2.4)
                .offset(x: x, y: y)
                .blendMode(.plusLighter)
        }
    }

    // MARK: - Helpers

    private var isError: Bool {
        if case .error = activity { return true }
        return false
    }

    /// Subtle idle breath — 1.0 → 1.04 → 1.0 over 3s.
    private func breathScale(_ t: TimeInterval) -> CGFloat {
        let s = sin(t * 2 * .pi / 3.0) * 0.5 + 0.5    // 0..1
        return 1.0 + CGFloat(s) * 0.04
    }

    private func blend(_ a: Color, _ b: Color, t: Double) -> Color {
        // SwiftUI lacks public color-space mixing; use NSColor for the blend.
        let aN = NSColor(a).usingColorSpace(.sRGB) ?? .white
        let bN = NSColor(b).usingColorSpace(.sRGB) ?? .white
        let mix = NSColor(
            srgbRed:   aN.redComponent   * (1 - t) + bN.redComponent   * t,
            green:     aN.greenComponent * (1 - t) + bN.greenComponent * t,
            blue:      aN.blueComponent  * (1 - t) + bN.blueComponent  * t,
            alpha:     aN.alphaComponent * (1 - t) + bN.alphaComponent * t
        )
        return Color(nsColor: mix)
    }
}

// MARK: - Glow mode (cursor aura)

private struct CursorAura: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    let activity: AgentActivity

    @State private var renderedOpacity: Double = 0.0

    private static let panelSize: CGFloat = 200
    private static let visibleRadius: CGFloat = 56
    private static let paintRadius: CGFloat = 90

    private var shouldRender: Bool {
        if viewModel.isListening { return true }
        if case .idle = activity { return false }
        return true
    }

    private var hue: Color { CursorPalette.primary(for: activity) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !shouldRender)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = 1.0 + 0.06 * (sin(t * 2 * .pi / 2.4) * 0.5 + 0.5)

            ZStack {
                aura
                    .scaleEffect(breath)
                if isToolCall {
                    toolCallRipple(time: t)
                }
                if viewModel.isListening {
                    anchorPip
                }
            }
            .frame(width: Self.panelSize, height: Self.panelSize)
            .compositingGroup()
            .blendMode(.plusLighter)
            .opacity(renderedOpacity)
        }
        .onAppear { syncOpacity(animated: false) }
        .onChange(of: shouldRender) { _, _ in syncOpacity(animated: true) }
        .onChange(of: viewModel.mode) { _, _ in syncOpacity(animated: false) }
    }

    // MARK: - Layers

    /// Soft radial halo painted via Canvas. Continuous gradient from
    /// `hue.opacity(0.55)` at center → 0.0 at `paintRadius`, leaving
    /// `panelSize/2 - paintRadius = 10pt` of transparent margin before the
    /// panel edge. The Circle().fill() approach is gone — Canvas does the
    /// radial in one pass with no clipping boundary.
    private var aura: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let stops = Gradient(stops: [
                .init(color: hue.opacity(0.55), location: 0.0),
                .init(color: hue.opacity(0.32), location: 0.25),
                .init(color: hue.opacity(0.12), location: 0.55),
                .init(color: hue.opacity(0.0),  location: 1.0)
            ])
            let rect = CGRect(
                x: center.x - Self.paintRadius,
                y: center.y - Self.paintRadius,
                width: Self.paintRadius * 2,
                height: Self.paintRadius * 2
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    stops,
                    center: center,
                    startRadius: 0,
                    endRadius: Self.paintRadius
                )
            )
        }
    }

    private var anchorPip: some View {
        Circle()
            .fill(hue.opacity(0.95))
            .frame(width: 4, height: 4)
            .shadow(color: hue.opacity(0.7), radius: 2)
    }

    private var isToolCall: Bool {
        if case .toolCall = activity { return true }
        return false
    }

    @ViewBuilder
    private func toolCallRipple(time t: TimeInterval) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 1.8) / 1.8
        let scale = 0.2 + phase * 0.95             // expand 0.2 → 1.15x of visibleRadius
        let opacity = max(0, 0.45 * (1.0 - phase))
        Circle()
            .stroke(hue.opacity(opacity), lineWidth: 1.5)
            .frame(width: Self.visibleRadius * 2 * scale,
                   height: Self.visibleRadius * 2 * scale)
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

// MARK: - Heart microburst (success FX)

private struct HeartBurst: View {
    let start: Date?

    private static let lifetime: TimeInterval = 0.32
    private static let particleCount = 5

    // Pre-baked random angles + glyph mix so the burst pattern stays
    // visually stable each fire (no jitter between frames).
    private static let angles: [Double]  = [-70, -95, -110, -85, -120]   // upward fan
    private static let glyphs: [String]  = ["heart.fill", "sparkle", "heart.fill", "heart.fill", "sparkle"]
    private static let colors: [Color]   = [
        CursorPalette.coralPink,
        CursorPalette.coralWarm,
        CursorPalette.coralPink,
        CursorPalette.coralPink,
        CursorPalette.coralWarm
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: start == nil)) { ctx in
            if let start, ctx.date.timeIntervalSince(start) <= Self.lifetime {
                let elapsed = ctx.date.timeIntervalSince(start)
                let progress = elapsed / Self.lifetime
                ZStack {
                    ForEach(0..<Self.particleCount, id: \.self) { i in
                        particle(index: i, progress: progress)
                    }
                }
                .frame(width: 60, height: 60)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    @ViewBuilder
    private func particle(index i: Int, progress: Double) -> some View {
        let angle = Self.angles[i] * .pi / 180.0
        let distance = 24.0 * progress
        let x = cos(angle) * distance
        let y = sin(angle) * distance
        let opacity = max(0, 0.9 * (1.0 - progress))
        let scale = scaleEnvelope(progress)
        Image(systemName: Self.glyphs[i])
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Self.colors[i])
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(x: x, y: y)
            .shadow(color: Self.colors[i].opacity(0.5), radius: 2)
    }

    /// 0.6 → 1.0 → 0.85 envelope so particles puff in then settle.
    private func scaleEnvelope(_ p: Double) -> CGFloat {
        if p < 0.4 {
            return CGFloat(0.6 + (p / 0.4) * 0.4)        // 0.6 → 1.0
        } else {
            return CGFloat(1.0 - ((p - 0.4) / 0.6) * 0.15)   // 1.0 → 0.85
        }
    }
}
