//
//  CursorCompanionView.swift
//  Agent in the Notch
//
//  Soft-pill cursor companion. Apple's chubby `arrowshape.up.left.fill`
//  SF Symbol = rounded cursor silhouette, no custom path math.
//  Pastel fill, soft warm two-layer shadow. Cute, not aggressive.
//

import SwiftUI

struct CursorCompanionView: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @State private var pulse: CGFloat = 1.0
    @State private var orbit: Double = 0.0
    @State private var idleOffset: CGFloat = 0.0
    @State private var idleOpacity: Double = 1.0

    private let spriteSize: CGFloat = 18

    private var isIdle: Bool { !viewModel.isListening && !viewModel.isThinking }

    var body: some View {
        ZStack {
            // Subtle ground glow — soft-pill warm halo under the cursor
            Ellipse()
                .fill(softPillColor.opacity(0.14))
                .frame(width: spriteSize * 0.55, height: spriteSize * 0.28)
                .blur(radius: 3)
                .offset(y: spriteSize * 0.5)

            if viewModel.isListening {
                Circle()
                    .fill(softPillColor.opacity(0.25))
                    .frame(width: spriteSize * 1.8 * pulse, height: spriteSize * 1.8 * pulse)
                    .blur(radius: 5)
            }

            Image(systemName: "cursorarrow")
                .font(.system(size: spriteSize, weight: .black))
                .foregroundColor(softPillColor)
                .scaleEffect(pulse)
                .shadow(color: Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.04), radius: 1, x: 0, y: 1)
                .shadow(color: Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.06), radius: 4, x: 0, y: 2)
                .offset(y: isIdle ? idleOffset : 0)
                .opacity(isIdle ? idleOpacity : 1.0)

            if viewModel.isThinking {
                Circle()
                    .fill(Color.white)
                    .frame(width: 3, height: 3)
                    .offset(y: -spriteSize * 0.85)
                    .rotationEffect(.degrees(orbit))
                    .shadow(color: softPillColor.opacity(0.6), radius: 2)
            }
        }
        .frame(width: spriteSize * 2.4, height: spriteSize * 2.4)
        .onAppear { startIdleAnimation() }
        .onChange(of: viewModel.isListening) { _, listening in
            withAnimation(
                listening
                ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.25)
            ) {
                pulse = listening ? 1.18 : 1.0
            }
        }
        .onChange(of: viewModel.isThinking) { _, thinking in
            if thinking {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    orbit = 360
                }
            } else {
                orbit = 0
            }
        }
        .allowsHitTesting(false)
    }

    /// Wyatt's CursorColor → soft-pill pastel palette.
    private var softPillColor: Color {
        switch viewModel.color {
        case .red:    return Color(red: 0.953, green: 0.478, blue: 0.478) // #F37A7A
        case .blue:   return Color(red: 0.357, green: 0.486, blue: 0.980) // #5B7CFA
        case .green:  return Color(red: 0.490, green: 0.831, blue: 0.604) // #7DD49A
        case .yellow: return Color(red: 0.961, green: 0.725, blue: 0.278) // #F5B947
        }
    }

    private func startIdleAnimation() {
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            idleOffset = -2.5
        }
        withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
            idleOpacity = 0.7
        }
    }
}
