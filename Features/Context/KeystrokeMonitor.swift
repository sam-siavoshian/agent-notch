import Foundation
import AppKit
import CoreGraphics

/// Captures key events via CGEvent tap, burst-batches them into `input` CEvents.
///
/// Requires Input Monitoring TCC permission (separate from Accessibility on macOS 14+).
/// If denied, the monitor runs in degraded mode: it doesn't install a tap and emits nothing.
/// The user is prompted via the onboarding flow (PermissionChecker.inputMonitoring).
///
/// Burst-batching: keystrokes hitting the same focused element within 2s coalesce into a single
/// `input` event. Finalization triggers: focus change, 1.5s idle, or a submit-key (return/tab/cmd+return).
public final class KeystrokeMonitor {

    public static let shared = KeystrokeMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Burst-batching state
    private var pendingText: String = ""
    private var pendingModifiers: [String] = []
    private var pendingStarted: Date?
    private var pendingFocusedElement: String?
    private var idleTimer: Timer?

    private let queue = DispatchQueue(label: "AgentNotch.KeystrokeMonitor.queue")

    // Hooked in by AXObserver when the focused element changes mid-burst.
    public var focusedElementProvider: (() -> String?)?

    public init() {}

    /// Start the CGEvent tap. Returns false if Input Monitoring permission is denied.
    @discardableResult
    public func start() -> Bool {
        guard CGPreflightListenEventAccess() else {
            // Permission not granted; degraded mode.
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeystrokeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: userInfo
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        flushPending(reason: "stop")
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else { return }

        let chars = readChars(from: event)
        let flags = event.flags
        let modifiers = readableModifiers(flags)

        // Submit keys finalize a burst.
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isReturn = (keyCode == 36)      // kVK_Return
        let isTab    = (keyCode == 48)      // kVK_Tab
        let cmdHeld  = flags.contains(.maskCommand)

        if isReturn || isTab || (isReturn && cmdHeld) {
            // Append the submit key's text contribution if any, then flush.
            queue.sync {
                if !chars.isEmpty { pendingText.append(chars) }
                let submitKey = isReturn ? (cmdHeld ? "cmd+return" : "return") : "tab"
                flushPending(reason: submitKey)
            }
            return
        }

        // Regular character key — accumulate.
        queue.sync {
            if pendingStarted == nil {
                pendingStarted = Date()
                pendingFocusedElement = focusedElementProvider?()
                pendingModifiers = modifiers
            } else if Date().timeIntervalSince(pendingStarted!) > 2.0 {
                // Too old — flush before adding.
                flushPending(reason: "idle_timeout")
                pendingStarted = Date()
                pendingFocusedElement = focusedElementProvider?()
                pendingModifiers = modifiers
            }
            pendingText.append(chars)
            resetIdleTimer()
        }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.queue.sync { self?.flushPending(reason: "idle_timeout") }
        }
    }

    /// MUST be called from `queue`.
    private func flushPending(reason: String) {
        guard !pendingText.isEmpty else {
            pendingStarted = nil
            pendingFocusedElement = nil
            pendingModifiers = []
            return
        }
        let payload: CEvent.Payload = .input(
            element: pendingFocusedElement,
            text: pendingText,
            context: nil,
            submitKey: reason,
            modifiers: pendingModifiers
        )
        // Hop off the queue before ingest (ingest may touch other singletons).
        let copy = payload
        DispatchQueue.main.async {
            _ = EventIngester.shared.ingest(kind: .input, sourceMonitor: "KeystrokeMonitor", payload: copy)
        }
        pendingText = ""
        pendingStarted = nil
        pendingFocusedElement = nil
        pendingModifiers = []
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func readChars(from event: CGEvent) -> String {
        var length: Int = 0
        var chars: [UniChar] = Array(repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func readableModifiers(_ flags: CGEventFlags) -> [String] {
        var out: [String] = []
        if flags.contains(.maskCommand)   { out.append("cmd") }
        if flags.contains(.maskAlternate) { out.append("alt") }
        if flags.contains(.maskControl)   { out.append("ctrl") }
        if flags.contains(.maskShift)     { out.append("shift") }
        return out
    }
}
