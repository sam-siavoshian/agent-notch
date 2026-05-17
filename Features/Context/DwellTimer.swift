import Foundation
import AppKit

/// Tracks focus duration per (app, window). When focus moves elsewhere AND stays away ≥10s,
/// emits a `.dwell` CEvent with the accumulated duration. Dwells <15s are discarded as noise.
public final class DwellTimer {

    public static let shared = DwellTimer()

    private struct Key: Hashable { let bundleID: String; let windowTitle: String }
    private struct DwellState {
        var enteredAt: Date
        var accumulated: TimeInterval
        var lastLeftAt: Date?             // nil = still focused
    }

    private var current: Key?
    private var states: [Key: DwellState] = [:]
    private var sweepTimer: Timer?

    private let queue = DispatchQueue(label: "AgentNotch.DwellTimer.queue")

    private init() {}

    public func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            handleFocusEntered(bundleID: app.bundleIdentifier ?? "<unknown>", windowTitle: app.localizedName ?? "<unknown>")
        }
    }

    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Use localized name as window title (avoids AX/CGWindow query).
        let bundleID = app.bundleIdentifier ?? "<unknown>"
        let windowTitle = app.localizedName ?? "<unknown>"
        handleFocusEntered(bundleID: bundleID, windowTitle: windowTitle)
    }

    private func handleFocusEntered(bundleID: String, windowTitle: String) {
        let now = Date()
        queue.sync {
            if let prev = current, prev.bundleID != bundleID || prev.windowTitle != windowTitle {
                if var state = states[prev] {
                    state.accumulated += now.timeIntervalSince(state.enteredAt)
                    state.lastLeftAt = now
                    states[prev] = state
                }
            }
            let key = Key(bundleID: bundleID, windowTitle: windowTitle)
            if var state = states[key] {
                // Resume — clear lastLeftAt, reset entered timer
                state.enteredAt = now
                state.lastLeftAt = nil
                states[key] = state
            } else {
                states[key] = DwellState(enteredAt: now, accumulated: 0, lastLeftAt: nil)
            }
            current = key
        }
    }

    /// Sweep timer: any state with `lastLeftAt > 10s ago` emits a dwell event and is cleared.
    private func sweep() {
        let now = Date()
        var toEmit: [(Key, TimeInterval)] = []
        queue.sync {
            var toRemove: [Key] = []
            for (key, state) in states {
                guard let leftAt = state.lastLeftAt else { continue }
                if now.timeIntervalSince(leftAt) >= 10.0 {
                    if state.accumulated >= 15.0 {
                        toEmit.append((key, state.accumulated))
                    }
                    toRemove.append(key)
                }
            }
            for key in toRemove { states.removeValue(forKey: key) }
        }
        for (key, duration) in toEmit {
            DispatchQueue.main.async {
                _ = EventIngester.shared.ingest(
                    kind: .dwell,
                    sourceMonitor: "DwellTimer",
                    payload: .dwell(durationS: duration, signal: duration >= 60 ? "deep focus" : nil),
                    explicitApp: EventIngester.AppContext(name: key.windowTitle, bundleID: key.bundleID, windowTitle: key.windowTitle)
                )
            }
        }
    }
}
