//
//  CursorCompanionView.swift
//  Agent in the Notch
//
//  Soft-pill cursor companion. SF Symbol `cursorarrow` rendered as a
//  miniature pill surface: top→bottom-trailing gradient body, white
//  bottom-rim peek for glass-raised dimension, warm tinted halo,
//  4-layer shadow stack. Listening + thinking states animate without
//  ever stripping the dimensional treatment.
//

import SwiftUI

struct CursorCompanionView: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @State private var pulse: CGFloat = 1.0
    @State private var orbit: Double = 0.0
    @State private var idleScale: CGFloat = 1.0
    @State private var idleOpacity: Double = 1.0
    @State private var haloPhase: CGFloat = 1.0

    private static let spriteSize: CGFloat = 17
    private static let symbol = "cursorarrow"

    private var isIdle: Bool { !viewModel.isListening && !viewModel.isThinking }

    var body: some View {
        ZStack {
            groundShadow
            ambientHalo
            listeningRing
            cursorBody
                .scaleEffect(viewModel.isListening ? pulse : idleScale)
                .opacity(isIdle ? idleOpacity : 1.0)
            thinkingOrbit
        }
        .frame(width: Self.spriteSize * 2.8, height: Self.spriteSize * 2.8)
        .onAppear { startIdleAnimations() }
        .onChange(of: viewModel.isListening) { _, listening in
            if listening {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = 1.22
                    haloPhase = 1.25
                }
            } else {
                // Kill the active repeatForever transaction first, then
                // ease back to rest. Without the nil-animation reset the
                // pulse keeps oscillating after the task ends.
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) {
                    pulse = 1.0
                    haloPhase = 1.0
                }
                withAnimation(.easeOut(duration: 0.25)) {
                    pulse = 1.0
                    haloPhase = 1.0
                }
            }
        }
        .onChange(of: viewModel.isThinking) { _, thinking in
            if thinking {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    orbit = 360
                }
            } else {
                var tx = Transaction(animation: nil)
                tx.disablesAnimations = true
                withTransaction(tx) { orbit = 0 }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: layers

    private var groundShadow: some View {
        Ellipse()
            .fill(Color.black.opacity(0.14))
            .frame(width: Self.spriteSize * 0.75, height: Self.spriteSize * 0.30)
            .blur(radius: 4)
            .offset(y: Self.spriteSize * 0.65)
    }

    private var ambientHalo: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        softPillColor.opacity(0.34),
                        softPillColor.opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 1,
                    endRadius: Self.spriteSize * 1.25
                )
            )
            .frame(width: Self.spriteSize * 2.6, height: Self.spriteSize * 2.6)
            .scaleEffect(viewModel.isListening ? haloPhase : 1.0)
            .opacity(viewModel.isListening ? 1.0 : (isIdle ? 0.55 : 0.78))
    }

    @ViewBuilder
    private var listeningRing: some View {
        if viewModel.isListening {
            Circle()
                .stroke(Color.white.opacity(0.55), lineWidth: 1.4)
                .frame(width: Self.spriteSize * 1.55 * pulse, height: Self.spriteSize * 1.55 * pulse)
                .blur(radius: 0.4)
                .shadow(color: softPillColor.opacity(0.5), radius: 6)
        }
    }

    /// Cursor body. Three layered SF Symbol passes:
    ///   1. White rim peeking offset down-right (glass raised edge).
    ///   2. Main gradient body (light→saturated, top-left to bottom-right).
    ///   3. Top-left white gleam (inner highlight).
    /// Wrapped in 4-layer soft-pill shadow stack + warm tinted glow.
    private var cursorBody: some View {
        ZStack {
            Image(systemName: Self.symbol)
                .font(.system(size: Self.spriteSize, weight: .black))
                .foregroundStyle(Color.white.opacity(0.85))
                .offset(x: 0.6, y: 0.9)
                .blur(radius: 0.35)

            Image(systemName: Self.symbol)
                .font(.system(size: Self.spriteSize, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [softPillColorLight, softPillColor, softPillColorDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: Self.symbol)
                .font(.system(size: Self.spriteSize, weight: .black))
                .foregroundStyle(Color.white.opacity(0.45))
                .offset(x: -0.45, y: -0.55)
                .blur(radius: 0.25)
                .blendMode(.plusLighter)
                .mask(
                    Image(systemName: Self.symbol)
                        .font(.system(size: Self.spriteSize, weight: .black))
                )
        }
        // 4-layer soft-pill shadow recipe
        .shadow(color: Color.black.opacity(0.10), radius: 0.5, x: 0, y: 0.3)
        .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 2)
        .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 5)
        .shadow(color: softPillColor.opacity(viewModel.isListening ? 0.75 : 0.45),
                radius: viewModel.isListening ? 10 : 6, x: 0, y: 0)
    }

    @ViewBuilder
    private var thinkingOrbit: some View {
        if viewModel.isThinking {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 3.2 - CGFloat(i) * 0.7, height: 3.2 - CGFloat(i) * 0.7)
                        .opacity(1.0 - Double(i) * 0.32)
                        .offset(y: -Self.spriteSize * 0.95)
                        .rotationEffect(.degrees(orbit - Double(i) * 30))
                        .shadow(color: softPillColor.opacity(0.75), radius: 2.5)
                }
            }
        }
    }

    // MARK: palette

    /// Wyatt's CursorColor → soft-pill pastel palette (mid tone).
    private var softPillColor: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.953, green: 0.478, blue: 0.478) // #F37A7A
        case .blue:   return Color(red: 0.357, green: 0.486, blue: 0.980) // #5B7CFA
        case .green:  return Color(red: 0.490, green: 0.831, blue: 0.604) // #7DD49A
        case .yellow: return Color(red: 0.961, green: 0.725, blue: 0.278) // #F5B947
        }
    }

    /// Lighter (mixed ~35% white) for gradient top stop.
    private var softPillColorLight: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.985, green: 0.700, blue: 0.700)
        case .blue:   return Color(red: 0.610, green: 0.685, blue: 0.992)
        case .green:  return Color(red: 0.700, green: 0.905, blue: 0.760)
        case .yellow: return Color(red: 0.985, green: 0.840, blue: 0.520)
        }
    }

    /// Slightly deeper (mixed ~18% black) for gradient bottom stop.
    private var softPillColorDeep: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.780, green: 0.380, blue: 0.380)
        case .blue:   return Color(red: 0.280, green: 0.385, blue: 0.820)
        case .green:  return Color(red: 0.385, green: 0.700, blue: 0.490)
        case .yellow: return Color(red: 0.820, green: 0.605, blue: 0.215)
        }
    }

    private func startIdleAnimations() {
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
            idleScale = 1.04
        }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            idleOpacity = 0.82
        }
    }
}
