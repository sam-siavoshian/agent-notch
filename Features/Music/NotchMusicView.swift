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

private struct MusicStateKey: Equatable {
    let connected: Bool
    let running: Bool
    let hasTrack: Bool
}

struct NotchMusicView: View {
    @ObservedObject private var controller = SpotifyController.shared
    @StateObject private var lyrics = LyricsStore()

    /// Wall-clock anchor for predicted elapsed time between Spotify
    /// notification refreshes. Source-of-truth `currentTime` only updates
    /// on play/pause/seek/track-change — we predict in-between.
    @State private var anchorWall: Date = Date()
    @State private var anchorElapsed: Double = 0

    // Discovery section expand state. Folded by default so the music card
    // stays compact; each section pulls its data on first expand.
    @State private var queueExpanded = false
    @State private var devicesExpanded = false
    @State private var recentExpanded = false
    @State private var searchExpanded = false
    @State private var searchQuery: String = ""

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
        .animation(
            .easeOut(duration: 0.22),
            value: MusicStateKey(
                connected: controller.isConnected,
                running: controller.isRunning,
                hasTrack: controller.state.hasTrack
            )
        )
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
            // Spotify only broadcasts on play/pause/track-change. When the user
            // hits play after a long pause the cached currentTime may be stale,
            // so kick a refresh to re-anchor against the real player position.
            if nowPlaying { Task { await controller.refreshNow() } }
        }
        .onChange(of: controller.state.duration) { _, _ in
            // Duration arrives after title/artist sometimes — once we have it,
            // re-fetch with /api/get for an exact match.
            if lyrics.lines.isEmpty { refetchLyrics() }
        }
        .onAppear {
            anchorWall = Date()
            anchorElapsed = controller.state.currentTime
            refetchLyrics()
        }
    }

    /// Kick off a lyrics fetch from current controller state. Idempotent —
    /// LyricsStore short-circuits when the track key hasn't changed.
    private func refetchLyrics() {
        let t = controller.state.title
        let a = controller.state.artist
        let al = controller.state.album
        let d = controller.state.duration
        if !t.isEmpty, !a.isEmpty {
            lyrics.fetch(title: t, artist: a, album: al, duration: d)
        } else {
            lyrics.reset()
        }
    }

    /// Predicted elapsed seconds — base + wall-clock delta when playing.
    private func predictedElapsed() -> Double {
        guard controller.state.isPlaying else { return anchorElapsed }
        let delta = Date().timeIntervalSince(anchorWall)
        let raw = anchorElapsed + delta
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
        VStack(spacing: 8) {
            trackCard

            // Lyrics live directly under the track card — the natural
            // "what is this song saying" position. Renders only when there's
            // actual content (loading skeleton OR synced lines OR plain
            // text). Empty + not-loading state collapses to zero height so
            // the panel hugs the playing card.
            lyricsPanel

            ScrubBar(
                current: controller.state.currentTime,
                duration: controller.state.duration
            ) { newPos in
                Task { await controller.seek(to: newPos) }
            }

            HStack(spacing: 8) {
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

            secondaryControlsRow

            discoveryStack
        }
    }

    /// Power-user collapsible sections (Queue / Devices / Recently Played /
    /// Search). Visible only when the Web API is authed.
    @ViewBuilder
    private var discoveryStack: some View {
        if controller.webAPIReady {
            VStack(spacing: 6) {
                queueSection
                devicesSection
                recentSection
                searchSection
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Queue

    private var queueSection: some View {
        DiscoverySection(
            title: "Up Next",
            icon: "list.bullet",
            count: controller.queueSnapshot?.queue.count,
            expanded: $queueExpanded,
            inFlight: controller.queueInFlight,
            onRefresh: { Task { await controller.refreshQueue(force: true) } }
        ) {
            let queue = controller.queueSnapshot?.queue ?? []
            if queue.isEmpty {
                DiscoveryEmptyRow(text: controller.queueInFlight ? "Loading…" : "Queue is empty")
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(queue.prefix(5))) { item in
                        QueueRow(track: item)
                    }
                    if queue.count > 5 {
                        DiscoveryEmptyRow(text: "+ \(queue.count - 5) more in queue")
                    }
                }
            }
        }
        .onChange(of: queueExpanded) { _, expanded in
            if expanded { Task { await controller.refreshQueue() } }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        DiscoverySection(
            title: "Devices",
            icon: "hifispeaker.2.fill",
            count: controller.devices.count > 0 ? controller.devices.count : nil,
            expanded: $devicesExpanded,
            inFlight: controller.devicesInFlight,
            onRefresh: { Task { await controller.refreshDevices(force: true) } }
        ) {
            if controller.devices.isEmpty {
                DiscoveryEmptyRow(text: controller.devicesInFlight ? "Loading…" : "No devices found")
            } else {
                VStack(spacing: 2) {
                    ForEach(controller.devices) { device in
                        DeviceRow(device: device) {
                            Task { await controller.transferPlayback(toDeviceID: device.id) }
                        }
                    }
                }
            }
        }
        .onChange(of: devicesExpanded) { _, expanded in
            if expanded { Task { await controller.refreshDevices() } }
        }
    }

    // MARK: - Recently Played

    private var recentSection: some View {
        DiscoverySection(
            title: "Recently Played",
            icon: "clock.arrow.circlepath",
            count: controller.recentlyPlayed.count > 0 ? controller.recentlyPlayed.count : nil,
            expanded: $recentExpanded,
            inFlight: controller.recentlyPlayedInFlight,
            onRefresh: { Task { await controller.refreshRecentlyPlayed(force: true) } }
        ) {
            if controller.recentlyPlayed.isEmpty {
                if controller.recentlyPlayedNeedsReauth && !controller.recentlyPlayedInFlight {
                    ReconnectPrompt {
                        Task { _ = await controller.authenticateWebAPI() }
                    }
                } else {
                    DiscoveryEmptyRow(text: controller.recentlyPlayedInFlight ? "Loading…" : "Nothing to show yet")
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(controller.recentlyPlayed.prefix(10))) { item in
                        RecentRow(item: item) {
                            Task { await controller.playTrack(uri: item.uri) }
                        }
                    }
                }
            }
        }
        .onChange(of: recentExpanded) { _, expanded in
            if expanded { Task { await controller.refreshRecentlyPlayed() } }
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        DiscoverySection(
            title: "Search",
            icon: "magnifyingglass",
            count: nil,
            expanded: $searchExpanded,
            inFlight: controller.searchInFlight,
            onRefresh: nil
        ) {
            VStack(spacing: 4) {
                SearchPillField(text: $searchQuery)
                if !searchQuery.isEmpty {
                    if controller.searchResults.isEmpty && !controller.searchInFlight {
                        DiscoveryEmptyRow(text: "No results")
                    } else {
                        VStack(spacing: 2) {
                            ForEach(controller.searchResults) { result in
                                SearchResultRow(result: result,
                                                onPlay: { Task {
                                                    await controller.playTrack(uri: result.uri)
                                                    searchQuery = ""
                                                    searchExpanded = false
                                                } },
                                                onQueue: { Task {
                                                    _ = await controller.addToQueue(uri: result.uri)
                                                } })
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: searchQuery) { _, q in
            Task { await controller.search(q) }
        }
    }

    /// Shuffle / heart / repeat / add-to-playlist. Tier-2 features are only
    /// visible when the Web API is authed; Tier-1 (shuffle, boolean repeat)
    /// is always on.
    private var secondaryControlsRow: some View {
        HStack(spacing: 6) {
            // Shuffle (AppleScript)
            SecondaryToggleButton(
                system: "shuffle",
                isOn: controller.state.isShuffled,
                tint: spotifyGreen,
                help: "Shuffle \(controller.state.isShuffled ? "on" : "off")"
            ) {
                Task { await controller.toggleShuffle() }
            }

            // Like / heart (Web API only) — hidden until authed.
            if controller.webAPIReady {
                SecondaryToggleButton(
                    system: (controller.state.isLiked == true) ? "heart.fill" : "heart",
                    isOn: controller.state.isLiked == true,
                    tint: Color(red: 0xF3/255, green: 0x7A/255, blue: 0x7A/255),
                    help: (controller.state.isLiked == true)
                          ? "Remove from Liked Songs"
                          : "Save to Liked Songs"
                ) {
                    Task { await controller.toggleLiked() }
                }
                .disabled(controller.state.trackID.isEmpty)
            }

            // Repeat — cycles off / context / track when authed; off ↔ context otherwise.
            SecondaryToggleButton(
                system: controller.state.repeatMode.displaySymbol,
                isOn: controller.state.repeatMode != .off,
                tint: spotifyGreen,
                help: repeatTooltip
            ) {
                Task { await controller.cycleRepeatMode() }
            }

            Spacer(minLength: 2)

            // Add-to-playlist menu (Web API only). Hidden when unauthed —
            // we don't show a "Sign in" pill in this row; users sign in via
            // Advanced Settings (or auto-triggered when they tap a
            // discovery action that needs it).
            if controller.webAPIReady,
               !controller.playlists.isEmpty,
               !controller.state.trackURI.isEmpty {
                AddToPlaylistMenu(
                    playlists: controller.playlists.filter { $0.canModify },
                    tint: spotifyGreen
                ) { playlist in
                    Task {
                        _ = await controller.addCurrentTrackToPlaylist(id: playlist.id)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var repeatTooltip: String {
        switch controller.state.repeatMode {
        case .off:     return controller.webAPIReady ? "Repeat off → all" : "Repeat off → all"
        case .context: return controller.webAPIReady ? "Repeat all → track" : "Repeat all → off"
        case .track:   return "Repeat track → off"
        }
    }

    /// Live lyrics card. LyricsView handles its own height per state:
    /// - synced / plain → 106pt scroller
    /// - loading        → 28pt "Looking for lyrics…" soft pill
    /// - empty          → 28pt "no lyrics · just vibes" pill with mini
    ///                    waveform glyph
    /// `TimelineView` re-runs every ~500ms to drive predicted elapsed —
    /// lyrics lines last 2-4s typically, so 500ms granularity feels live
    /// without burning 4 redraws/sec on the ForEach scroller.
    @ViewBuilder
    private var lyricsPanel: some View {
        if controller.state.hasTrack {
            TimelineView(.animation(minimumInterval: 0.5, paused: !controller.state.isPlaying)) { _ in
                LyricsView(
                    store: lyrics,
                    elapsed: predictedElapsed(),
                    isPlaying: controller.state.isPlaying
                )
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var trackCard: some View {
        let showAlbum = !controller.state.album.isEmpty
            && controller.state.album.caseInsensitiveCompare(controller.state.title) != .orderedSame

        return HStack(spacing: 10) {
            artwork
                .frame(width: 40, height: 40)
                .shadow(color: spotifyGreen.opacity(0.22), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.state.title.isEmpty ? "—" : controller.state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(SoftPill.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(controller.state.artist)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SoftPill.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showAlbum {
                    Text(controller.state.album)
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
                // top inner highlight — sells the dimension
                RoundedRectangle(cornerRadius: 13, style: .continuous)
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
        .overlay(
            // resting green ambient — faint, only on the card edge
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(spotifyGreen.opacity(0.08), lineWidth: 0.5)
        )
        // Composite the artwork shadow + PillBackground glow + overlay
        // strokes into one offscreen layer so we don't pay per-frame
        // compositing on every track-state tick.
        .compositingGroup()
    }

    // MARK: - Pieces

    private var artwork: some View {
        Group {
            if let data = controller.state.artwork, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().interpolation(.medium).scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SoftPill.Surface.inset)
                    .overlay(Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.muted))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var openSpotifyButton: some View {
        OpenSpotifyPill(action: { controller.openSpotify() })
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
        TransportButton(system: system, big: big,
                        spotifyGreen: spotifyGreen, action: action)
    }

    /// Stored `let` so each body eval is a property load, not a re-execution
    /// of a computed property + indirection through a static.
    private let spotifyGreen = Color(red: 0.114, green: 0.725, blue: 0.329) // #1DB954
}

// MARK: - Transport button (prev / play / next)

private struct TransportButton: View {
    let system: String
    let big: Bool
    let spotifyGreen: Color
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
                        spotifyGreen.opacity(1.0),
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
    private static let _green = Color(red: 0.114, green: 0.725, blue: 0.329)
    private var green: Color { Self._green }

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
                            .stroke(green.opacity(hovered ? 0.35 : 0.0), lineWidth: 0.8)
                    )
                    .shadow(color: green.opacity(hovered ? 0.35 : 0.0),
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
// Renders the official Spotify glyph from an inline SVG (single-path,
// even-odd fill — the sound-wave cutouts are baked into the path). Loaded
// via NSImage(data:) which natively decodes SVG on macOS 13+. The image
// is templated so .foregroundStyle controls the color.
//
// Trademark of Spotify AB. Used per Spotify's third-party brand guidelines
// to indicate integration with the Spotify desktop app.

struct SpotifyMark: View {
    var size: CGFloat = 24
    private let green = Color(red: 0.114, green: 0.725, blue: 0.329)

    var body: some View {
        Image(nsImage: Self.glyph)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(green)
    }

    // Decode once, share across all instances.
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

    private static let _green       = Color(red: 0.114, green: 0.725, blue: 0.329)
    private static let _greenBright = Color(red: 0.30,  green: 0.92,  blue: 0.50)
    private var green: Color       { Self._green }
    private var greenBright: Color { Self._greenBright }

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
                                colors: [greenBright, green],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: filled, height: 4)
                        .shadow(color: green.opacity(isInteracting ? 0.7 : 0.45),
                                radius: isInteracting ? 6 : 3, y: 0)

                    // Thumb — appears on hover/drag
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(green.opacity(0.6), lineWidth: 0.5))
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

// MARK: - Secondary toggle (shuffle / heart / repeat)

private struct SecondaryToggleButton: View {
    let system: String
    let isOn: Bool
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(isOn ? tint : SoftPill.Text.secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(hovered ? SoftPill.Surface.hover : SoftPill.Surface.inset)
                )
                .overlay(
                    Circle().strokeBorder(
                        isOn ? tint.opacity(hovered ? 0.6 : 0.35)
                             : Color.white.opacity(hovered ? 0.12 : 0.05),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: isOn ? tint.opacity(hovered ? 0.45 : 0.25) : .clear,
                        radius: isOn ? (hovered ? 6 : 3) : 0, y: 0)
                .scaleEffect(pressed ? 0.92 : (hovered ? 1.05 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(.easeOut(duration: 0.14), value: hovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.78), value: pressed)
        .help(help)
    }
}

// MARK: - Add-to-playlist menu

private struct AddToPlaylistMenu: View {
    let playlists: [SpotifyPlaylist]
    let tint: Color
    let onPick: (SpotifyPlaylist) -> Void

    @State private var hovered = false

    var body: some View {
        Menu {
            // Cap at 50 entries to keep the menu sane. Most users have far fewer.
            ForEach(playlists.prefix(50)) { playlist in
                Button(playlist.name) { onPick(playlist) }
            }
            if playlists.count > 50 {
                Divider()
                Text("+\(playlists.count - 50) more, use voice")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                Text("Playlist")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(hovered ? SoftPill.Text.primary : SoftPill.Text.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? SoftPill.Surface.hover : SoftPill.Surface.inset)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(hovered ? 0.35 : 0.1), lineWidth: 0.8)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Add this track to a playlist")
    }
}

// MARK: - Connect-cloud pill (shown when Web API isn't authed yet)

private struct ConnectCloudPill: View {
    let tint: Color
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Sign in")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(hovered ? SoftPill.Text.primary : SoftPill.Text.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? SoftPill.Surface.hover : SoftPill.Surface.inset)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tint.opacity(hovered ? 0.45 : 0.15), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .help("Sign in to Spotify for Like + Add-to-Playlist + 3-state repeat")
    }
}

// MARK: - DiscoverySection (reusable collapsible header + body)

private struct DiscoverySection<Content: View>: View {
    let title: String
    let icon: String
    let count: Int?
    @Binding var expanded: Bool
    let inFlight: Bool
    let onRefresh: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            header
            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Section-local animation for the chevron rotation + content
        // transition. The panel-height growth is driven by the parent
        // notch's spring via `withAnimation` in the toggle below.
        .animation(NotchContentView.notchSpring, value: expanded)
    }

    private var header: some View {
        Button {
            // Drive the toggle inside the shared notch spring so the whole
            // panel — chevron, section body, AND notch height — animates
            // as one motion instead of two stutter-steps.
            withAnimation(NotchContentView.notchSpring) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.muted)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.secondary)
                if let count, count > 0 {
                    Text("·  \(count)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(SoftPill.Text.muted)
                }
                Spacer(minLength: 0)
                if inFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                }
                if let onRefresh, expanded {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SoftPill.Text.muted)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(SoftPill.Text.muted)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? SoftPill.Surface.hover : SoftPill.Surface.inset.opacity(0.45))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct DiscoveryEmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(SoftPill.Text.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
    }
}

private struct DiscoveryArtwork: View {
    let url: String?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable()
                    } else {
                        Rectangle().fill(SoftPill.Surface.inset)
                    }
                }
            } else {
                Rectangle().fill(SoftPill.Surface.inset)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - Row variants

private struct QueueRow: View {
    let track: SpotifyQueuedTrack

    var body: some View {
        HStack(spacing: 8) {
            DiscoveryArtwork(url: track.artworkURL, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SoftPill.Text.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(SoftPill.Text.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

private struct DeviceRow: View {
    let device: SpotifyDevice
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(device.isActive
                                     ? Color(red: 0.114, green: 0.725, blue: 0.329)
                                     : SoftPill.Text.muted)
                    .frame(width: 14)
                Text(device.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SoftPill.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if device.isActive {
                    Circle()
                        .fill(Color(red: 0.114, green: 0.725, blue: 0.329))
                        .frame(width: 5, height: 5)
                        .shadow(color: Color(red: 0.114, green: 0.725, blue: 0.329).opacity(0.6), radius: 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? SoftPill.Surface.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(device.isActive)
        .help(device.isActive ? "Active device" : "Transfer playback to \(device.name)")
    }

    private var iconName: String {
        switch device.type.lowercased() {
        case "computer":            return "laptopcomputer"
        case "smartphone":          return "iphone"
        case "tablet":              return "ipad"
        case "speaker", "avr":      return "hifispeaker.fill"
        case "tv":                  return "tv"
        case "automobile":          return "car.fill"
        case "stb":                 return "appletv.fill"
        case "audiodongle":         return "wave.3.right"
        case "gameconsole":         return "gamecontroller.fill"
        case "castaudio", "castvideo": return "airplayaudio"
        default:                    return "hifispeaker.2.fill"
        }
    }
}

private struct RecentRow: View {
    let item: SpotifyRecentItem
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                DiscoveryArtwork(url: item.artworkURL, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SoftPill.Text.primary)
                        .lineLimit(1)
                    Text(item.artist)
                        .font(.system(size: 9))
                        .foregroundStyle(SoftPill.Text.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(Self.relative.localizedString(for: item.playedAt, relativeTo: Date()))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(SoftPill.Text.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered ? SoftPill.Surface.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Play \(item.title)")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct SearchPillField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SoftPill.Text.muted)
            TextField("Search Spotify…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(SoftPill.Text.primary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SoftPill.Text.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(SoftPill.Surface.inset)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
}

private struct SearchResultRow: View {
    let result: SpotifySearchResult
    let onPlay: () -> Void
    let onQueue: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            DiscoveryArtwork(url: result.artworkURL, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(result.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SoftPill.Text.primary)
                    .lineLimit(1)
                Text(result.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(SoftPill.Text.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered {
                Button(action: onQueue) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SoftPill.Text.muted)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Add to queue")
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.114, green: 0.725, blue: 0.329))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Play now")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? SoftPill.Surface.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hovered = $0 }
    }
}

private struct ReconnectPrompt: View {
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text("Reconnect Spotify to enable")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color(red: 0.114, green: 0.725, blue: 0.329))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.114, green: 0.725, blue: 0.329).opacity(hovered ? 0.18 : 0.10))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
