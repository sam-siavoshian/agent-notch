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
        for t in triggers where lower.hasPrefix(t) {
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
        // Only act when Spotify is explicitly mentioned OR transport verbs are
        // unambiguous AND Spotify is the frontmost music app. Conservative.
        let mentionsSpotify = lower.contains("spotify")

        if mentionsSpotify && (lower.contains("pause") || lower.contains("stop")) {
            return await tellSpotify(cmd: "pause", affirmation: "Pausing Spotify.")
        }
        if mentionsSpotify && (lower.contains("resume") || lower == "play spotify" || lower.contains("play music")) {
            return await tellSpotify(cmd: "play", affirmation: "Playing Spotify.")
        }
        if mentionsSpotify && (lower.contains("next") || lower.contains("skip")) {
            return await tellSpotify(cmd: "next track", affirmation: "Next track.")
        }
        if mentionsSpotify && lower.contains("previous") {
            return await tellSpotify(cmd: "previous track", affirmation: "Previous track.")
        }
        // Play a named song/artist on Spotify — search via spotify: URL.
        // "play <query> on spotify"
        if mentionsSpotify, let q = extract(after: "play ", before: " on spotify", in: lower) ??
                                  extract(after: "play ", before: " in spotify", in: lower) {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let url = URL(string: "spotify:search:\(encoded)") {
                NSWorkspace.shared.open(url)
                return .handled(summary: "Spotify search for \(q)", affirmation: "Searching Spotify for \(q).")
            }
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
}

// MARK: - Reminders

enum ReminderIntent {
    static func handle(_ transcript: String) async -> IntentResult {
        let lower = transcript.lowercased()
        let triggers = ["remind me to ", "add a reminder to ", "add reminder to "]
        for t in triggers where lower.hasPrefix(t) {
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
        return .notMine
    }
}
