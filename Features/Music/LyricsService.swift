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

    static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.id == rhs.id && lhs.time == rhs.time && lhs.text == rhs.text
    }
}

@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String? = nil

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
    func fetch(title: String, artist: String, album: String = "") {
        let key = normalize("\(title)|\(artist)")
        guard !title.isEmpty, !artist.isEmpty else {
            reset(); return
        }
        if key == loadedKey { return }
        loadedKey = key

        if let hit = cache[key] {
            self.lines = hit.lines
            self.plain = hit.plain
            self.lastError = nil
            self.isLoading = false
            return
        }

        fetchTask?.cancel()
        isLoading = true
        lines = []
        plain = ""
        lastError = nil

        fetchTask = Task { [weak self, key, title, artist, album] in
            let result = await LRClibClient.search(title: title, artist: artist, album: album)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.loadedKey == key else { return }
                switch result {
                case .success(let parsed):
                    self.cache[key] = parsed
                    self.lines = parsed.lines
                    self.plain = parsed.plain
                case .failure(let err):
                    self.lastError = err.localizedDescription
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
        lastError = nil
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
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func search(title: String, artist: String, album: String) async
        -> Result<LyricsStore.ParsedLyrics, Error>
    {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        guard let url = comps.url else { return .failure(LRCError.decode) }

        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("AgentNotch/0.1 (https://github.com/agentnotch)",
                     forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return .failure(LRCError.badStatus(code)) }
            let hits = try JSONDecoder().decode([Hit].self, from: data)
            guard let hit = hits.first(where: {
                ($0.syncedLyrics?.isEmpty == false) || ($0.plainLyrics?.isEmpty == false)
            }) else {
                return .failure(LRCError.noMatch)
            }
            let parsed = LyricsStore.ParsedLyrics(
                lines: parseLRC(hit.syncedLyrics ?? ""),
                plain: hit.plainLyrics ?? ""
            )
            return .success(parsed)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - LRC parser

    /// Parses `[mm:ss.xx]` or `[m:ss]` timestamped lines. Multi-tag lines like
    /// `[00:12.30][00:45.10]text` produce one LyricLine per tag.
    static func parseLRC(_ raw: String) -> [LyricLine] {
        guard !raw.isEmpty else { return [] }
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var out: [LyricLine] = []
        for rawLine in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
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
                let centis = Double(subS) ?? 0
                let divisor: Double = subS.count >= 3 ? 1000 : 100
                let t = mins * 60 + secs + centis / divisor
                out.append(LyricLine(time: t, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
