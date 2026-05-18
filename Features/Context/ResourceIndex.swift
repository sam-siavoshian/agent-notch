import Foundation

/// Rolling index of URIs/files/channels the user has touched recently. Adapters
/// contribute entries via `record(_:)`. Consumers (Phase 4 Selector) read the
/// top-N via `recent(limit:)`.
///
/// Entries are deduplicated by URI; subsequent calls for the same URI update
/// `lastSeen` only. Bounded at `capacity` entries with LRU eviction.
public final class ResourceIndex {

    public static let shared = ResourceIndex()

    private let capacity: Int
    private var byURI: [String: CResourceRef] = [:]
    private let queue = DispatchQueue(label: "AgentNotch.ResourceIndex.queue")

    /// Coalesces many rapid `record()` calls into one disk write. Worst case
    /// the latest state lands on disk `persistDebounce` after the last call.
    private var pendingPersist: DispatchWorkItem?
    private let persistQueue = DispatchQueue(label: "AgentNotch.ResourceIndex.persist", qos: .utility)
    private static let persistDebounce: TimeInterval = 1.0

    public init(capacity: Int = 100) {
        self.capacity = capacity
        // Hydrate from L5Store so the index survives restart. Without this,
        // every launch starts empty and the Selector loses its ability to
        // resolve "the X" against URLs/files the user already touched.
        for ref in L5Store.shared.loadResourcesIndex() {
            byURI[ref.uri] = ref
        }
    }

    /// Add or refresh a single resource. Updates lastSeen if URI is already present.
    public func record(_ ref: CResourceRef) {
        var isNewURI = false
        queue.sync {
            if var existing = byURI[ref.uri] {
                existing = CResourceRef(
                    kind: existing.kind,
                    uri: existing.uri,
                    label: ref.label ?? existing.label,
                    app: ref.app ?? existing.app,
                    lastSeen: ref.lastSeen
                )
                byURI[ref.uri] = existing
            } else {
                byURI[ref.uri] = ref
                isNewURI = true
                evictIfNeeded()
            }
            schedulePersistLocked()
        }
        if isNewURI {
            AgentObservabilityLog.shared.record(.memoryMutation(
                id: UUID(),
                t: Date(),
                kind: .resourceRecorded,
                summary: "\(ref.kind): \(ref.uri.prefix(80))"
            ))
        }
    }

    /// Bulk insert — convenience for adapter `recentResources()` returns.
    public func record(_ refs: [CResourceRef]) {
        for ref in refs { record(ref) }
    }

    /// Most recently seen N resources, newest first.
    public func recent(limit: Int = 20) -> [CResourceRef] {
        queue.sync {
            Array(byURI.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
        }
    }

    /// Clear all entries (settings or debug).
    public func clear() {
        queue.sync { byURI.removeAll() }
    }

    /// MUST be called from `queue`.
    private func evictIfNeeded() {
        guard byURI.count > capacity else { return }
        // LRU by lastSeen
        let toRemove = byURI.values.sorted { $0.lastSeen < $1.lastSeen }.prefix(byURI.count - capacity)
        for r in toRemove { byURI.removeValue(forKey: r.uri) }
    }

    /// MUST be called from `queue`. Schedules a debounced save so a burst of
    /// records (e.g. a browser snapshot returning 12 tabs) coalesces into one
    /// disk write. Saves snapshot the index off-queue to avoid blocking
    /// readers while encoding.
    private func schedulePersistLocked() {
        pendingPersist?.cancel()
        let snapshot = Array(byURI.values)
        let item = DispatchWorkItem {
            try? L5Store.shared.saveResourcesIndex(snapshot)
        }
        pendingPersist = item
        persistQueue.asyncAfter(deadline: .now() + Self.persistDebounce, execute: item)
    }
}
