import Foundation

/// Append-only chronological story of `SurfaceObservation`s, persisted as
/// daily-rotated JSONL with an in-memory tail for fast Selector reads.
///
/// This is one of the three sinks `GeminiObserver` writes to on every
/// successful capture:
///   - `ScreenObservationLog` — live ring for DevTools
///   - `SurfaceMemoryStore`   — per-(app, surface) UI knowledge accumulator
///   - `CaptureStoryLog`      — THIS — the user-centric chronological story
///
/// The Selector reads `tail(...)` at long-press time, filters to the last
/// few minutes, and ships it as `recent_story` in the Mercury payload so
/// briefs can carry real continuity ("you've been drafting a letter to
/// Marcus for the last 5 minutes") rather than guessing from one frame.
///
/// Patterned after `EventLog`: append-only JSONL with per-day rotation under
/// ~/Library/Application Support/AgentNotch/ContextMemory/story-YYYY-MM-DD.jsonl
/// (one observation per line). The in-memory ring is bounded; the on-disk
/// log is unbounded by design — story replay is a feature.
public final class CaptureStoryLog {

    public static let shared = CaptureStoryLog()

    private let inMemoryCapacity: Int
    private var buffer: [SurfaceObservation]
    private let queue = DispatchQueue(label: "AgentNotch.CaptureStoryLog.queue")
    private let encoder: JSONEncoder

    public init(inMemoryCapacity: Int = 200) {
        self.inMemoryCapacity = inMemoryCapacity
        self.buffer = []
        self.buffer.reserveCapacity(inMemoryCapacity)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        ensureDirectoryExists()
        self.buffer = Self.loadTodaysTail(maxCount: inMemoryCapacity)
    }

    /// Re-hydrate today's story so the Selector's `recent_story` survives a
    /// mid-day restart and Mercury briefs keep narrative continuity. Yesterday's
    /// story is intentionally NOT loaded — "recent" means today, and stale
    /// continuity would mislead the brief.
    private static func loadTodaysTail(maxCount: Int) -> [SurfaceObservation] {
        let day = dayFormatter.string(from: Date())
        let url = storageRoot.appendingPathComponent("story-\(day).jsonl")
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let tail = lines.suffix(maxCount)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [SurfaceObservation] = []
        out.reserveCapacity(tail.count)
        for line in tail {
            guard let lineData = line.data(using: .utf8),
                  let obs = try? decoder.decode(SurfaceObservation.self, from: lineData) else { continue }
            out.append(obs)
        }
        return out
    }

    // MARK: - Public API

    /// Append a freshly produced `SurfaceObservation` to today's story file
    /// and update the in-memory ring.
    public func record(_ obs: SurfaceObservation) {
        queue.sync {
            buffer.append(obs)
            if buffer.count > inMemoryCapacity {
                buffer.removeFirst(buffer.count - inMemoryCapacity)
            }
            appendToDisk(obs)
        }
    }

    /// Most recent N story entries (in chronological order, oldest first).
    /// Backed by the in-memory ring — does not touch disk.
    public func tail(_ limit: Int) -> [SurfaceObservation] {
        queue.sync {
            Array(buffer.suffix(limit))
        }
    }

    /// Full in-memory buffer snapshot (capped at `inMemoryCapacity`).
    public func snapshot() -> [SurfaceObservation] {
        queue.sync { Array(buffer) }
    }

    // MARK: - Persistence

    private static let storageRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
    }()

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
    }

    private func currentLogFile(for date: Date) -> URL {
        let day = Self.dayFormatter.string(from: date)
        return Self.storageRoot.appendingPathComponent("story-\(day).jsonl")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Append one JSONL line. Best-effort: if disk write fails, the in-memory
    /// copy survives. Matches `EventLog`'s appendToDisk semantics.
    private func appendToDisk(_ obs: SurfaceObservation) {
        guard let data = try? encoder.encode(obs) else { return }
        let url = currentLogFile(for: obs.t)
        var line = data
        line.append(0x0A) // \n
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            // File doesn't exist yet — create with first line.
            try? line.write(to: url, options: [.atomic])
        }
    }
}
