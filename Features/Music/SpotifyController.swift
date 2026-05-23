//
//  SpotifyController.swift
//  Agent in the Notch
//
//  Two-tier Spotify integration:
//
//    Tier 1 — AppleScript only, no auth, always available
//    - DistributedNotificationCenter observes "com.spotify.client.PlaybackStateChanged"
//      (broadcast on play/pause/track-change).
//    - AppleScript pulls track metadata + transport state + drives play / pause /
//      next / prev / seek / shuffle / boolean-repeat / volume.
//
//    Tier 2 — Web API (PKCE OAuth), opt-in, optional
//    - Adds three-state repeat (off/track/context), save-to-library, add-to-
//      playlist, and a cached playlists list. Token storage in Keychain.
//    - When un-authed, all Tier-1 controls still work; Tier-2 features no-op
//      gracefully (UI hides the affordances).
//
//  Originally ported from boring.notch (MIT). Tier 2 is local code.
//

import AppKit
import Foundation
import SwiftUI

/// Three-state repeat mode. AppleScript only exposes a boolean on macOS
/// Spotify.app today, so without Web API auth we cycle `off <-> all` and
/// surface `track` only when the Web API is authed.
public enum SpotifyRepeatMode: String, Codable, Sendable {
    case off
    case track
    case context   // a.k.a. "all" / repeat-playlist

    var next: SpotifyRepeatMode {
        switch self {
        case .off:     return .context
        case .context: return .track
        case .track:   return .off
        }
    }

    /// AppleScript boolean fallback — `track` and `context` both map to ON.
    var appleScriptBool: Bool {
        switch self {
        case .off: return false
        case .track, .context: return true
        }
    }

    var displaySymbol: String {
        switch self {
        case .off, .context: return "repeat"
        case .track:         return "repeat.1"
        }
    }
}

struct SpotifyPlaybackState: Equatable {
    var isPlaying: Bool = false
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var currentTime: Double = 0
    var duration: Double = 0
    var isShuffled: Bool = false
    /// Legacy boolean — kept for back-compat. New consumers should read
    /// `repeatMode`.
    var isRepeating: Bool { repeatMode != .off }
    var repeatMode: SpotifyRepeatMode = .off
    var volume: Double = 0.5
    var artworkURL: String = ""
    var artwork: Data?
    /// Spotify track URI — `spotify:track:<id>`. Empty when no track loaded.
    var trackURI: String = ""
    /// Whether the current track is in the user's Liked Songs library.
    /// `nil` while unknown (no Web API auth or not yet checked).
    var isLiked: Bool? = nil

    /// True iff Spotify is running AND there is a real track loaded.
    var hasTrack: Bool { !title.isEmpty && title != "Unknown" }

    /// Bare Spotify track ID (`<id>` from `spotify:track:<id>`), or "" when missing.
    var trackID: String {
        // Spotify uses `spotify:track:<id>` URIs from AppleScript.
        let parts = trackURI.split(separator: ":")
        guard parts.count >= 3, parts[parts.count - 2] == "track" else { return "" }
        return String(parts.last ?? "")
    }
}

