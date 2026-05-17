import Foundation

/// Looks up the `AppContextAdapter` for a given bundle ID. Concrete adapter
/// implementations register themselves here at module init.
public final class AdapterRegistry {

    public static let shared = AdapterRegistry()

    private var byBundleID: [String: AppContextAdapter] = [:]
    private let queue = DispatchQueue(label: "AgentNotch.AdapterRegistry.queue")

    private init() {}

    /// Register one adapter instance for all of its claimed bundle IDs.
    public func register(_ adapter: AppContextAdapter) {
        let ids = type(of: adapter).bundleIDs
        queue.sync {
            for id in ids { byBundleID[id] = adapter }
        }
    }

    /// Look up an adapter by bundle ID. Returns nil if no adapter claims this bundle.
    public func adapter(for bundleID: String) -> AppContextAdapter? {
        queue.sync { byBundleID[bundleID] }
    }

    /// All registered adapter instances (deduplicated by class identity).
    public func allRegistered() -> [AppContextAdapter] {
        queue.sync {
            var seen: Set<ObjectIdentifier> = []
            var out: [AppContextAdapter] = []
            for adapter in byBundleID.values {
                let id = ObjectIdentifier(adapter as AnyObject)
                if seen.insert(id).inserted {
                    out.append(adapter)
                }
            }
            return out
        }
    }

    /// Convenience: run snapshot() against the registered adapter for `bundleID`
    /// with a hard timeout. Returns nil on absent adapter, timeout, or error.
    public func snapshot(bundleID: String, timeout: TimeInterval = 0.2) async -> [String: AnyCodable]? {
        guard let adapter = adapter(for: bundleID) else { return nil }
        do {
            return try await withTimeout(seconds: timeout) {
                try await adapter.snapshot(bundleID: bundleID)
            }
        } catch {
            return nil
        }
    }
}

/// Race the async operation against a timeout. The first to complete wins.
private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AdapterError.timeout
        }
        guard let first = try await group.next() else {
            throw AdapterError.timeout
        }
        group.cancelAll()
        return first
    }
}
