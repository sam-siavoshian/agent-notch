//
//  NotchMusicView.swift
//  Agent in the Notch
//
//  Music tab. Three states:
//    1. Disconnected — Spotify mark + Connect button. No assumption that
//       Spotify is installed. Tapping Connect persists the choice + starts
//       listening for the system playback notification.
//    2. Connected, Spotify not running — Spotify mark + "Open Spotify" button.
//    3. Connected, Spotify playing/paused — full now-playing card with
//       artwork, title, artist, prev/play-pause/next, scrub bar.
//

import AppKit
import SwiftUI

struct NotchMusicView: View {
    @ObservedObject private var controller = SpotifyController.shared

    var body: some View {
        ZStack {
            if !controller.isConnected {
                disconnectedState
            } else if !controller.isRunning {
                connectedButIdleState
            } else {
                playingState
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.22), value: controller.isConnected)
        .animation(.easeOut(duration: 0.22), value: controller.isRunning)
        .animation(.easeOut(duration: 0.22), value: controller.state.hasTrack)
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
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                artwork.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.state.title.isEmpty ? "—" : controller.state.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(controller.state.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(SoftPill.Text.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !controller.state.album.isEmpty {
                        Text(controller.state.album)
                            .font(.system(size: 9))
                            .foregroundStyle(SoftPill.Text.muted.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                SpotifyMark(size: 14).opacity(0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                PillBackground(
                    fill: AnyShapeStyle(SoftPill.Surface.base),
                    glow: spotifyGreen,
                    cornerRadius: 12
                )
            )

            ScrubBar(
                current: controller.state.currentTime,
                duration: controller.state.duration
            ) { newPos in
                Task { await controller.seek(to: newPos) }
            }

            HStack(spacing: 6) {
                controlButton(system: "backward.fill") {
                    Task { await controller.previousTrack() }
                }
                controlButton(
                    system: controller.state.isPlaying ? "pause.fill" : "play.fill",
                    big: true
                ) {
                    Task { await controller.togglePlay() }
                }
                controlButton(system: "forward.fill") {
                    Task { await controller.nextTrack() }
                }
                Spacer(minLength: 4)
                openSpotifyButton
            }
        }
    }

    // MARK: - Pieces

    private var artwork: some View {
        Group {
            if let data = controller.state.artwork, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().interpolation(.medium).scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SoftPill.Surface.inset)
                    .overlay(Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.muted))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var openSpotifyButton: some View {
        Button { controller.openSpotify() } label: {
            HStack(spacing: 5) {
                SpotifyMark(size: 11)
                Text("Open")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(SoftPill.Text.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(SoftPill.Surface.inset))
        }
        .buttonStyle(.plain)
    }

    private var disconnectButton: some View {
        Button { controller.disconnect() } label: {
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

    private func controlButton(system: String, big: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: big ? 13 : 10, weight: .bold))
                .foregroundStyle(SoftPill.Text.primary)
                .frame(width: big ? 30 : 26, height: big ? 30 : 26)
                .background(
                    Circle().fill(big ? spotifyGreen.opacity(0.92)
                                       : SoftPill.Surface.inset)
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(big ? 0.20 : 0.06),
                                          lineWidth: 0.5)
                )
                .shadow(color: big ? spotifyGreen.opacity(0.40) : .clear,
                        radius: big ? 8 : 0, y: big ? 3 : 0)
        }
        .buttonStyle(.plain)
    }

    private var spotifyGreen: Color {
        Color(red: 0.114, green: 0.725, blue: 0.329) // #1DB954
    }
}

// MARK: - Spotify brand mark
//
// Green circle with three white sound waves. Drawn as native paths so we
// don't bundle a PNG/SVG asset. Trademark of Spotify AB — used here only
// to indicate integration with the Spotify desktop app, per their brand
// guidelines for third-party app references.

private struct SpotifyMark: View {
    var size: CGFloat = 24
    private let green = Color(red: 0.114, green: 0.725, blue: 0.329)

    var body: some View {
        ZStack {
            Circle().fill(green)
            GeometryReader { geo in
                let w = geo.size.width
                let lineWidth = w * 0.10
                // Three nested arcs, white, opening downward. Stagger via
                // both vertical offset AND radius so the arcs look concentric.
                arc(in: geo, yOffset: -0.18, radius: 0.34, lineWidth: lineWidth)
                arc(in: geo, yOffset: -0.04, radius: 0.27, lineWidth: lineWidth * 0.85)
                arc(in: geo, yOffset:  0.08, radius: 0.20, lineWidth: lineWidth * 0.72)
            }
            .padding(size * 0.12)
        }
        .frame(width: size, height: size)
    }

    private func arc(in geo: GeometryProxy, yOffset: CGFloat,
                     radius: CGFloat, lineWidth: CGFloat) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        return Path { p in
            let center = CGPoint(x: w / 2, y: h / 2 + yOffset * h)
            let r = w * radius
            p.addArc(center: center, radius: r,
                     startAngle: .degrees(200), endAngle: .degrees(-20),
                     clockwise: false)
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

// MARK: - Scrub bar

private struct ScrubBar: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragging: Double?

    private var displayed: Double { dragging ?? current }
    private var ratio: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, displayed / duration))
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SoftPill.Surface.inset)
                        .frame(height: 4)
                    Capsule()
                        .fill(Color(red: 0.114, green: 0.725, blue: 0.329))
                        .frame(width: max(2, CGFloat(ratio) * geo.size.width),
                               height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
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

            HStack {
                Text(format(displayed))
                Spacer()
                Text(format(duration))
            }
            .font(.system(size: 8.5, design: .monospaced))
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