@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()

    @Published private(set) var state = SpotifyPlaybackState()
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    /// True when the Spotify Web API is reachable with a valid token.
    /// Drives whether 3-state repeat, save, and add-to-playlist are exposed.
    @Published private(set) var webAPIReady: Bool = false
    /// Last user-facing error from a Web API call, if any. Cleared on success.
    @Published private(set) var lastWebError: String? = nil
    /// Cached playlists for fuzzy-match "add to <name>" intent. Refreshed
    /// after auth + on demand.
    @Published private(set) var playlists: [SpotifyPlaylist] = []

    // MARK: - Discovery state (lazy — populated on section expand)

    @Published private(set) var searchResults: [SpotifySearchResult] = []
    @Published private(set) var queueSnapshot: SpotifyQueueSnapshot?
    @Published private(set) var devices: [SpotifyDevice] = []
    @Published private(set) var recentlyPlayed: [SpotifyRecentItem] = []
    @Published private(set) var searchInFlight: Bool = false
    @Published private(set) var queueInFlight: Bool = false
    @Published private(set) var devicesInFlight: Bool = false
    @Published private(set) var recentlyPlayedInFlight: Bool = false
    /// Set to true once we've seen a 403 on a discovery endpoint that
    /// requires a scope the user's existing refresh token doesn't have
    /// (e.g. `user-read-recently-played` added after their original auth).
    /// UI surfaces a "Reconnect to enable" pill instead of the empty section.
    @Published private(set) var recentlyPlayedNeedsReauth: Bool = false

    private var searchTask: Task<Void, Never>?
    private var lastDiscoveryRefresh: [String: Date] = [:]
    private static let discoveryCacheTTL: TimeInterval = 30

    private let connectedKey = "spotify.connected"
    private var notificationTask: Task<Void, Never>?
    private var runningPollTask: Task<Void, Never>?
    private var positionPollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkURL: String?
    private var lastLikedCheckTrackID: String?
    private var lastRepeatStateCheck: Date = .distantPast
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

    /// Back-compat: AppDelegate boot path. Equivalent to
    /// `startIfPreviouslyConnected()` — never auto-opts-in.
    func start() { startIfPreviouslyConnected() }

    /// User tapped Connect. Begins listening + persists the choice.
    func connect() {
        guard !isConnected else { return }
        isConnected = true
        UserDefaults.standard.set(true, forKey: connectedKey)
        refreshRunningState()
        // If a refresh token is sitting in Keychain from a prior session,
        // restore Web API readiness silently. The first API call will refresh
        // the access token on demand.
        Task { await self.warmWebAPIIfAuthed() }
        notificationTask = Task { [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            for await _ in notifications {
                await self?.refresh()
            }
        }
        // Poll running state every 3s so the view reacts when Spotify
        // launches or quits (no system notification for that).
        runningPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.refreshRunningStateAndMaybeFetch()
            }
        }
        // Poll player position every 2s while playing. Spotify only broadcasts
        // PlaybackStateChanged on play/pause/track-change — without this poll
        // our cached currentTime drifts when the user seeks externally and the
        // lyrics anchor goes stale. Cheap: one AppleScript call, ~5ms.
        positionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { continue }
                if self.shouldPollPosition() { await self.refresh() }
            }
        }
        Task { await refresh() }
    }

    /// View can force a fresh AppleScript pull (used when user resumes play
    /// after a long pause — the cached currentTime is stale until the next
    /// notification fires, which may be never until the next track change).
    func refreshNow() async { await refresh() }

    private func shouldPollPosition() -> Bool {
        isConnected && isRunning && state.isPlaying
    }

    /// User tapped Disconnect. Stops listening + clears state. Does NOT
    /// revoke Web API auth — that has a dedicated `signOutWebAPI()`.
    func disconnect() {
        isConnected = false
        UserDefaults.standard.set(false, forKey: connectedKey)
        notificationTask?.cancel(); notificationTask = nil
        runningPollTask?.cancel(); runningPollTask = nil
        positionPollTask?.cancel(); positionPollTask = nil
        artworkTask?.cancel(); artworkTask = nil
        state = SpotifyPlaybackState()
        lastArtworkURL = nil
        lastLikedCheckTrackID = nil
        lastRepeatStateCheck = .distantPast
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
    func setVolume(_ level: Double) async {
        let v = Int((max(0, min(1, level)) * 100).rounded())
        await sendCommand("set sound volume to \(v)")
        try? await Task.sleep(for: commandDelay)
        await refresh()
    }

    /// Toggle shuffle on/off. AppleScript-only — no Web API needed.
    func toggleShuffle() async {
        let next = !state.isShuffled
        await sendCommand("set shuffling to \(next ? "true" : "false")")
        try? await Task.sleep(for: commandDelay)
        await refresh()
    }

    /// Explicit setter — used by IntentRouter ("shuffle on" / "shuffle off").
    func setShuffle(_ on: Bool) async {
        await sendCommand("set shuffling to \(on ? "true" : "false")")
        try? await Task.sleep(for: commandDelay)
        await refresh()
    }

    /// Cycle repeat mode: off → context (all) → track → off. When the Web API
    /// is authed we get full three-state support. Without it we fall back to
    /// the AppleScript boolean (off ↔ context).
    func cycleRepeatMode() async {
        let target = state.repeatMode.next
        await setRepeatMode(target)
    }

    /// Set repeat to a specific mode. Falls back to AppleScript boolean when
    /// no Web API token is available (track mode collapses to context).
    func setRepeatMode(_ mode: SpotifyRepeatMode) async {
        var applied = mode
        if webAPIReady {
            // Web API supports off/track/context natively.
            let ok = await SpotifyWebClient.shared.setRepeatState(mode.rawValue)
            if !ok {
                // Token may have expired between checks — fall back gracefully.
                await sendCommand("set repeating to \(mode.appleScriptBool)")
                applied = mode.appleScriptBool ? .context : .off
            }
        } else {
            // Boolean-only fallback. `track` snaps to `context`.
            let bool = mode.appleScriptBool
            await sendCommand("set repeating to \(bool)")
            applied = bool ? .context : .off
        }
        // Optimistic state update so the UI snaps instantly; refresh confirms.
        var s = state
        s.repeatMode = applied
        state = s
        try? await Task.sleep(for: commandDelay)
        await refresh()
    }

    /// Save the current track to Liked Songs. No-op when Web API isn't authed.
    @discardableResult
    func saveCurrentTrack() async -> Bool {
        let id = state.trackID
        guard !id.isEmpty, webAPIReady else { return false }
        let ok = await SpotifyWebClient.shared.saveTracks([id])
        if ok {
            var s = state
            s.isLiked = true
            state = s
        }
        return ok
    }

    /// Remove the current track from Liked Songs.
    @discardableResult
    func unsaveCurrentTrack() async -> Bool {
        let id = state.trackID
        guard !id.isEmpty, webAPIReady else { return false }
        let ok = await SpotifyWebClient.shared.removeSavedTracks([id])
        if ok {
            var s = state
            s.isLiked = false
            state = s
        }
        return ok
    }

    /// Toggle Liked Songs membership. Used by the heart button.
    func toggleLiked() async {
        guard webAPIReady, !state.trackID.isEmpty else { return }
        if state.isLiked == true {
            await unsaveCurrentTrack()
        } else {
            await saveCurrentTrack()
        }
    }

    /// Add the current track to the playlist whose name fuzzy-matches `query`.
    /// Returns the playlist name on success, nil on failure.
    @discardableResult
    func addCurrentTrackToPlaylist(matching query: String) async -> String? {
        guard webAPIReady, !state.trackURI.isEmpty else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if playlists.isEmpty { await refreshPlaylists() }
        // Prefer exact, then prefix, then substring match. Skip
        // collaborative-only / owned-by-other playlists we can't modify.
        let candidates = playlists.filter { $0.canModify }
        let lower = candidates.map { ($0, $0.name.lowercased()) }
        let pick: SpotifyPlaylist? =
            lower.first(where: { $0.1 == q })?.0
            ?? lower.first(where: { $0.1.hasPrefix(q) })?.0
            ?? lower.first(where: { $0.1.contains(q) })?.0
        guard let playlist = pick else { return nil }
        let ok = await SpotifyWebClient.shared.addTrack(uri: state.trackURI,
                                                       toPlaylist: playlist.id)
        return ok ? playlist.name : nil
    }

    /// Add the current track to a specific playlist by ID. Returns success.
    @discardableResult
    func addCurrentTrackToPlaylist(id playlistID: String) async -> Bool {
        guard webAPIReady, !state.trackURI.isEmpty else { return false }
        return await SpotifyWebClient.shared.addTrack(uri: state.trackURI,
                                                     toPlaylist: playlistID)
    }

    /// Pull the user's playlists into the local cache. Cheap to call — paged
    /// at 50/req, capped at 100 entries to keep the UI menu short.
    func refreshPlaylists() async {
        guard webAPIReady else { return }
        let fetched = await SpotifyWebClient.shared.fetchUserPlaylists()
        if !fetched.isEmpty { playlists = fetched }
    }

    // MARK: - Web API auth

    /// Kicks off the PKCE OAuth flow. Surfaces errors via `lastWebError`.
    @discardableResult
    func authenticateWebAPI() async -> Bool {
        lastWebError = nil
        do {
            try await SpotifyWebClient.shared.beginPKCEFlow()
            webAPIReady = true
            await refreshPlaylists()
            await syncWebAPIPlaybackState()
            return true
        } catch {
            let msg: String
            if let e = error as? SpotifyWebClient.AuthError {
                msg = e.userMessage
            } else {
                msg = error.localizedDescription
            }
            lastWebError = msg
            webAPIReady = false
            return false
        }
    }

    /// Sign out of the Web API. AppleScript-driven controls keep working.
    func signOutWebAPI() {
        SpotifyWebClient.shared.signOut()
        webAPIReady = false
        playlists = []
        var s = state
        s.isLiked = nil
        state = s
    }

    /// On launch, if a refresh token exists we silently mint an access token
    /// and flip `webAPIReady = true` so the UI knows.
    private func warmWebAPIIfAuthed() async {
        guard SpotifyWebClient.shared.hasRefreshToken else { return }
        let ok = await SpotifyWebClient.shared.warmAccessToken()
        webAPIReady = ok
        if ok {
            await refreshPlaylists()
            await syncWebAPIPlaybackState()
        } else {
            lastWebError = "Spotify re-auth needed"
        }
    }

    /// Pull repeat/shuffle state from the Web API so the UI reflects the
    /// real three-state repeat even when the user changed it from another
    /// device. Falls back silently on failure.
    private func syncWebAPIPlaybackState() async {
        guard webAPIReady else { return }
        if let snap = await SpotifyWebClient.shared.fetchPlayback() {
            var s = state
            if let mode = SpotifyRepeatMode(rawValue: snap.repeatState) {
                s.repeatMode = mode
            }
            s.isShuffled = snap.shuffleState
            state = s
        }
    }

    /// Refresh `state.isLiked` for the current track. Throttled by trackID
    /// so we only call /me/tracks/contains once per track change.
    private func refreshLikedIfNeeded() async {
        guard webAPIReady, !state.trackID.isEmpty else { return }
        if lastLikedCheckTrackID == state.trackID { return }
        lastLikedCheckTrackID = state.trackID
        let result = await SpotifyWebClient.shared.checkSavedTracks([state.trackID])
        guard let liked = result.first else { return }
        var s = state
        s.isLiked = liked
        state = s
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
              descriptor.numberOfItems >= 11 else { return }

        // AppleScript only exposes a boolean for `repeating`. When the Web
        // API is authed we trust the cached `repeatMode` (kept in sync via
        // `syncWebAPIPlaybackState()`); otherwise fold the bool into off/context.
        let boolRepeat = descriptor.atIndex(8)?.booleanValue ?? false
        let mappedRepeat: SpotifyRepeatMode = webAPIReady
            ? state.repeatMode
            : (boolRepeat ? .context : .off)
        let trackURI = descriptor.atIndex(11)?.stringValue ?? ""

        let new = SpotifyPlaybackState(
            isPlaying: descriptor.atIndex(1)?.booleanValue ?? false,
            title: descriptor.atIndex(2)?.stringValue ?? "",
            artist: descriptor.atIndex(3)?.stringValue ?? "",
            album: descriptor.atIndex(4)?.stringValue ?? "",
            currentTime: descriptor.atIndex(5)?.doubleValue ?? 0,
            // Spotify's `duration of current track` returns milliseconds.
            duration: (descriptor.atIndex(6)?.doubleValue ?? 0) / 1000,
            isShuffled: descriptor.atIndex(7)?.booleanValue ?? false,
            repeatMode: mappedRepeat,
            volume: Double(descriptor.atIndex(9)?.int32Value ?? 50) / 100.0,
            artworkURL: descriptor.atIndex(10)?.stringValue ?? "",
            artwork: state.artwork, // keep prior bytes; replaced after fetch below
            trackURI: trackURI,
            isLiked: (trackURI == state.trackURI) ? state.isLiked : nil
        )
        // Periodic resync of repeat/shuffle from the Web API — covers the
        // case where the user changed it on another device. Throttled to
        // once per 30s so we don't spam /me/player.
        if webAPIReady, Date().timeIntervalSince(lastRepeatStateCheck) > 30 {
            lastRepeatStateCheck = Date()
            Task { [weak self] in await self?.syncWebAPIPlaybackState() }
        }
        // Kick a Liked-songs check the moment the track changes.
        if new.trackID != state.trackID, webAPIReady {
            Task { [weak self] in await self?.refreshLikedIfNeeded() }
        }

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
        // `spotify url of current track` returns a `spotify:track:<id>` URI
        // which we use to drive Liked-songs checks + add-to-playlist over the
        // Web API. Always last in the tuple so older builds gracefully ignore.
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
                set trackURI to spotify url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL, trackURI}
            on error
                return {false, "", "", "", 0, 0, false, false, 50, "", ""}
            end try
        end tell
        """
        return try await AppleScriptHelper.execute(script)
    }

    private static func fetchArtwork(url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Discovery (search / queue / devices / recently played)

    /// Debounced live search. Cancels any prior in-flight task. An empty
    /// query clears results immediately (no network call).
    func search(_ query: String) async {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchResults = []
            searchInFlight = false
            return
        }
        guard webAPIReady else {
            searchResults = []
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.searchInFlight = true
            let results = await SpotifyWebClient.shared.search(trimmed)
            guard !Task.isCancelled else { return }
            self.searchResults = results
            self.searchInFlight = false
        }
        searchTask = task
    }

    /// Play a track URI immediately. Falls back to opening `spotify:track:`
    /// via NSWorkspace when the Web API isn't authed.
    @discardableResult
    func playTrack(uri: String) async -> Bool {
        guard !uri.isEmpty else { return false }
        if webAPIReady, await SpotifyWebClient.shared.play(uri: uri) {
            try? await Task.sleep(for: commandDelay)
            await refresh()
            return true
        }
        if let url = URL(string: uri) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    /// Append a track URI to the active device's queue.
    @discardableResult
    func addToQueue(uri: String) async -> Bool {
        guard webAPIReady, !uri.isEmpty else { return false }
        let ok = await SpotifyWebClient.shared.addToQueue(uri: uri)
        if ok {
            // Invalidate the cached queue snapshot so the next read pulls fresh.
            lastDiscoveryRefresh["queue"] = nil
        }
        return ok
    }

    /// Fetch /me/player/queue and publish. Cached 30s; pass force=true to
    /// bypass the cache.
    func refreshQueue(force: Bool = false) async {
        guard webAPIReady else { return }
        if !force, let last = lastDiscoveryRefresh["queue"],
           Date().timeIntervalSince(last) < Self.discoveryCacheTTL {
            return
        }
        queueInFlight = true
        let snap = await SpotifyWebClient.shared.fetchQueue()
        queueSnapshot = snap
        lastDiscoveryRefresh["queue"] = Date()
        queueInFlight = false
    }

    /// Fetch /me/player/devices and publish.
    func refreshDevices(force: Bool = false) async {
        guard webAPIReady else { return }
        if !force, let last = lastDiscoveryRefresh["devices"],
           Date().timeIntervalSince(last) < Self.discoveryCacheTTL {
            return
        }
        devicesInFlight = true
        devices = await SpotifyWebClient.shared.fetchDevices()
        lastDiscoveryRefresh["devices"] = Date()
        devicesInFlight = false
    }

    /// Fetch /me/player/recently-played and publish. Sets
    /// `recentlyPlayedNeedsReauth` when Spotify returns no rows AND the
    /// user is authed — that's the signature of an old token missing the
    /// `user-read-recently-played` scope (Spotify returns 403 → our
    /// `apiCall` returns `(false, nil)` → fetch returns []).
    func refreshRecentlyPlayed(force: Bool = false) async {
        guard webAPIReady else { return }
        if !force, let last = lastDiscoveryRefresh["recent"],
           Date().timeIntervalSince(last) < Self.discoveryCacheTTL {
            return
        }
        recentlyPlayedInFlight = true
        let rows = await SpotifyWebClient.shared.fetchRecentlyPlayed()
        recentlyPlayed = rows
        recentlyPlayedNeedsReauth = rows.isEmpty
        lastDiscoveryRefresh["recent"] = Date()
        recentlyPlayedInFlight = false
    }

    /// Transfer playback to a specific device.
    @discardableResult
    func transferPlayback(toDeviceID id: String, play: Bool = true) async -> Bool {
        guard webAPIReady else { return false }
        let ok = await SpotifyWebClient.shared.transferPlayback(toDevice: id, play: play)
        if ok {
            // Devices change which one is active — invalidate.
            lastDiscoveryRefresh["devices"] = nil
            await refreshDevices(force: true)
        }
        return ok
    }

    /// Fuzzy-match a device by name + transfer. Returns the matched device
    /// name on success, nil on no-match / failure.
    @discardableResult
    func transferPlayback(matchingName query: String, play: Bool = true) async -> String? {
        guard webAPIReady else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        await refreshDevices(force: true)
        let lower = devices.map { ($0, $0.name.lowercased()) }
        let match: SpotifyDevice? =
            lower.first(where: { $0.1 == q })?.0
            ?? lower.first(where: { $0.1.hasPrefix(q) })?.0
            ?? lower.first(where: { $0.1.contains(q) })?.0
        guard let device = match else { return nil }
        let ok = await SpotifyWebClient.shared.transferPlayback(toDevice: device.id, play: play)
        return ok ? device.name : nil
    }
}
