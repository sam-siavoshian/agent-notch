//
//  SpotifyController.swift
//  Agent in the Notch
//
//  Lightest possible Spotify integration. No OAuth, no Web API, no SDK.
//  Two mechanisms only:
//    1. DistributedNotificationCenter observes "com.spotify.client.PlaybackStateChanged"
//       — Spotify broadcasts this on every play/pause/track-change.
//    2. AppleScript pulls current track + position when the notification fires.
//  Controls are AppleScript tells: "tell application Spotify to <command>".
//
//  Ported from boring.notch (MIT). Trimmed to single-controller, no protocol,
//  no Combine, plain @Published ObservableObject so it slots into our notch.
//

import AppKit
import Foundation
import SwiftUI

struct SpotifyPlaybackState: Equatable {
    var isPlaying: Bool = false
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var currentTime: Double = 0
    var duration: Double = 0
    var isShuffled: Bool = false
    var isRepeating: Bool = false
    var volume: Double = 0.5
    var artworkURL: String = ""
    var artwork: Data?

    /// True iff Spotify is running AND there is a real track loaded.
    var hasTrack: Bool { !title.isEmpty && title != "Unknown" }
}

@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()

    @Published private(set) var state = SpotifyPlaybackState()
    @Published private(set) var isRunning = false

    private var notificationTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkURL: String?
    private let commandDelay: Duration = .milliseconds(40)

    private init() {}

    /// Begin observing Spotify. Safe to call multiple times.
    func start() {
        guard notificationTask == nil else { return }
        refreshRunningState()
        notificationTask = Task { [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            for await _ in notifications {
                await self?.refresh()
            }
        }
        // Initial fetch in case Spotify is already playing on launch.
        Task { await refresh() }
    }

    func stop() {
        notificationTask?.cancel()
        notificationTask = nil
        artworkTask?.cancel()
        artworkTask = nil
    }

    // MARK: - Controls

    func togglePlay() async { await sendCommand("playpause") }
    func nextTrack() async { await sendAndRefresh("next track") }
    func previousTrack() async { await sendAndRefresh("previous track") }
    func seek(to time: Double) async { await sendAndRefresh("set player position to \(time)") }
    func setVolume(_ level: Double) async {
        let v = Int((max(0, min(1, level)) * 100).rounded())
        await sendCommand("set sound volume to \(v)")
        try? await Task.sleep(for: commandDelay)
        await refresh()
    }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: - Internals

    private func refreshRunningState() {
        isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.spotify.client"
        }
    }

    private func refresh() async {
        refreshRunningState()
        guard isRunning else {
            if state != SpotifyPlaybackState() { state = SpotifyPlaybackState() }
            return
        }
        guard let descriptor = try? await fetchPlayback(),
              descriptor.numberOfItems >= 10 else { return }

        let new = SpotifyPlaybackState(
            isPlaying: descriptor.atIndex(1)?.booleanValue ?? false,
            title: descriptor.atIndex(2)?.stringValue ?? "",
            artist: descriptor.atIndex(3)?.stringValue ?? "",
            album: descriptor.atIndex(4)?.stringValue ?? "",
            currentTime: descriptor.atIndex(5)?.doubleValue ?? 0,
            // Spotify's `duration of current track` returns milliseconds.
            duration: (descriptor.atIndex(6)?.doubleValue ?? 0) / 1000,
            isShuffled: descriptor.atIndex(7)?.booleanValue ?? false,
            isRepeating: descriptor.atIndex(8)?.booleanValue ?? false,
            volume: Double(descriptor.atIndex(9)?.int32Value ?? 50) / 100.0,
            artworkURL: descriptor.atIndex(10)?.stringValue ?? "",
            artwork: state.artwork // keep prior bytes; replaced after fetch below
        )

        // If the artwork URL is unchanged, keep the existing bytes — no flash.
        if new.artworkURL == lastArtworkURL && state.artwork != nil {
            state = new
            return
        }

        // Apply track metadata immediately; artwork lands after the network fetch.
        var pending = new
        pending.artwork = nil
        state = pending

        if !new.artworkURL.isEmpty, let url = URL(string: new.artworkURL) {
            artworkTask?.cancel()
            artworkTask = Task { [weak self] in
                guard let data = try? await Self.fetchArtwork(url: url) else { return }
                await MainActor.run {
                    guard let self else { return }
                    var s = self.state
                    s.artwork = data
                    self.state = s
                    self.lastArtworkURL = new.artworkURL
                    self.artworkTask = nil
                }
            }
        } else {
            lastArtworkURL = nil
        }
    }

    private func sendCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func sendAndRefresh(_ command: String) async {
        await sendCommand(command)
        try? await Task.sleep(for: commandDelay)
        await refresh()
    }

    private func fetchPlayback() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
            on error
                return {false, "", "", "", 0, 0, false, false, 50, ""}
            end try
        end tell
        """
        return try await AppleScriptHelper.execute(script)
    }

    private static func fetchArtwork(url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}
