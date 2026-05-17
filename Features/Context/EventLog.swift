import Foundation

/// Thread-safe append-only ring buffer + JSONL persistence for CEvents.
///
/// In-memory: keeps the last `inMemoryCapacity` events for fast tail() reads.
/// On disk:   appends each event as a single JSON line under
///            ~/Library/Application Support/AgentNotch/ContextMemory/events.jsonl
///            with per-day rotation (events-2026-05-16.jsonl).
public final class EventLog {

    public static let shared = EventLog()

    private let inMemoryCapacity: Int
    private var buffer: [CEvent]
    private let queue = DispatchQueue(label: "AgentNotch.EventLog.queue")
    private var seqCounter: Int
    private let encoder: JSONEncoder

    public init(inMemoryCapacity: Int = 500) {
        self.inMemoryCapacity = inMemoryCapacity
        self.buffer = []
        self.buffer.reserveCapacity(inMemoryCapacity)
        self.seqCounter = 0
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        self.ensureDirectoryExists()
    }

    // MARK: Public API

    /// Issue the next monotonic seq number. Callers use this to populate `CEvent.seq`
    /// at construction time. (We expose this rather than mutating events post-construction.)
    public func nextSeq() -> Int {
        queue.sync {
            seqCounter += 1
            return seqCounter
        }
    }

    /// Append an event to the in-memory buffer + the on-disk JSONL file.
    public func append(_ event: CEvent) {
        queue.sync {
            buffer.append(event)
            if buffer.count > inMemoryCapacity {
                buffer.removeFirst(buffer.count - inMemoryCapacity)
            }
            appendToDisk(event)
        }
    }

    /// Most recent N events (in chronological order, oldest first).
    public func tail(_ n: Int) -> [CEvent] {
        queue.sync {
            Array(buffer.suffix(n))
        }
    }

    /// Full in-memory buffer snapshot.
    public func snapshot() -> [CEvent] {
        queue.sync { Array(buffer) }
    }

    // MARK: Persistence

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
        return Self.storageRoot.appendingPathComponent("events-\(day).jsonl")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Append one JSONL line. Best-effort: if disk write fails, the in-memory copy survives.
    private func appendToDisk(_ event: CEvent) {
        guard let data = try? encoder.encode(event) else { return }
        let url = currentLogFile(for: event.t)
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
