import Foundation

/// Persistence for the L5 narrative layer:
///   - active_task.json           ← current CActiveTask (or absent if no active task)
///   - task_archive/YYYY-MM-DD.jsonl  ← one JSON line per archived CArchivedTask
///   - resources_index.json       ← snapshot of ResourceIndex (rebuilt at boot)
///
/// All writes are atomic (write-to-temp + rename). Reads return nil/defaults on absence.
public final class L5Store {

    public static let shared = L5Store()

    private let queue = DispatchQueue(label: "AgentNotch.L5Store.queue")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
        ensureDirectories()
    }

    // MARK: - Paths

    public static let storageRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
    }()

    public static var activeTaskURL: URL { storageRoot.appendingPathComponent("active_task.json") }
    public static var resourcesIndexURL: URL { storageRoot.appendingPathComponent("resources_index.json") }
    public static var taskArchiveRoot: URL { storageRoot.appendingPathComponent("task_archive", isDirectory: true) }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.taskArchiveRoot, withIntermediateDirectories: true)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - active_task.json

    public func loadActiveTask() -> CActiveTask? {
        queue.sync {
            guard let data = try? Data(contentsOf: Self.activeTaskURL) else { return nil }
            return try? decoder.decode(CActiveTask.self, from: data)
        }
    }

    public func saveActiveTask(_ task: CActiveTask) throws {
        try queue.sync {
            let data = try encoder.encode(task)
            try writeAtomic(data: data, to: Self.activeTaskURL)
        }
    }

    public func clearActiveTask() {
        queue.sync {
            try? FileManager.default.removeItem(at: Self.activeTaskURL)
        }
    }

    // MARK: - task_archive/<date>.jsonl

    /// Append an archived task to today's archive file.
    public func archive(_ task: CArchivedTask) throws {
        try queue.sync {
            let day = Self.dayFormatter.string(from: task.endedAt)
            let url = Self.taskArchiveRoot.appendingPathComponent("\(day).jsonl")
            let data = try encoder.encode(task)
            var line = data
            line.append(0x0A)
            try appendOrCreate(data: line, to: url)
        }
    }

    /// Load all archived tasks for a date range (inclusive).
    /// Returns `[]` for any missing day. Useful for the "today" view in Selector / Dev Tools.
    public func loadArchive(from start: Date, to end: Date) -> [CArchivedTask] {
        queue.sync {
            var out: [CArchivedTask] = []
            var cursor = start
            while cursor <= end {
                let day = Self.dayFormatter.string(from: cursor)
                let url = Self.taskArchiveRoot.appendingPathComponent("\(day).jsonl")
                if let data = try? String(contentsOf: url, encoding: .utf8) {
                    for line in data.split(separator: "\n") where !line.isEmpty {
                        if let lineData = line.data(using: .utf8),
                           let task = try? decoder.decode(CArchivedTask.self, from: lineData) {
                            out.append(task)
                        }
                    }
                }
                cursor = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? end.addingTimeInterval(86_400)
            }
            return out
        }
    }

    // MARK: - resources_index.json

    public func loadResourcesIndex() -> [CResourceRef] {
        queue.sync {
            guard let data = try? Data(contentsOf: Self.resourcesIndexURL),
                  let refs = try? decoder.decode([CResourceRef].self, from: data) else { return [] }
            return refs
        }
    }

    public func saveResourcesIndex(_ refs: [CResourceRef]) throws {
        try queue.sync {
            let data = try encoder.encode(refs)
            try writeAtomic(data: data, to: Self.resourcesIndexURL)
        }
    }

    // MARK: - File helpers

    private func writeAtomic(data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])
        // Replace destination atomically.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func appendOrCreate(data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }
}
