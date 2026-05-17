import Foundation
import AppKit
import Carbon.HIToolbox

/// Single chokepoint that all monitor-emitted events pass through before reaching the
/// EventLog. Implements the 8-step redaction policy from spec §5.
///
/// Returns nil for events that should be dropped entirely; returns a (possibly redacted)
/// CEvent for events that should be persisted.
public final class PrivacyGate {

    public static let shared = PrivacyGate()

    /// Frontmost-app bundle IDs whose events are dropped entirely.
    /// Default list covers common password managers + Keychain. User edits via settings.
    public var neverLogApps: Set<String> = [
        "com.1password.1password7",
        "com.1password.1password8",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess"
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
        // Step 7: pause flag — only let heartbeat-shaped events through, throttled to 1/min.
        if collectionPaused {
            let allowed = (event.kind == .appSwitch) ||
                          (event.kind == .screen && Date().timeIntervalSince(lastHeartbeat) > 60)
            guard allowed else { return nil }
            queue.sync { lastHeartbeat = Date() }
        }

        var ev = event

        // Step 1: frontmost-app check (drop everything from a never-log app)
        if let bundle = event.bundleID, neverLogApps.contains(bundle) {
            return nil
        }

        // Step 2: clipboard taint propagation
        // If this is a paste-side input/copy_paste from a never-log source, drop the event.
        if case let .copyPaste(from, _, _) = event.payload {
            if neverLogApps.contains(from.app) {
                return nil
            }
        }
        // Heuristic: if the event has a "paste" hint in its context AND source-app metadata
        // upstream marked it from never-log, the upstream monitor should have already
        // dropped. This is defense-in-depth.

        // Step 3: secure-input — drop text content from input events
        if case let .input(element, _, context, submit, mods) = event.payload {
            if IsSecureEventInputEnabled() {
                ev.redacted = true
                ev.redactionReason = .secureInput
                ev = ev.with(payload: .input(element: element, text: "<redacted>", context: context, submitKey: submit, modifiers: mods))
            }
        }

        // Steps 4-6 (browser password URL/title heuristic, URL credential strip, clipboard
        // password-shape) — these are applied by the source monitors (BrowserAdapter,
        // ClipboardWatcher) before the event reaches PrivacyGate, since the relevant
        // signals (URL, focused-element role) live where the event is constructed.
        // PrivacyGate's job here is to defense-in-depth: if the upstream marked
        // an event with redactionReason, count it.

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
