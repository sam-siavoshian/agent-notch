//
//  NotchMusicView.swift
//  Agent in the Notch
//
//  Music tab. Three states: disconnected / connected-but-idle / playing.
//

import AppKit
import SwiftUI

/// Spotify brand green (#1DB954). Trademark of Spotify AB; used per
/// third-party brand guidelines to indicate integration.
private let spotifyGreen = Color(red: 0.114, green: 0.725, blue: 0.329)

struct NotchMusicView: View {
    @ObservedObject private var controller = SpotifyController.shared
    @StateObject private var lyrics = LyricsStore()

    /// Wall-clock anchor for predicted elapsed time between Spotify
    /// notification refreshes (source-of-truth `currentTime` only updates on
    /// play/pause/seek/track-change).
    @State private var anchorWall: Date = Date()
    @State private var anchorElapsed: Double = 0

    private var trackKey: String { controller.state.title + "|" + controller.state.artist }

    var body: some View {
        Group {
            if !controller.isConnected {
                disconnectedState
            } else if !controller.isRunning {
                connectedButIdleState
            } else {
                playingState
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.22), value: controller.isConnected)
        .animation(.easeOut(duration: 0.22), value: controller.isRunning)
        .animation(.easeOut(duration: 0.22), value: controller.state.hasTrack)
        .onChange(of: trackKey) { _, _ in
            anchorWall = Date()
            anchorElapsed = controller.state.currentTime
            refetchLyrics()
        }
        .onChange(of: controller.state.currentTime) { _, newVal in
            anchorWall = Date()
            anchorElapsed = newVal
        }
        .onChange(of: controller.state.isPlaying) { _, nowPlaying in
            anchorWall = Date()
            anchorElapsed = controller.state.currentTime
            // Re-anchor against real player position; cached time may be stale
            // after a long pause (no notification fires until next track).
            if nowPlaying { Task { await controller.refreshNow() } }
        }
        .onChange(of: controller.state.duration) { _, _ in
            // Duration sometimes arrives after title/artist; re-fetch /api/get
            // for an exact match once we have it.
            if lyrics.lines.isEmpty { refetchLyrics() }
        }
        .onAppear {
            anchorWall = Date()
            anchorElapsed = controller.state.currentTime
            refetchLyrics()
        }
    }

    private func refetchLyrics() {
        let s = controller.state
        if !s.title.isEmpty, !s.artist.isEmpty {
            lyrics.fetch(title: s.title, artist: s.artist, album: s.album, duration: s.duration)
        } else {
            lyrics.reset()
        }
    }

    /// Predicted elapsed seconds — base + wall-clock delta when playing.
    private func predictedElapsed() -> Double {
        guard controller.state.isPlaying else { return anchorElapsed }
        let raw = anchorElapsed + Date().timeIntervalSince(anchorWall)
        let dur = controller.state.duration
        return dur > 0 ? min(max(raw, 0), dur) : max(raw, 0)
    }

    // MARK: - States

