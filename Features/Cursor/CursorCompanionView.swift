//
//  CursorCompanionView.swift
//  Agent in the Notch
//
//  Rendered sprite. No PNG assets — shape-based so we can hot-swap colors
//  without an asset catalog. Pulses on listening, spins on thinking.
//

import SwiftUI

struct CursorCompanionView: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @State private var pulse: CGFloat = 1.0
    @State private var spin: Double = 0.0

    var body: some View {
        ZStack {
            Circle()
                .fill(viewModel.color.swatch.opacity(0.25))
                .frame(width: 36 * pulse, height: 36 * pulse)
                .blur(radius: 4)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [viewModel.color.swatch, viewModel.color.swatch.opacity(0.65)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 22
                    )
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                )
                .frame(width: 18, height: 18)
                .shadow(color: viewModel.color.swatch.opacity(0.7), radius: 6)

            if viewModel.isThinking {
                Circle()
                    .trim(from: 0.0, to: 0.25)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(spin))
            }
        }
        .frame(width: 36, height: 36)
        .onChange(of: viewModel.isListening) { _, listening in
            withAnimation(listening ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .easeOut(duration: 0.2)) {
                pulse = listening ? 1.6 : 1.0
            }
        }
        .onChange(of: viewModel.isThinking) { _, thinking in
            if thinking {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spin = 360
                }
            } else {
                spin = 0
            }
        }
        .allowsHitTesting(false)
    }
}
