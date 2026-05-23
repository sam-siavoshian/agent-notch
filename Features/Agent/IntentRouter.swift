//
//  IntentRouter.swift
//  Agent in the Notch
//
//  Pre-flight pattern matcher that runs BEFORE the model loop. If a user
//  transcript matches a known deterministic intent (open URL, control
//  Spotify, add a reminder), we execute it directly and skip the whole
//  vision+click loop. Result: ~0 turn latency for the most common voice
//  commands.
//
//  Conservative on purpose: misclassifying "delete my files" as a fast path
//  would be catastrophic, so we only match very obvious patterns. Anything
//  ambiguous falls through to the model.
//

import Foundation
import AppKit

public enum IntentResult: Sendable {
    case handled(summary: String, affirmation: String)
    case deferred(hint: String)
    case notMine
}

public enum IntentRouter {
    /// Try each handler in order. First non-`.notMine` wins.
    public static func tryHandle(transcript raw: String) async -> IntentResult {
        let transcript = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        guard !transcript.isEmpty else { return .notMine }

        // Safety: never fast-path anything that mentions destructive verbs.
        let dangerous = ["delete", "erase", "format", "wipe", "remove", "uninstall", "shut down", "shutdown", "restart", "log out", "purchase", "buy", "pay", "send money"]
        let lower = transcript.lowercased()
        if dangerous.contains(where: { lower.contains($0) }) {
            return .notMine
        }

        if case .handled(let s, let a) = OpenURLIntent.handle(transcript) { return .handled(summary: s, affirmation: a) }
        if case .handled(let s, let a) = await SpotifyIntent.handle(transcript) { return .handled(summary: s, affirmation: a) }
        if case .handled(let s, let a) = await ReminderIntent.handle(transcript) { return .handled(summary: s, affirmation: a) }
        return .notMine
    }
}

// MARK: - Open URL

enum OpenURLIntent {
    static func handle(_ transcript: String) -> IntentResult {
        let lower = transcript.lowercased()
        // Explicit http(s) URL anywhere in the transcript.
        if let url = firstHTTPURL(in: transcript) {
            return open(url, label: url.host ?? url.absoluteString)
        }
        // "open <domain>" / "go to <domain>" / "navigate to <domain>"
        let triggers = ["open ", "go to ", "navigate to ", "visit "]
        if let t = triggers.first(where: { lower.hasPrefix($0) }) {
            let tail = String(transcript.dropFirst(t.count)).trimmingCharacters(in: .whitespaces)
            if let url = domainURL(from: tail) {
                return open(url, label: url.host ?? tail)
            }
        }
        return .notMine
    }

    private static func firstHTTPURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let match = detector?.firstMatch(in: text, options: [], range: range)
        return match?.url
    }

    private static func domainURL(from raw: String) -> URL? {
        // Strip trailing punctuation, lowercase, swap spoken "dot" for "."
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: " dot ", with: ".")
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        guard s.contains(".") else { return nil }
        let parts = s.split(separator: " ")
        // Take first whitespace-separated token that looks like a domain.
        guard let token = parts.first(where: { $0.contains(".") }) else { return nil }
        let urlString = "https://" + String(token)
        return URL(string: urlString)
    }

    private static func open(_ url: URL, label: String) -> IntentResult {
        NSWorkspace.shared.open(url)
        return .handled(
            summary: "Opened \(url.absoluteString)",
            affirmation: "Opening \(label) now."
        )
    }
}

// MARK: - Spotify

