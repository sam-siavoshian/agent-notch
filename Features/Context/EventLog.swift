import Foundation

/// Thread-safe append-only ring buffer + per-day JSONL persistence for CEvents.
/// On disk: `~/Library/Application Support/AgentNotch/ContextMemory/events-YYYY-MM-DD.jsonl`.
public final class EventLog {

    public static let shared = EventLog()

    private let inMemoryCapacity = 500
    private var buffer: [CEvent] = []
    private let queue = DispatchQueue(label: "AgentNotch.EventLog.queue")
    private var seqCounter = 0
    private let encoder: JSONEncoder

    private init() {
        buffer.reserveCapacity(inMemoryCapacity)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
    }

    // MARK: Public API

    /// Issue the next monotonic seq number. Used to populate `CEvent.seq` at construction time.
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

    /// Most recent N events (chronological order, oldest first).
    public func tail(_ n: Int) -> [CEvent] {
        queue.sync { Array(buffer.suffix(n)) }
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
        let url = Self.storageRoot.appendingPathComponent("events-\(Self.dayFormatter.string(from: event.t)).jsonl")
        var line = data
        line.append(0x0A) // \n
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: [.atomic])
        }
    }
}
