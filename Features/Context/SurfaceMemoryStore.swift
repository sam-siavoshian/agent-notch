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

    /// Retention policy for accumulated surface memory.
    public struct RetentionPolicy {
        public let maxAgeDays: Int               // delete surfaces unseen for > this many days
        public let maxSurfacesPerApp: Int        // keep top-N by observationCount per app
        public let minObservationsToKeep: Int    // surfaces with fewer observations than this are eligible for early pruning

        public init(maxAgeDays: Int, maxSurfacesPerApp: Int, minObservationsToKeep: Int) {
            self.maxAgeDays = maxAgeDays
            self.maxSurfacesPerApp = maxSurfacesPerApp
            self.minObservationsToKeep = minObservationsToKeep
        }

        public static let `default` = RetentionPolicy(maxAgeDays: 30, maxSurfacesPerApp: 50, minObservationsToKeep: 2)
    }

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

            accumulateCounter &+= 1
            if accumulateCounter % Self.pruneIntervalAccumulations == 0 {
                shouldSchedulePrune = true
            }
        }
        if shouldSchedulePrune {
            Self.pruneScheduler.async { [weak self] in
                self?.prune()
            }
        }
    }

    /// Look up accumulated memory for a (bundleID, surface) pair. Returns nil if absent.
    public func memory(forBundle bundleID: String, surface: String) -> SurfaceMemory? {
        queue.sync { loadMemory(bundleID: bundleID, surface: surface) }
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

    /// All bundle IDs that have surface memory.
    public func allBundleIDs() -> [String] {
        queue.sync {
            (try? FileManager.default.contentsOfDirectory(at: Self.storageRoot, includingPropertiesForKeys: nil))?
                .map { $0.lastPathComponent } ?? []
        }
    }

    /// Find surfaces from ANY bundle whose surface name, app name, or control
    /// labels match any of the given lowercased tokens. This is the
    /// cross-app deictic resolver: when the user says "DM phone1k" while
    /// browsing in Brave, the bundle-scoped `memories(forBundle:)` returns
    /// only Brave surfaces, but the phone1k Discord surface lives under a
    /// different bundle. Without this method that surface stays invisible
    /// to Mercury and the agent falls back to a generic Messages/Mail path.
    ///
    /// Scoring: surface-name hit = 5, app-name hit = 2, control-label hit = 1.
    /// Higher-score surfaces sort first; ties broken by `observationCount`.
    /// Skips tokens shorter than 3 chars to avoid junk matches on "is"/"to".
    public func searchAcrossApps(matchingTokens tokens: [String], limit: Int = 4) -> [SurfaceMemory] {
        let normalized = Set(tokens.map { $0.lowercased() }.filter { $0.count >= 3 })
        guard !normalized.isEmpty else { return [] }
        var scored: [(score: Int, mem: SurfaceMemory)] = []
        for bid in allBundleIDs() {
            for mem in memories(forBundle: bid) {
                var score = 0
                let surfaceLower = mem.surface.lowercased()
                let appLower = mem.app.lowercased()
                for tok in normalized {
                    if surfaceLower.contains(tok) { score += 5 }
                    if appLower.contains(tok) { score += 2 }
                    for ctrl in mem.controls where ctrl.label.lowercased().contains(tok) {
                        score += 1
                    }
                }
                if score > 0 { scored.append((score, mem)) }
            }
        }
        return scored
            .sorted { (lhs, rhs) in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.mem.observationCount > rhs.mem.observationCount
            }
            .prefix(limit)
            .map { $0.mem }
    }

    /// Remove memories older than `policy.maxAgeDays` (with fewer than
    /// `policy.minObservationsToKeep` observations), then per-app cap to
    /// `policy.maxSurfacesPerApp` by `observationCount` (descending).
    /// Returns counts of `{scanned, deleted}`.
    @discardableResult
    public func prune(_ policy: RetentionPolicy = .default) -> (scanned: Int, deleted: Int) {
        queue.sync {
            performPruneLocked(policy)
        }
    }

    private func performPruneLocked(_ policy: RetentionPolicy) -> (scanned: Int, deleted: Int) {
        let fm = FileManager.default
        guard let appDirs = try? fm.contentsOfDirectory(at: Self.storageRoot, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        let now = Date()
        let maxAge = TimeInterval(policy.maxAgeDays) * 86_400
        var scanned = 0
        var deleted = 0

        for appDir in appDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: appDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) else { continue }

            // Decode survivors; skip files that fail to decode (leave them alone).
            struct Survivor { let url: URL; let memory: SurfaceMemory }
            var survivors: [Survivor] = []

            for url in files where url.pathExtension == "json" {
                scanned += 1
                guard let data = try? Data(contentsOf: url),
                      let memory = try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data) else {
                    continue
                }
                let age = now.timeIntervalSince(memory.lastSeen)
                if age > maxAge && memory.observationCount < policy.minObservationsToKeep {
                    if (try? fm.removeItem(at: url)) != nil {
                        deleted += 1
                    }
                    continue
                }
                survivors.append(Survivor(url: url, memory: memory))
            }

            // Per-app cap: keep top-N by observationCount, delete the rest.
            if survivors.count > policy.maxSurfacesPerApp {
                let sorted = survivors.sorted { lhs, rhs in
                    if lhs.memory.observationCount != rhs.memory.observationCount {
                        return lhs.memory.observationCount > rhs.memory.observationCount
                    }
                    return lhs.memory.lastSeen > rhs.memory.lastSeen
                }
                for s in sorted.dropFirst(policy.maxSurfacesPerApp) {
                    if (try? fm.removeItem(at: s.url)) != nil {
                        deleted += 1
                    }
                }
            }
        }

        return (scanned, deleted)
    }

    private func loadMemory(bundleID: String, surface: String) -> SurfaceMemory? {
        let url = pathFor(bundleID: bundleID, surface: surface)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(SurfaceMemory.self, from: data)
    }

    private func saveMemory(_ memory: SurfaceMemory) throws {
        let url = pathFor(bundleID: memory.bundleID, surface: memory.surface)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(memory)
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
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
