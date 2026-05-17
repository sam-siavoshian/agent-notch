import Foundation

/// Per-(bundleID, surface) accumulated UI knowledge: every control we've ever
/// observed on this surface, with seen_count + last_seen. The Selector reads
/// this at long-press time to give Claude a richer surface map than what a
/// single screenshot snapshot would provide.
///
/// Storage is keyed on the **bundle identifier** (e.g. `com.apple.dt.Xcode`),
/// not the localized app display name. Display names vary across language and
/// app version ("Visual Studio Code" vs "Code"); using them as the key caused
/// silent memory misses where the observer wrote under one name and the
/// selector read under another. The `app` field on `SurfaceMemory` is kept
/// as a denormalized display label only.
public final class SurfaceMemoryStore {
    public static let shared = SurfaceMemoryStore()

    public struct SurfaceMemory: Codable {
        public let bundleID: String        // canonical key
        public var app: String             // display name (latest seen)
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
    private static let pruneScheduler = DispatchQueue(label: "AgentNotch.SurfaceMemoryStore.prune", qos: .utility)
    /// Trigger an opportunistic prune every Nth accumulate. Guarded by `queue`.
    private static let pruneIntervalAccumulations: Int = 50
    private var accumulateCounter: Int = 0
    private static let storageRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextMemory", isDirectory: true)
            .appendingPathComponent("surfaces", isDirectory: true)
    }()

    // Retention constants used by `prune()`.
    private static let maxAgeDays: Int = 30
    private static let maxSurfacesPerApp: Int = 50
    private static let minObservationsToKeep: Int = 2

    public init() {
        try? FileManager.default.createDirectory(at: Self.storageRoot, withIntermediateDirectories: true)
    }

    /// Merge an observation into per-surface memory. Bumps seen_count for known
    /// controls, adds new ones, updates last_seen. Skips observations that
    /// arrive without a bundleID (e.g. older JSONL lines re-read after a
    /// schema bump) — the key would be ambiguous.
    public func accumulate(_ obs: SurfaceObservation) {
        guard let bundleID = obs.bundleID, !bundleID.isEmpty,
              let surface = obs.currentSurface, !surface.isEmpty else { return }
        let app = obs.frontmostApp ?? bundleID
        var shouldSchedulePrune = false
        queue.sync {
            var memory = loadMemory(bundleID: bundleID, surface: surface)
                ?? SurfaceMemory(bundleID: bundleID, app: app, surface: surface, controls: [], lastSeen: obs.t, observationCount: 0)
            memory.app = app   // refresh display name from latest observation
            memory.lastSeen = obs.t
            memory.observationCount += 1

            for control in obs.observableControls {
                let needle = control.label.lowercased()
                if let idx = memory.controls.firstIndex(where: { $0.label.lowercased() == needle }) {
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

            accumulateCounter &+= 1
            if accumulateCounter % Self.pruneIntervalAccumulations == 0 {
                shouldSchedulePrune = true
            }
        }
        if shouldSchedulePrune {
            Self.pruneScheduler.async { [weak self] in
                guard let self else { return }
                self.queue.sync { self.performPruneLocked() }
            }
        }
    }

    /// All surface memories for a given bundle ID (across all surfaces seen).
    public func memories(forBundle bundleID: String) -> [SurfaceMemory] {
        queue.sync {
            let appDir = Self.storageRoot.appendingPathComponent(safeFilename(bundleID))
            guard let files = try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) else { return [] }
            return files.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data)
            }
        }
    }

    /// Remove memories older than `maxAgeDays` with fewer than
    /// `minObservationsToKeep` observations, then per-app cap to
    /// `maxSurfacesPerApp` by `observationCount` (descending).
    /// Must be called while holding `queue`.
    private func performPruneLocked() {
        let fm = FileManager.default
        guard let appDirs = try? fm.contentsOfDirectory(at: Self.storageRoot, includingPropertiesForKeys: nil) else {
            return
        }
        let now = Date()
        let maxAge = TimeInterval(Self.maxAgeDays) * 86_400

        for appDir in appDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: appDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) else { continue }

            // Decode survivors; skip files that fail to decode (leave them alone).
            struct Survivor { let url: URL; let memory: SurfaceMemory }
            var survivors: [Survivor] = []

            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let memory = try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data) else {
                    continue
                }
                let age = now.timeIntervalSince(memory.lastSeen)
                if age > maxAge && memory.observationCount < Self.minObservationsToKeep {
                    try? fm.removeItem(at: url)
                    continue
                }
                survivors.append(Survivor(url: url, memory: memory))
            }

            // Per-app cap: keep top-N by observationCount, delete the rest.
            if survivors.count > Self.maxSurfacesPerApp {
                let sorted = survivors.sorted { lhs, rhs in
                    if lhs.memory.observationCount != rhs.memory.observationCount {
                        return lhs.memory.observationCount > rhs.memory.observationCount
                    }
                    return lhs.memory.lastSeen > rhs.memory.lastSeen
                }
                for s in sorted.dropFirst(Self.maxSurfacesPerApp) {
                    try? fm.removeItem(at: s.url)
                }
            }
        }
    }

    private func loadMemory(bundleID: String, surface: String) -> SurfaceMemory? {
        let url = pathFor(bundleID: bundleID, surface: surface)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data)
    }

    private static let memoryEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func saveMemory(_ memory: SurfaceMemory) throws {
        let url = pathFor(bundleID: memory.bundleID, surface: memory.surface)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.memoryEncoder.encode(memory)
        try data.write(to: url, options: [.atomic])
    }

    private func pathFor(bundleID: String, surface: String) -> URL {
        Self.storageRoot
            .appendingPathComponent(safeFilename(bundleID))
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
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
