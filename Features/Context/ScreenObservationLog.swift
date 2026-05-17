import Foundation

/// Rolling in-memory ring + append-only on-disk JSONL log of every
/// `SurfaceObservation` produced by `GeminiObserver`. The Dev Tools "Screen
/// Obs" pane reads `tail(...)` for the live stream; the JSONL file on disk
/// is the durable record we can replay or post-process between sessions.
public final class ScreenObservationLog {
    public static let shared = ScreenObservationLog()

    private var buffer: [SurfaceObservation] = []
    private static let capacity = 100
    private let queue = DispatchQueue(label: "AgentNotch.ScreenObservationLog.queue")
    private let encoder: JSONEncoder

    private static let storageRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
    }()
    private static let jsonlFile: URL = storageRoot.appendingPathComponent("screen_observations.jsonl")

    public init() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        self.encoder = e
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
    }

    public func record(_ obs: SurfaceObservation) {
        queue.sync {
            buffer.append(obs)
            if buffer.count > Self.capacity {
                buffer.removeFirst(buffer.count - Self.capacity)
            }
            if let data = try? encoder.encode(obs) {
                var line = data; line.append(0x0A)
                if let h = try? FileHandle(forWritingTo: Self.jsonlFile) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: line)
                } else {
                    try? line.write(to: Self.jsonlFile)
                }
            }
        }
    }

    public func tail(_ n: Int) -> [SurfaceObservation] {
        queue.sync { Array(buffer.suffix(n)) }
    }

    public func snapshot() -> [SurfaceObservation] {
        queue.sync { Array(buffer) }
    }
}
