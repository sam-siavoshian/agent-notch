//
//  AgentEventSource.swift
//  Agent in the Notch
//
//  Single shared CGEventSource for every synthetic event the agent emits.
//  Two reasons:
//   1. localEventsSuppressionInterval = 0 — without this, macOS WindowServer
//      suppresses our synthetic moves whenever the user is also moving their
//      real trackpad. We need both streams to flow independently.
//   2. Stable sourceStateID — KeystrokeMonitor's CGEventTap sees every keydown,
//      including ours. We stamp our source ID and the monitor filters by it,
//      so the agent's own typing never gets ingested as user input and fed
//      back to the model on the next turn.
//

import Foundation
import CoreGraphics

public enum AgentEventSource {

    /// Shared event source. Created lazily on first access. Returned as
    /// `CGEventSource?` because `CGEventSource(stateID:)` is fallible in the
    /// underlying C API, even though it has never actually returned nil on
    /// macOS in practice.
    public static let shared: CGEventSource? = {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            return nil
        }
        // Synthetic events must not be suppressed by simultaneous real
        // trackpad input. Default is 250ms (the gesture-debounce window).
        src.localEventsSuppressionInterval = 0
        return src
    }()

    /// The stateID stamped on every event made with `shared`. Read at the
    /// CGEventTap layer via `event.getIntegerValueField(.eventSourceStateID)`
    /// to identify and skip our own synthetic events.
    public static let sourceStateID: Int64 = {
        guard let src = shared else { return 0 }
        return Int64(src.sourceStateID.rawValue)
    }()

    /// True when the event was emitted by our own AgentEventSource. Used by
    /// KeystrokeMonitor / future ClipboardWatcher / future mouse taps to skip
    /// agent-self events instead of ingesting them as user activity.
    @inlinable
    public static func isSelfEvent(_ event: CGEvent) -> Bool {
        let id = event.getIntegerValueField(.eventSourceStateID)
        return id != 0 && id == sourceStateID
    }
}
