import Foundation

/// Rolling index of URIs/files/channels the user has touched recently. Adapters
/// call `record(_:)`; Selector reads the top-N via `recent(limit:)`.
///
/// Entries are deduplicated by URI; subsequent calls for the same URI update
/// `lastSeen` only. Bounded at `capacity` with LRU eviction.
public final class ResourceIndex {

    public static let shared = ResourceIndex()

    private let capacity: Int
    private var byURI: [String: CResourceRef] = [:]
    private let queue = DispatchQueue(label: "AgentNotch.ResourceIndex.queue")

    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Add or refresh a single resource. Updates lastSeen if URI already present.
    public func record(_ ref: CResourceRef) {
        var isNewURI = false
        queue.sync {
            if let existing = byURI[ref.uri] {
                byURI[ref.uri] = CResourceRef(
                    kind: existing.kind,
                    uri: existing.uri,
                    label: ref.label ?? existing.label,
                    app: ref.app ?? existing.app,
                    lastSeen: ref.lastSeen
                )
            } else {
                byURI[ref.uri] = ref
                isNewURI = true
                evictIfNeeded()
            }
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

    /// Most recently seen N resources, newest first.
    public func recent(limit: Int = 20) -> [CResourceRef] {
        queue.sync {
            Array(byURI.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(limit))
        }
    }

    /// MUST be called from `queue`.
    private func evictIfNeeded() {
        guard byURI.count > capacity else { return }
        let toRemove = byURI.values.sorted { $0.lastSeen < $1.lastSeen }.prefix(byURI.count - capacity)
        for r in toRemove { byURI.removeValue(forKey: r.uri) }
    }
}