enum SpotifyIntent {
    static func handle(_ transcript: String) async -> IntentResult {
        let lower = transcript.lowercased()
        // Spotify-targeted transport / state commands. We act when the
        // transcript explicitly says "spotify" OR uses a music-adjacent verb
        // that is unambiguous on its own (shuffle, repeat, save song, etc).
        let mentionsSpotify = lower.contains("spotify")

        // --- Tier 1: AppleScript-only (always available) ---

        if mentionsSpotify, lower.contains("pause") || lower.contains("stop") {
            return await tellSpotify(cmd: "pause", affirmation: "Pausing Spotify.")
        }
        if mentionsSpotify,
           lower.contains("resume") || lower == "play spotify" || lower.contains("play music") {
            return await tellSpotify(cmd: "play", affirmation: "Playing Spotify.")
        }
        if mentionsSpotify, lower.contains("next") || lower.contains("skip") {
            return await tellSpotify(cmd: "next track", affirmation: "Next track.")
        }
        if mentionsSpotify, lower.contains("previous") {
            return await tellSpotify(cmd: "previous track", affirmation: "Previous track.")
        }

        // Shuffle: "shuffle on/off/toggle". Verb is unambiguous, no need
        // to mention Spotify.
        if let on = parseShuffle(lower) {
            return await runOnController { c in
                await c.setShuffle(on)
                return "Shuffle \(on ? "on" : "off")."
            } summary: { "Shuffle \($0)" }
        }
        if lower == "toggle shuffle" || lower == "shuffle" {
            return await runOnController { c in
                let now = !c.state.isShuffled
                await c.setShuffle(now)
                return "Shuffle \(now ? "on" : "off")."
            } summary: { "Shuffle \($0)" }
        }

        // Repeat: "repeat off/track/song/all/playlist/context".
        if let mode = parseRepeat(lower) {
            return await runOnController { c in
                await c.setRepeatMode(mode)
                return "Repeat \(mode.spoken)."
            } summary: { "Repeat \($0)" }
        }

        // Play a named song/artist on Spotify — search via spotify: URL.
        // "play <query> on spotify"
        if let q = extract(after: "play ", before: " on spotify", in: lower) ??
                   extract(after: "play ", before: " in spotify", in: lower) {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let url = URL(string: "spotify:search:\(encoded)") {
                NSWorkspace.shared.open(url)
                return .handled(summary: "Spotify search for \(q)", affirmation: "Searching Spotify for \(q).")
            }
        }

        // --- Tier 2: Web API (require auth) ---

        // Save current track: "save song" / "save this track" / "like song"
        if isSaveSongCommand(lower) {
            return await runOnController { c in
                guard c.webAPIReady else { return "Spotify cloud sign-in needed for Liked Songs." }
                let ok = await c.saveCurrentTrack()
                return ok ? "Saved to your Liked Songs." : "Could not save the song."
            } summary: { _ in "Spotify save song" }
        }

        // Unsave: "unsave song" / "unlike song"
        if isUnsaveSongCommand(lower) {
            return await runOnController { c in
                guard c.webAPIReady else { return "Spotify cloud sign-in needed." }
                let ok = await c.unsaveCurrentTrack()
                return ok ? "Removed from Liked Songs." : "Could not update Liked Songs."
            } summary: { _ in "Spotify unsave song" }
        }

        // Add to <playlist>: "add this/song to <name> playlist" / "add to <name>"
        if let q = parseAddToPlaylist(lower) {
            return await runOnController { c in
                guard c.webAPIReady else { return "Spotify cloud sign-in needed to add to playlists." }
                if let name = await c.addCurrentTrackToPlaylist(matching: q) {
                    return "Added to \(name)."
                }
                return "Could not find a matching playlist for \(q)."
            } summary: { _ in "Spotify add to playlist \(q)" }
        }

        return .notMine
    }

    private static func tellSpotify(cmd: String, affirmation: String) async -> IntentResult {
        let script = "tell application \"Spotify\" to \(cmd)"
        do {
            _ = try await AppleScriptBridge.run(script)
            return .handled(summary: "Spotify \(cmd)", affirmation: affirmation)
        } catch {
            NSLog("[IntentRouter] Spotify command failed: \(error)")
            return .notMine
        }
    }

