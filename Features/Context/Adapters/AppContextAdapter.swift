import Foundation

/// One app-specific context adapter. Each adapter knows how to extract the
/// `app_specific` blob for the L2 snapshot and contribute resources to
/// `recent_resources` in L5.
///
/// Adapters are looked up by bundle ID via `AdapterRegistry`. A single adapter
/// implementation can claim multiple bundle IDs (e.g. one BrowserAdapter handles
/// Arc, Chrome, Safari, and Brave).
public protocol AppContextAdapter {
    /// Bundle IDs this adapter claims. Used by `AdapterRegistry` for lookup.
    static var bundleIDs: [String] { get }

    /// Per-snapshot extraction. Called at long-press time as part of building L2.
    /// Implementations MUST honor the 200ms hard deadline — return whatever is
    /// available, never block on slow operations.
    func snapshot(bundleID: String) async throws -> [String: AnyCodable]

    /// Recently-touched resources contributed by this app. Called periodically
    /// (every ~30s for active app, on focus change for others) to keep
    /// `ResourceIndex` warm.
    func recentResources(bundleID: String) async -> [CResourceRef]
}

/// Errors adapters may surface. Treat all of these as "fall back to nil app_specific".
public enum AdapterError: Error {
    case unsupportedBundle(String)
    case timeout
    case appUnreachable(String)            // e.g. AppleScript permission denied
    case malformedResponse(String)
}
