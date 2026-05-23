//
//  LyricsView.swift
//  Agent in the Notch
//
//  Karaoke-style synced lyrics panel + compact empty / loading affordances.
//
//  Height is state-dependent:
//    - Synced or plain lyrics → 106pt panel (5-line scroller with fade mask)
//    - Loading                → 28pt soft-pill "Looking for lyrics…" with
//                                breathing dots
//    - No lyrics found        → 28pt soft-pill "no lyrics · just vibes"
//                                with animated 3-bar waveform
//
//  See ~/.claude/skills/soft-pill-ui/references/live-lyrics.md.
//

import SwiftUI

struct LyricsView: View {
    @ObservedObject var store: LyricsStore
    let elapsed: Double
    let isPlaying: Bool

    private let lineHeight: CGFloat = 18
    private let visibleHalf = 2     // 2 above + active + 2 below = 5
    private let scrollerHeight: CGFloat = 18 * 5 + 16     // = 106pt
    private let compactHeight: CGFloat = 28

    /// What the current store state should render as.
    private enum Mode {
        case loading
        case empty
        case plain
        case synced
    }

    private var mode: Mode {
        if store.isLoading { return .loading }
        if store.lines.isEmpty && store.plain.isEmpty { return .empty }
        if store.lines.isEmpty { return .plain }
        return .synced
    }

    var body: some View {
        switch mode {
        case .loading:
            CompactLyricsPill(
                kind: .loading,
                isPlaying: isPlaying,
                height: compactHeight
            )
        case .empty:
            CompactLyricsPill(
                kind: .empty,
                isPlaying: isPlaying,
                height: compactHeight
            )
        case .plain, .synced:
            fullScroller
        }
    }

    // MARK: - Full scroller (used for synced lyrics + plain text)

    private var fullScroller: some View {
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
                if store.lines.isEmpty {
                    plainBlock
                } else {
                    syncedScroller
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .mask(fadeMask)
        }
        .frame(height: scrollerHeight)
        .clipped()
        .contentShape(Rectangle())
        .opacity(isPlaying ? 1.0 : 0.6)
        .animation(.easeOut(duration: 0.18), value: isPlaying)
    }

    /// 250ms look-ahead — the active line lights up SLIGHTLY before it is sung.
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

// MARK: - Compact pill (empty / loading)

/// Soft-pill row used for the two non-content lyric states. Matches the
/// dark notch aesthetic: faint white surface, subtle warm glow, animated
/// glyph on the left, label on the right. Total height = `height`.
private struct CompactLyricsPill: View {
    enum Kind { case loading, empty }
    let kind: Kind
    let isPlaying: Bool
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            glyph
                .frame(width: 18, height: 14)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if kind == .empty {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(accent.opacity(0.10), lineWidth: 0.5)
                )
        )
        .shadow(color: accent.opacity(0.18), radius: 6, y: 1)
        .opacity(isPlaying ? 1.0 : 0.55)
    }

    private var label: String {
        switch kind {
        case .loading: return "Looking for lyrics…"
        case .empty:   return "no lyrics · just vibes"
        }
    }

    private var textColor: Color {
        switch kind {
        case .loading: return .white.opacity(0.72)
        case .empty:   return .white.opacity(0.80)
        }
    }

    /// Spotify green (#1DB954) — matches the rest of the music-tab accents
    /// (transport play button glow, scrub bar fill, shuffle "on" state).
    private var accent: Color { Color(red: 0.114, green: 0.725, blue: 0.329) }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .loading:
            BreathingDots(color: accent)
        case .empty:
            WaveformGlyph(color: accent, isPlaying: isPlaying)
        }
    }
}

// MARK: - Animated glyphs

/// Three small dots that breathe out of phase. Used during the LRClib
/// fetch — feels alive without being noisy.
private struct BreathingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                dot(at: t, offset: 0)
                dot(at: t, offset: 1)
                dot(at: t, offset: 2)
            }
        }
    }

    private func dot(at t: TimeInterval, offset i: Int) -> some View {
        let omega = 2 * Double.pi / 1.1
        let raw = sin(t * omega + Double(i) * Double.pi / 3)
        let phase = (raw + 1) / 2
        let opacity = 0.35 + phase * 0.55
        let scale = 0.85 + CGFloat(phase) * 0.3
        return Circle()
            .fill(color.opacity(opacity))
            .frame(width: 4, height: 4)
            .scaleEffect(scale)
    }
}

/// Three bars that wobble like a tiny audio visualizer. Pauses when the
/// track is paused so the row reflects the playback state.
private struct WaveformGlyph: View {
    let color: Color
    let isPlaying: Bool

    private static let durations: [Double] = [0.42, 0.58, 0.50]
    private static let baseH: [CGFloat]    = [4, 9, 5]
    private static let peakH: [CGFloat]    = [11, 4, 10]

    @State private var phase = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(color.opacity(0.85))
                    .frame(width: 2.2, height: phase ? Self.peakH[i] : Self.baseH[i])
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: Self.durations[i]).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.18),
                        value: isPlaying ? phase : false
                    )
            }
        }
        .onAppear { phase = isPlaying }
        .onChange(of: isPlaying) { _, playing in phase = playing }
    }
}
