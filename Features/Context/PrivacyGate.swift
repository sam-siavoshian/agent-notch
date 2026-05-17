import Foundation
import AppKit
import Carbon.HIToolbox

/// Single chokepoint for monitor-emitted events before they reach EventLog.
/// Drops events from `neverLogApps`, redacts secure-input text, propagates clipboard taint,
/// and gates everything behind `collectionPaused` (allowing only throttled heartbeats).
/// Returns nil for events to drop; otherwise a (possibly redacted) CEvent.
public final class PrivacyGate {

    public static let shared = PrivacyGate()

    /// Frontmost-app bundle IDs whose events are dropped entirely.
    public var neverLogApps: Set<String> = [
        "com.1password.1password7",
        "com.1password.1password8",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.agentnotch.app"
    ]

    /// When true, suppress all events except occasional heartbeats.
    public var collectionPaused: Bool = false

    /// Daily redaction counters surfaced in Dev Tools.
    public private(set) var redactionCounts: [CEvent.RedactionReason: Int] = [:]

    private let queue = DispatchQueue(label: "AgentNotch.PrivacyGate.queue")
    private var lastHeartbeat: Date = .distantPast

    public init() {}

    /// Process one event. Returns nil to drop, or a possibly-redacted CEvent.
    public func process(_ event: CEvent) -> CEvent? {
        // Belt-and-suspenders: never log events from our own process.
        if let selfBundle = Bundle.main.bundleIdentifier, event.bundleID == selfBundle {
            return nil
        }

        // When paused, only let heartbeat-shaped events through (≤1/min).
        if collectionPaused {
            let allowed = (event.kind == .appSwitch) ||
                          (event.kind == .screen && Date().timeIntervalSince(lastHeartbeat) > 60)
            guard allowed else { return nil }
            queue.sync { lastHeartbeat = Date() }
        }

        var ev = event

        // Drop everything from a never-log app.
        if let bundle = event.bundleID, neverLogApps.contains(bundle) {
            return nil
        }

        // Clipboard taint propagation: drop pastes whose source is a never-log app.
        if case let .copyPaste(from, _, _) = event.payload, neverLogApps.contains(from.app) {
            return nil
        }

        // Secure-input: redact text content from input events.
        if case let .input(element, _, context, submit, mods) = event.payload, IsSecureEventInputEnabled() {
            ev.redacted = true
            ev.redactionReason = .secureInput
            ev = ev.with(payload: .input(element: element, text: "<redacted>", context: context, submitKey: submit, modifiers: mods))
        }

        // Upstream monitors (BrowserAdapter, ClipboardWatcher) may already have set
        // redactionReason for browser-password / URL-credential / password-shape cases —
        // count those defense-in-depth.
        if let reason = ev.redactionReason {
            queue.sync { redactionCounts[reason, default: 0] += 1 }
        }

        return ev
    }
}

// MARK: - CEvent mutation helper

private extension CEvent {
    func with(payload newPayload: Payload) -> CEvent {
        CEvent(
            id: id,
            t: t,
            seq: seq,
            kind: kind,
            sourceMonitor: sourceMonitor,
            app: app,
            bundleID: bundleID,
            pid: pid,
            windowTitle: windowTitle,
            windowID: windowID,
            displayID: displayID,
            redacted: redacted,
            redactionReason: redactionReason,
            payload: newPayload
        )
    }
}