    private static func extract(after start: String, before end: String, in text: String) -> String? {
        guard let s = text.range(of: start) else { return nil }
        guard let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return nil }
        let mid = text[s.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespaces)
        return mid.isEmpty ? nil : mid
    }

    private static func extract(after start: String, in text: String) -> String? {
        guard let s = text.range(of: start) else { return nil }
        let tail = text[s.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return tail.isEmpty ? nil : tail
    }

    // MARK: - Parsers (kept tiny + explicit)

    /// Returns `true` / `false` if the transcript says "shuffle on/off". `nil`
    /// when shuffle isn't being explicitly set (caller handles "toggle").
    private static func parseShuffle(_ s: String) -> Bool? {
        // Allow either word order: "shuffle on" / "turn on shuffle" / "shuffle off"
        let onCues  = ["shuffle on", "turn on shuffle", "enable shuffle", "start shuffle", "shuffle play"]
        let offCues = ["shuffle off", "turn off shuffle", "disable shuffle", "stop shuffle", "no shuffle"]
        if onCues.contains(where: { s.contains($0) })  { return true }
        if offCues.contains(where: { s.contains($0) }) { return false }
        return nil
    }

    /// Maps free-form repeat commands to a `SpotifyRepeatMode`.
    private static func parseRepeat(_ s: String) -> SpotifyRepeatMode? {
        // Word-boundary check so we don't catch "repeating" inside other text.
        guard s.contains("repeat") else { return nil }
        if s.contains("repeat off") || s.contains("turn off repeat") || s.contains("stop repeat") || s.contains("no repeat") {
            return .off
        }
        if s.contains("repeat track") || s.contains("repeat song") || s.contains("repeat one") || s.contains("repeat current") {
            return .track
        }
        if s.contains("repeat all") || s.contains("repeat playlist") || s.contains("repeat context") || s.contains("repeat queue") || s.contains("repeat on") {
            return .context
        }
        return nil
    }

    private static func isSaveSongCommand(_ s: String) -> Bool {
        // "save song" / "save this song" / "save this track" / "save current track"
        // "like song" / "like this song" / "favorite song" / "heart this song"
        let cues = [
            "save song", "save this song", "save the song", "save this track", "save the track",
            "save current track", "save this", "like this song", "like song", "like this track",
            "favorite this", "favorite song", "favorite this song", "heart this song",
            "add to liked songs", "add to library", "add to my library"
        ]
        return cues.contains(where: { s.contains($0) })
    }

    private static func isUnsaveSongCommand(_ s: String) -> Bool {
        // We deliberately avoid the words "delete" / "remove" / "erase" since
        // they live on the dangerous list that short-circuits IntentRouter.
        let cues = [
            "unsave song", "unsave this song", "unsave this track", "unlike song",
            "unlike this song", "unfavorite this", "unheart this song", "unlike track"
        ]
        return cues.contains(where: { s.contains($0) })
    }

    /// "add this to <playlist>" / "add song to <playlist>" / "add to <playlist>"
    /// Returns the playlist-name query, with optional trailing " playlist".
    private static func parseAddToPlaylist(_ s: String) -> String? {
        let triggers = [
            "add this to ", "add song to ", "add this song to ", "add the song to ",
            "add this track to ", "add track to ", "add to "
        ]
        guard let t = triggers.first(where: { s.contains($0) }) else { return nil }
        guard let q = extract(after: t, in: s) else { return nil }
        // Strip noise like "playlist" / "my chill playlist" → "my chill"
        let cleaned = q
            .replacingOccurrences(of: " playlist", with: "")
            .replacingOccurrences(of: " on spotify", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Run a closure on `SpotifyController.shared` (the singleton is @MainActor).
    @MainActor
    private static func runOnController(
        _ work: @MainActor (SpotifyController) async -> String,
        summary makeSummary: (String) -> String
    ) async -> IntentResult {
        let aff = await work(SpotifyController.shared)
        return .handled(summary: makeSummary(aff), affirmation: aff)
    }
}

private extension SpotifyRepeatMode {
    var spoken: String {
        switch self {
        case .off: return "off"
        case .track: return "track"
        case .context: return "all"
        }
    }
}

// MARK: - Reminders

enum ReminderIntent {
    static func handle(_ transcript: String) async -> IntentResult {
        let lower = transcript.lowercased()
        let triggers = ["remind me to ", "add a reminder to ", "add reminder to "]
        guard let t = triggers.first(where: { lower.hasPrefix($0) }) else { return .notMine }
        let body = String(transcript.dropFirst(t.count)).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return .notMine }
        let safe = body.replacingOccurrences(of: "\"", with: "'")
        let script = "tell application \"Reminders\" to make new reminder with properties {name:\"\(safe)\"}"
        do {
            _ = try await AppleScriptBridge.run(script)
            return .handled(summary: "Reminder added: \(body)", affirmation: "Reminder added.")
        } catch {
            NSLog("[IntentRouter] Reminder add failed: \(error)")
            return .notMine
        }
    }
}
