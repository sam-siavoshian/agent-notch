//
//  LyricsService.swift
//  Agent in the Notch
//
//  LRClib-backed synced lyrics. Free API, no auth, returns LRC-format
//  `syncedLyrics` + `plainLyrics`. Cached in-memory per track key.
//  See ~/.claude/skills/soft-pill-ui/references/live-lyrics.md.
//

import Foundation

struct LyricLine: Equatable, Identifiable {
    let id = UUID()
    let time: Double   // seconds from track start
    let text: String
}

@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String = ""
    @Published private(set) var isLoading: Bool = false

    /// Track key currently loaded. Skip re-fetch if unchanged.
    private var loadedKey: String? = nil
    private var cache: [String: ParsedLyrics] = [:]
    private var fetchTask: Task<Void, Never>?

    struct ParsedLyrics {
        let lines: [LyricLine]
        let plain: String
    }

    /// Fetch lyrics for the given track. No-op if the key matches the
    /// currently-loaded set. Cancels any in-flight fetch on key change.
    /// Pass `duration` (seconds) when available so we can hit LRClib's exact
    /// `/api/get` endpoint (`/api/search` returns fuzzy matches).
    func fetch(title: String, artist: String, album: String = "", duration: Double = 0) {
        let key = normalize("\(title)|\(artist)")
        guard !title.isEmpty, !artist.isEmpty else {
            reset(); return
        }
        if key == loadedKey { return }
        loadedKey = key

        if let hit = cache[key] {
            self.lines = hit.lines
            self.plain = hit.plain
            self.isLoading = false
            return
        }

        fetchTask?.cancel()
        isLoading = true
        lines = []
        plain = ""

        fetchTask = Task { [weak self, key, title, artist, album, duration] in
            let result = await LRClibClient.fetch(title: title, artist: artist,
                                                  album: album, duration: duration)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.loadedKey == key else { return }
                if case .success(let parsed) = result {
                    self.cache[key] = parsed
                    self.lines = parsed.lines
                    self.plain = parsed.plain
                }
                self.isLoading = false
            }
        }
    }

    func reset() {
        fetchTask?.cancel()
        loadedKey = nil
        lines = []
        plain = ""
        isLoading = false
    }

    private func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .lowercased()
    }
}

// MARK: - LRClib HTTP client

enum LRClibClient {
    enum LRCError: Error, LocalizedError {
        case badStatus(Int)
        case decode
        case noMatch
        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "LRClib HTTP \(c)"
            case .decode:           return "LRClib decode failed"
            case .noMatch:          return "No lyrics match"
            }
        }
    }

    private struct Hit: Decodable {
        let duration: Double?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Two-step lookup: try `/api/get` first (exact match by track + artist +
    /// album + duration — returns the right recording). If that 404s, fall
    /// back to `/api/search` and pick the hit whose duration is closest to ours
    /// (the search endpoint can return covers, live versions, remixes).
    static func fetch(title: String, artist: String, album: String, duration: Double) async
        -> Result<LyricsStore.ParsedLyrics, Error>
    {
        if duration > 0, !album.isEmpty,
           let hit = await getExact(title: title, artist: artist,
                                    album: album, duration: duration) {
            return .success(parsedFrom(hit))
        }

        guard var comps = URLComponents(string: "https://lrclib.net/api/search") else {
            return .failure(LRCError.decode)
        }
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        guard let url = comps.url else { return .failure(LRCError.decode) }

        do {
            let data = try await get(url)
            let hits = try Self.jsonDecoder.decode([Hit].self, from: data)
            let candidates = hits.filter {
                ($0.syncedLyrics?.isEmpty == false) || ($0.plainLyrics?.isEmpty == false)
            }
            guard !candidates.isEmpty else { return .failure(LRCError.noMatch) }

            // Prefer the candidate whose duration is closest to ours; prefer
            // those that actually have synced lyrics. Falls back to first hit.
            let best = candidates.min { lhs, rhs in
                let lScore = matchScore(hit: lhs, duration: duration)
                let rScore = matchScore(hit: rhs, duration: duration)
                return lScore < rScore
            } ?? candidates[0]
            return .success(parsedFrom(best))
        } catch {
            return .failure(error)
        }
    }

    /// Lower score is better. Synced beats plain; tighter duration delta wins.
    private static func matchScore(hit: Hit, duration: Double) -> Double {
        let syncedBonus: Double = (hit.syncedLyrics?.isEmpty == false) ? 0 : 100
        let hitDur = hit.duration ?? 0
        let delta = duration > 0 && hitDur > 0 ? abs(hitDur - duration) : 50
        return syncedBonus + delta
    }

    private static func getExact(title: String, artist: String,
                                 album: String, duration: Double) async -> Hit? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        guard let url = comps.url else { return nil }
        guard let data = try? await get(url) else { return nil }
        return try? Self.jsonDecoder.decode(Hit.self, from: data)
    }

    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("AgentNotch/0.1 (https://github.com/agentnotch)",
                     forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LRCError.badStatus(code) }
        return data
    }

    private static func parsedFrom(_ hit: Hit) -> LyricsStore.ParsedLyrics {
        LyricsStore.ParsedLyrics(
            lines: parseLRC(hit.syncedLyrics ?? ""),
            plain: hit.plainLyrics ?? ""
        )
    }

    // MARK: - LRC parser

    // swiftlint:disable:next force_try — hardcoded literal, never throws
    static let lrcTagRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )

    static let jsonDecoder = JSONDecoder()

    /// Parses `[mm:ss.xx]` or `[m:ss.xxx]` timestamped lines. Multi-tag lines
    /// like `[00:12.30][00:45.10]text` produce one LyricLine per tag.
    /// Honors `[offset:+/-N]` ms header (shifts all timestamps), strips BOM,
    /// handles both LF and CRLF.
    static func parseLRC(_ raw: String) -> [LyricLine] {
        guard !raw.isEmpty else { return [] }
        let cleaned = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw

        // [offset:+250] or [offset:-100] — milliseconds, ADDED to every timestamp.
        // Positive offset means lyrics arrive LATE so we shift forward.
        var offsetSec: Double = 0
        if let offRange = cleaned.range(of: #"\[offset:\s*([+-]?\d+)\]"#,
                                        options: .regularExpression) {
            let body = cleaned[offRange]
            if let numRange = body.range(of: #"[+-]?\d+"#, options: .regularExpression),
               let ms = Double(body[numRange]) {
                offsetSec = ms / 1000.0
            }
        }

        let regex = LRClibClient.lrcTagRegex

        var out: [LyricLine] = []
        for rawLine in cleaned.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            for m in matches {
                let minS = ns.substring(with: m.range(at: 1))
                let secS = ns.substring(with: m.range(at: 2))
                var subS = "0"
                if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound {
                    subS = ns.substring(with: m.range(at: 3))
                }
                let mins = Double(minS) ?? 0
                let secs = Double(secS) ?? 0
                let frac = Double(subS) ?? 0
                let divisor: Double = subS.count >= 3 ? 1000 : 100
                let t = mins * 60 + secs + frac / divisor + offsetSec
                out.append(LyricLine(time: max(0, t), text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
