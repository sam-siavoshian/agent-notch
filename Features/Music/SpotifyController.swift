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
    @Published private(set) var isConnected = false

    private let connectedKey = "spotify.connected"
    private var notificationTask: Task<Void, Never>?
    private var runningPollTask: Task<Void, Never>?
    private var positionPollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkURL: String?
    private let commandDelay: Duration = .milliseconds(40)

    private init() {}

    /// True once the user has tapped Connect. Persisted across launches.
    var hasEverConnected: Bool {
        UserDefaults.standard.bool(forKey: connectedKey)
    }

    /// Resume the connection at launch if user previously opted in.
    func startIfPreviouslyConnected() {
        guard hasEverConnected else { return }
        connect()
    }

    /// User tapped Connect. Begins listening + persists the choice.
    func connect() {
        guard !isConnected else { return }
        isConnected = true
        UserDefaults.standard.set(true, forKey: connectedKey)
        refreshRunningState()
        notificationTask = Task { [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            for await _ in notifications {
                await self?.refresh()
            }
        }
        // No system notification fires when Spotify itself launches/quits.
        runningPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.refreshRunningStateAndMaybeFetch()
            }
        }
        // PlaybackStateChanged doesn't fire on external seeks, so poll position
        // while playing so the lyrics anchor stays accurate.
        positionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { continue }
                if self.shouldPollPosition() { await self.refresh() }
            }
        }
        Task { await refresh() }
    }

    /// View can force a fresh AppleScript pull (cached currentTime may be stale
    /// after a long pause; no notification fires until the next track change).
    func refreshNow() async { await refresh() }

    private func shouldPollPosition() -> Bool {
        isConnected && isRunning && state.isPlaying
    }

    /// User tapped Disconnect. Stops listening + clears state.
    func disconnect() {
        isConnected = false
        UserDefaults.standard.set(false, forKey: connectedKey)
        notificationTask?.cancel(); notificationTask = nil
        runningPollTask?.cancel(); runningPollTask = nil
        positionPollTask?.cancel(); positionPollTask = nil
        artworkTask?.cancel(); artworkTask = nil
        state = SpotifyPlaybackState()
        lastArtworkURL = nil
    }

    private func refreshRunningStateAndMaybeFetch() async {
        let wasRunning = isRunning
        refreshRunningState()
        if isRunning && !wasRunning {
            await refresh()
        } else if !isRunning && wasRunning {
            state = SpotifyPlaybackState()
        }
    }

    // MARK: - Controls

    func togglePlay() async { await sendCommand("playpause") }
    func nextTrack() async { await sendAndRefresh("next track") }
    func previousTrack() async { await sendAndRefresh("previous track") }
    func seek(to time: Double) async { await sendAndRefresh("set player position to \(time)") }

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
              descriptor.numberOfItems >= 7 else { return }

        let new = SpotifyPlaybackState(
            isPlaying: descriptor.atIndex(1)?.booleanValue ?? false,
            title: descriptor.atIndex(2)?.stringValue ?? "",
            artist: descriptor.atIndex(3)?.stringValue ?? "",
            album: descriptor.atIndex(4)?.stringValue ?? "",
            currentTime: descriptor.atIndex(5)?.doubleValue ?? 0,
            // Spotify's `duration of current track` returns milliseconds.
            duration: (descriptor.atIndex(6)?.doubleValue ?? 0) / 1000,
            artworkURL: descriptor.atIndex(7)?.stringValue ?? "",
            artwork: state.artwork
        )

        // Same URL → keep existing bytes to avoid an artwork flash.
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
                set artworkURL to artwork url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, artworkURL}
            on error
                return {false, "", "", "", 0, 0, ""}
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
