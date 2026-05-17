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

    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Add or refresh a single resource. Updates lastSeen if URI is already present.
    public func record(_ ref: CResourceRef) {
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
                evictIfNeeded()
            }
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
}