    private var disconnectedState: some View {
        VStack(spacing: 10) {
            SpotifyMark(size: 32)
            VStack(spacing: 2) {
                Text("Connect Spotify")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.primary)
                Text("Read currently playing track and control playback.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(SoftPill.Text.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                controller.connect()
            } label: {
                Text("Connect")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(spotifyGreen)
                    )
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: spotifyGreen.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .help("Begin listening for Spotify playback")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    private var connectedButIdleState: some View {
        VStack(spacing: 8) {
            SpotifyMark(size: 28)
            Text("Spotify isn't running")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SoftPill.Text.secondary)
            HStack(spacing: 6) {
                openSpotifyButton
                disconnectButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var playingState: some View {
        VStack(spacing: 6) {
            trackCard

            ScrubBar(
                current: controller.state.currentTime,
                duration: controller.state.duration
            ) { newPos in
                Task { await controller.seek(to: newPos) }
            }

            HStack(spacing: 8) {
                TransportButton(system: "backward.fill") {
                    Task { await controller.previousTrack() }
                }
                TransportButton(
                    system: controller.state.isPlaying ? "pause.fill" : "play.fill",
                    big: true
                ) {
                    Task { await controller.togglePlay() }
                }
                TransportButton(system: "forward.fill") {
                    Task { await controller.nextTrack() }
                }
                Spacer(minLength: 4)
                openSpotifyButton
            }

            lyricsPanel
        }
    }

    /// LyricsView handles its own loading / empty / no-match states.
    /// TimelineView re-runs ~4x/s to drive predicted elapsed.
    @ViewBuilder
    private var lyricsPanel: some View {
        if controller.state.hasTrack {
            TimelineView(.animation(minimumInterval: 0.25, paused: !controller.state.isPlaying)) { _ in
                LyricsView(
                    store: lyrics,
                    elapsed: predictedElapsed(),
                    isPlaying: controller.state.isPlaying
                )
            }
            .padding(.top, 2)
            .transition(.opacity)
        }
    }

    private var trackCard: some View {
        let s = controller.state
        let showAlbum = !s.album.isEmpty
            && s.album.caseInsensitiveCompare(s.title) != .orderedSame
        let cardShape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        return HStack(spacing: 10) {
            artwork
                .frame(width: 40, height: 40)
                .shadow(color: spotifyGreen.opacity(0.22), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.title.isEmpty ? "—" : s.title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(SoftPill.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(s.artist)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SoftPill.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showAlbum {
                    Text(s.album)
                        .font(.system(size: 9.5))
                        .foregroundStyle(SoftPill.Text.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            SpotifyMark(size: 13).opacity(0.55)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            ZStack {
                PillBackground(
                    fill: AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0x22/255, green: 0x24/255, blue: 0x29/255),
                                Color(red: 0x16/255, green: 0x17/255, blue: 0x1B/255)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    ),
                    glow: spotifyGreen,
                    cornerRadius: 13
                )
                cardShape
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), .clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        )
        .overlay(cardShape.stroke(spotifyGreen.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: - Pieces

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if let data = controller.state.artwork, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().interpolation(.medium).scaledToFill()
            } else {
                shape
                    .fill(SoftPill.Surface.inset)
                    .overlay(Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.muted))
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    private var openSpotifyButton: some View {
        OpenSpotifyPill(action: controller.openSpotify)
    }

    private var disconnectButton: some View {
        Button(action: controller.disconnect) {
            Text("Disconnect")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SoftPill.Text.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().strokeBorder(SoftPill.Text.muted.opacity(0.35),
                                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transport button (prev / play / next)

private struct TransportButton: View {
    let system: String
    var big: Bool = false
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: big ? 12 : 9.5, weight: .bold))
                .foregroundStyle(big ? Color.black.opacity(0.88) : SoftPill.Text.primary)
                .frame(width: big ? 30 : 26, height: big ? 30 : 26)
                .background(transportFill)
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(big ? 0.28 : (hovered ? 0.14 : 0.06)),
                        lineWidth: 0.5
                    )
                )
                .overlay(
                    // top inner highlight on the green orb
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(big ? 0.55 : 0.18), .clear],
                                startPoint: .top, endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
                .shadow(
                    color: big ? spotifyGreen.opacity(hovered ? 0.65 : 0.45)
                               : Color.black.opacity(0.35),
                    radius: big ? (hovered ? 14 : 10) : (hovered ? 6 : 3),
                    y: big ? (hovered ? 5 : 3) : (hovered ? 2 : 1)
                )
                .scaleEffect(pressed ? 0.93 : (hovered ? 1.04 : 1.0))
                .brightness(pressed ? -0.04 : (hovered ? 0.03 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.78), value: pressed)
    }

    @ViewBuilder
    private var transportFill: some View {
        if big {
            Circle().fill(
                RadialGradient(
                    colors: [
                        spotifyGreen,
                        Color(red: 0x16/255, green: 0xA3/255, blue: 0x4A/255)
                    ],
                    center: .topLeading, startRadius: 2, endRadius: 36
                )
            )
        } else {
            Circle().fill(hovered ? SoftPill.Surface.hover : SoftPill.Surface.inset)
        }
    }
}

// MARK: - Open Spotify pill

private struct OpenSpotifyPill: View {
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                SpotifyMark(size: 11)
                Text("Open")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(hovered ? SoftPill.Text.primary : SoftPill.Text.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? SoftPill.Surface.hover : SoftPill.Surface.inset)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(spotifyGreen.opacity(hovered ? 0.35 : 0.0), lineWidth: 0.8)
                    )
                    .shadow(color: spotifyGreen.opacity(hovered ? 0.35 : 0.0),
                            radius: hovered ? 8 : 0, y: hovered ? 2 : 0)
            )
            .scaleEffect(pressed ? 0.96 : (hovered ? 1.02 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.78), value: pressed)
    }
}

// MARK: - Spotify brand mark
//
// Inline SVG (single-path, even-odd fill) decoded once via NSImage(data:).
// Templated so .foregroundStyle controls the color.

struct SpotifyMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: Self.glyph)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(spotifyGreen)
    }

    private static let glyph: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
        <path d="M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12C24 5.4 18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z"/>
        </svg>
        """
        let data = svg.data(using: .utf8) ?? Data()
        let img = NSImage(data: data) ?? NSImage()
        img.isTemplate = true
        return img
    }()
}

// MARK: - Scrub bar

private struct ScrubBar: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragging: Double?
    @State private var hovered = false

    private let greenBright = Color(red: 0.30, green: 0.92, blue: 0.50)

    private var displayed: Double { dragging ?? current }
    private var ratio: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, displayed / duration))
    }
    private var isInteracting: Bool { hovered || dragging != nil }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let filled = max(2, CGFloat(ratio) * geo.size.width)
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(SoftPill.Surface.inset)
                        .frame(height: 4)
                        .overlay(
                            Capsule()
                                .stroke(Color.black.opacity(0.45), lineWidth: 0.5)
                        )

                    // Played fill — gradient + glow
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [greenBright, spotifyGreen],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: filled, height: 4)
                        .shadow(color: spotifyGreen.opacity(isInteracting ? 0.7 : 0.45),
                                radius: isInteracting ? 6 : 3, y: 0)

                    // Thumb — appears on hover/drag
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(spotifyGreen.opacity(0.6), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: filled - 4.5)
                        .opacity(isInteracting ? 1 : 0)
                        .scaleEffect(isInteracting ? 1 : 0.6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let r = max(0, min(1, v.location.x / geo.size.width))
                            dragging = r * duration
                        }
                        .onEnded { _ in
                            if let d = dragging { onSeek(d); dragging = nil }
                        }
                )
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.16), value: isInteracting)

            HStack {
                Text(format(displayed))
                Spacer()
                Text(format(duration))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(SoftPill.Text.muted)
        }
        .padding(.horizontal, 4)
        .opacity(duration > 0 ? 1 : 0.4)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
