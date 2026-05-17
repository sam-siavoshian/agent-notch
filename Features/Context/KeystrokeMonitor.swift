import Foundation
import AppKit
import CoreGraphics

/// Captures key events via CGEvent tap and burst-batches them into `input` CEvents.
/// Requires Input Monitoring TCC; if denied, runs in degraded mode (no tap installed).
/// Keystrokes hitting the same focused element coalesce; bursts finalize on focus change,
/// 1.5s idle, or a submit-key (return/tab/cmd+return).
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
        guard CGPreflightListenEventAccess() else { return false }
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
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isReturn = (keyCode == 36)      // kVK_Return
        let isTab    = (keyCode == 48)      // kVK_Tab
        let cmdHeld  = flags.contains(.maskCommand)
        let hasNonShiftModifier = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        // Modifier-shortcut fast path: when a non-shift modifier is held, the OS often
        // returns empty `chars`. Synthesize from keycode and emit as a single keystroke
        // so AnchorRecorder can detect the shortcut step.
        if hasNonShiftModifier {
            if let synthChar = Self.characterForKeycode(keyCode) {
                queue.sync { flushPending(reason: "shortcut") }
                let element = focusedElementProvider?()
                let payload: CEvent.Payload = .input(
                    element: element,
                    text: synthChar,
                    context: nil,
                    submitKey: "shortcut",
                    modifiers: modifiers
                )
                DispatchQueue.main.async {
                    _ = EventIngester.shared.ingest(kind: .input, sourceMonitor: "KeystrokeMonitor", payload: payload)
                }
                return
            }
            // Don't pollute prose with cmd-modified phantoms when keycode can't be decoded.
            return
        }

        // Submit keys finalize a burst.
        if isReturn || isTab {
            queue.sync {
                if !chars.isEmpty { pendingText.append(chars) }
                let submitKey = isReturn ? (cmdHeld ? "cmd+return" : "return") : "tab"
                flushPending(reason: submitKey)
            }
            return
        }

        // Regular character key — accumulate.
        queue.sync {
            if let started = pendingStarted {
                if Date().timeIntervalSince(started) > 2.0 {
                    flushPending(reason: "idle_timeout")
                    pendingStarted = Date()
                    pendingFocusedElement = focusedElementProvider?()
                    pendingModifiers = modifiers
                }
            } else {
                pendingStarted = Date()
                pendingFocusedElement = focusedElementProvider?()
                pendingModifiers = modifiers
            }
            pendingText.append(chars)
            resetIdleTimer()
        }
    }

    /// US QWERTY keycode → character. Returns nil for keycodes we don't recognize.
    private static func characterForKeycode(_ keycode: Int) -> String? {
        switch keycode {
        // Letters
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 31: return "o"
        case 32: return "u"
        case 34: return "i"
        case 35: return "p"
        case 37: return "l"
        case 38: return "j"
        case 40: return "k"
        case 45: return "n"
        case 46: return "m"
        // Digits
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 25: return "9"
        case 26: return "7"
        case 28: return "8"
        case 29: return "0"
        // Punctuation
        case 27: return "-"
        case 24: return "="
        case 33: return "["
        case 30: return "]"
        case 39: return "'"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 47: return "."
        case 50: return "`"
        // Special
        case 49: return "space"
        case 51: return "delete"
        case 53: return "esc"
        default: return nil
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
        DispatchQueue.main.async {
            _ = EventIngester.shared.ingest(kind: .input, sourceMonitor: "KeystrokeMonitor", payload: payload)
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
