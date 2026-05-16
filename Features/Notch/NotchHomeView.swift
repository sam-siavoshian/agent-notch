//
//  NotchHomeView.swift
//  Agent in the Notch
//
//  Home tab: agent presence orb, last spoken request, scrollable action log.
//

import SwiftUI

struct NotchHomeView: View {
    @ObservedObject private var state = AgentState.shared
    @ObservedObject private var store = AgentSettingsStore.shared

    private var isActive: Bool {
        switch state.activity {
        case .idle, .error: return false
        case .listening, .thinking, .toolCall: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHero

            if !state.lastTranscript.isEmpty {
                lastRequestCard
            }

            if !state.activityLog.isEmpty {
                activityFeed
            } else if !isActive && state.lastTranscript.isEmpty {
                emptyState
            }
        }
    }

    // MARK: – Status hero

    private var statusHero: some View {
        HStack(spacing: 14) {
            AgentOrb(color: store.cursorColor.swatch, isActive: isActive)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.activity.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .animation(nil, value: state.activity.label)

                Group {
                    if !state.detail.isEmpty {
                        Text(state.detail)
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        Text(isActive ? "Working on it…" : "Ready when you are")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: – Last request

    private var lastRequestCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 1)
            Text(state.lastTranscript)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: – Activity feed

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recent")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.leading, 2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(state.activityLog) { entry in
                        ActivityLogRow(entry: entry)
                    }
                }
            }
            .frame(maxHeight: 164)
        }
    }

    // MARK: – Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            if AgentInterfaces.cursor == nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange.opacity(0.75))
                Text("Cursor companion not connected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Waiting for Sam's module to register.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.28))
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(store.cursorColor.swatch.opacity(0.65))
                Text("Long-press the cursor companion to get started")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.38))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

// MARK: – Agent orb

private struct AgentOrb: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                PulsingHalo(color: color)
            } else {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
            }

            Circle()
                .fill(RadialGradient(
                    colors: [color, color.opacity(0.6)],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: 20
                ))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                .frame(width: 26, height: 26)
                .shadow(color: color.opacity(0.65), radius: 8)

            if isActive {
                SpinnerArc()
                    .frame(width: 38, height: 38)
            }
        }
        .frame(width: 44, height: 44)
    }
}

private struct PulsingHalo: View {
    let color: Color
    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(color.opacity(0.18))
            .frame(width: 44, height: 44)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    scale = 1.22
                }
            }
    }
}

private struct SpinnerArc: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.27)
            .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

// MARK: – Activity log row

private struct ActivityLogRow: View {
    let entry: AgentLogEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.activity.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(rowColor)
                .frame(width: 14, alignment: .center)

            Text(rowLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Text(entry.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.28))
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var rowLabel: String {
        entry.detail.isEmpty ? entry.activity.label : entry.detail
    }

    private var rowColor: Color {
        switch entry.activity {
        case .idle:             return .gray
        case .listening:        return .blue
        case .thinking:         return .purple
        case .toolCall:         return .green
        case .error:            return .red
        }
    }
}
