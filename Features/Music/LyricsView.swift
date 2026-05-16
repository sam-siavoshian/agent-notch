//
//  LyricsView.swift
//  Agent in the Notch
//
//  Karaoke-style synced lyrics panel. Center-anchored 5-line scroller,
//  top/bottom fade mask, active line in primary white, neighbors dimmed.
//  See ~/.claude/skills/soft-pill-ui/references/live-lyrics.md.
//

import SwiftUI

struct LyricsView: View {
    @ObservedObject var store: LyricsStore
    let elapsed: Double
    let isPlaying: Bool

    private let lineHeight: CGFloat = 18
    private let visibleHalf = 2     // 2 above + active + 2 below = 5

    var body: some View {
        ZStack {
            // Panel chrome — NOT masked. Sits behind the scrolling text so the
            // background doesn't fade out at the edges along with the lyrics.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                )

            Group {
                if store.isLoading {
                    skeleton
                } else if store.lines.isEmpty && store.plain.isEmpty {
                    if store.lastError != nil {
                        emptyState
                    } else {
                        Color.clear
                    }
                } else if store.lines.isEmpty {
                    plainBlock
                } else {
                    syncedScroller
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .mask(fadeMask)
        }
        .frame(height: lineHeight * CGFloat(visibleHalf * 2 + 1) + 16)
        .opacity(isPlaying ? 1.0 : 0.6)
        .animation(.easeOut(duration: 0.18), value: isPlaying)
    }

    /// 250ms look-ahead — the active line lights up SLIGHTLY before it is sung.
    /// Karaoke convention; without it the highlight feels late on long lines.
    private static let lookAhead: Double = 0.25

    private var activeIndex: Int {
        guard !store.lines.isEmpty else { return 0 }
        let target = elapsed + Self.lookAhead
        var lo = 0, hi = store.lines.count - 1, idx = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if store.lines[mid].time <= target { idx = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return idx
    }

    private var syncedScroller: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.lines.enumerated()), id: \.element.id) { i, line in
                Text(line.text)
                    .font(.system(size: fontSize(for: i), weight: weight(for: i)))
                    .foregroundStyle(color(for: i))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: lineHeight)
                    .scaleEffect(scale(for: i), anchor: .leading)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .offset(y: -CGFloat(activeIndex) * lineHeight + lineHeight * CGFloat(visibleHalf))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: activeIndex)
    }

    private func distance(_ i: Int) -> Int { abs(i - activeIndex) }
    private func fontSize(for i: Int) -> CGFloat {
        distance(i) == 0 ? 12.5 : distance(i) == 1 ? 11.5 : 10.5
    }
    private func weight(for i: Int) -> Font.Weight {
        distance(i) == 0 ? .semibold : distance(i) == 1 ? .medium : .regular
    }
    private func color(for i: Int) -> Color {
        switch distance(i) {
        case 0:  return .white
        case 1:  return .white.opacity(0.62)
        default: return .white.opacity(0.30)
        }
    }
    private func scale(for i: Int) -> CGFloat {
        distance(i) == 0 ? 1.0 : distance(i) == 1 ? 0.97 : 0.93
    }

    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1.00),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([0.70, 0.92, 0.55], id: \.self) { w in
                Capsule().fill(Color.white.opacity(0.08))
                    .frame(width: 160 * w, height: 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text("No lyrics for this track")
            .font(.system(size: 10.5, weight: .regular))
            .italic()
            .foregroundStyle(.white.opacity(0.32))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var plainBlock: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(store.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
