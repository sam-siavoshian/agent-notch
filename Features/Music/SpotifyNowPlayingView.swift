//
//  SpotifyNowPlayingView.swift
//  Agent in the Notch
//
//  Compact now-playing pill for the notch home tab. Hidden when Spotify
//  isn't running or no track is loaded.
//

import SwiftUI

struct SpotifyNowPlayingView: View {
    @ObservedObject private var controller = SpotifyController.shared

    var body: some View {
        Group {
            if controller.isRunning && controller.state.hasTrack {
                pill
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: controller.state.hasTrack)
        .animation(.easeOut(duration: 0.18), value: controller.isRunning)
    }

    private var pill: some View {
        HStack(spacing: 8) {
            artwork
            meta
            Spacer(minLength: 4)
            controls
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.base),
                glow: SoftPill.Status.green,
                cornerRadius: 11
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(count: 2) { controller.openSpotify() }
    }

    // MARK: - Pieces

    private var artwork: some View {
        Group {
            if let data = controller.state.artwork, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(SoftPill.Surface.inset)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SoftPill.Text.muted)
                    )
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(controller.state.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SoftPill.Text.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(controller.state.artist)
                .font(.system(size: 9))
                .foregroundStyle(SoftPill.Text.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            iconButton(system: "backward.fill", size: 9) {
                Task { await controller.previousTrack() }
            }
            iconButton(
                system: controller.state.isPlaying ? "pause.fill" : "play.fill",
                size: 11
            ) {
                Task { await controller.togglePlay() }
            }
            iconButton(system: "forward.fill", size: 9) {
                Task { await controller.nextTrack() }
            }
        }
    }

    private func iconButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(SoftPill.Text.primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
