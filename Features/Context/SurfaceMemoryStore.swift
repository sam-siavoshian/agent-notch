import Foundation

/// Per-(app, surface) accumulated UI knowledge: every control we've ever
/// observed on this surface, with seen_count + last_seen. The Selector reads
/// this at long-press time to give Claude a richer surface map than what a
/// single screenshot snapshot would provide.
public final class SurfaceMemoryStore {
    public static let shared = SurfaceMemoryStore()

    public struct SurfaceMemory: Codable {
        public let app: String
        public let surface: String         // e.g. "Slack #design composer"
        public var controls: [Control]
        public var lastSeen: Date
        public var observationCount: Int

        public struct Control: Codable {
            public let label: String
            public var purpose: String?
            public var location: String?
            public var iconHint: String?
            public var seenCount: Int
            public var lastSeen: Date
        }
    }

    private let queue = DispatchQueue(label: "AgentNotch.SurfaceMemoryStore.queue")
    private static let storageRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
            .appendingPathComponent("surfaces", isDirectory: true)
    }()

    public init() {
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
    }

    /// Merge an observation into per-surface memory. Bumps seen_count for known
    /// controls, adds new ones, updates last_seen.
    public func accumulate(_ obs: SurfaceObservation) {
        guard let app = obs.frontmostApp, let surface = obs.currentSurface, !surface.isEmpty else { return }
        queue.sync {
            var memory = loadMemory(app: app, surface: surface)
                ?? SurfaceMemory(app: app, surface: surface, controls: [], lastSeen: obs.t, observationCount: 0)
            memory.lastSeen = obs.t
            memory.observationCount += 1

            for control in obs.observableControls {
                if let idx = memory.controls.firstIndex(where: { $0.label.lowercased() == control.label.lowercased() }) {
                    memory.controls[idx].seenCount += 1
                    memory.controls[idx].lastSeen = obs.t
                    if memory.controls[idx].purpose == nil, control.purpose != nil {
                        memory.controls[idx].purpose = control.purpose
                    }
                    if memory.controls[idx].location == nil, control.location != nil {
                        memory.controls[idx].location = control.location
                    }
                    if memory.controls[idx].iconHint == nil, control.iconHint != nil {
                        memory.controls[idx].iconHint = control.iconHint
                    }
                } else {
                    memory.controls.append(SurfaceMemory.Control(
                        label: control.label, purpose: control.purpose, location: control.location,
                        iconHint: control.iconHint, seenCount: 1, lastSeen: obs.t
                    ))
                }
            }
            try? saveMemory(memory)
        }
    }

    /// Look up accumulated memory for an (app, surface) pair. Returns nil if absent.
    public func memory(for app: String, surface: String) -> SurfaceMemory? {
        queue.sync { loadMemory(app: app, surface: surface) }
    }

    /// All surface memories for a given app (across all surfaces seen).
    public func memories(for app: String) -> [SurfaceMemory] {
        queue.sync {
            let appDir = Self.storageRoot.appendingPathComponent(safeFilename(app))
            guard let files = try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) else { return [] }
            return files.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data)
            }
        }
    }

    /// All apps that have surface memory.
    public func allApps() -> [String] {
        queue.sync {
            (try? FileManager.default.contentsOfDirectory(at: Self.storageRoot, includingPropertiesForKeys: nil))?
                .map { $0.lastPathComponent } ?? []
        }
    }

    private func loadMemory(app: String, surface: String) -> SurfaceMemory? {
        let url = pathFor(app: app, surface: surface)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data)
    }

    private func saveMemory(_ memory: SurfaceMemory) throws {
        let url = pathFor(app: memory.app, surface: memory.surface)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(memory)
        try data.write(to: url, options: [.atomic])
    }

    private func pathFor(app: String, surface: String) -> URL {
        Self.storageRoot
            .appendingPathComponent(safeFilename(app))
            .appendingPathComponent(safeFilename(surface) + ".json")
    }

    private func safeFilename(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
         .replacingOccurrences(of: ":", with: "_")
         .replacingOccurrences(of: " ", with: "_")
         .lowercased()
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
