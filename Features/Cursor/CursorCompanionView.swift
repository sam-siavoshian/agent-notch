//
//  CursorCompanionView.swift
//  Agent in the Notch
//
//  Renders Wyatt's SVG cursor asset (red/green/blue/yellow) from
//  Assets.xcassets via CursorColor.assetName. Pulse halo on listening,
//  ring-spin on thinking.
//

import SwiftUI

struct CursorCompanionView: View {
    @ObservedObject var viewModel: CursorCompanionViewModel
    @State private var pulse: CGFloat = 1.0
    @State private var spin: Double = 0.0

    private let spriteSize: CGFloat = 17

    var body: some View {
        ZStack {
            Image(viewModel.color.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: spriteSize, height: spriteSize)
                .scaleEffect(pulse)

            if viewModel.isThinking {
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(
                        viewModel.color.swatch.opacity(0.95),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .frame(width: spriteSize * 1.5, height: spriteSize * 1.5)
                    .rotationEffect(.degrees(spin))
            }
        }
        .frame(width: spriteSize * 2.2, height: spriteSize * 2.2)
        .onChange(of: viewModel.isListening) { _, listening in
            withAnimation(
                listening
                ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.2)
            ) {
                pulse = listening ? 1.15 : 1.0
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
