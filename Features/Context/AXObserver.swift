import Foundation
import AppKit
import ApplicationServices

/// Per-PID AX observer lifecycle. Tracks the frontmost app via NSWorkspace notifications,
/// (re)creates an AXObserver each time it changes, and forwards focused-element changes
/// + value/selection/menu events.
///
/// Listens for:
///   kAXFocusedUIElementChangedNotification
///   kAXValueChangedNotification
///   kAXSelectedTextChangedNotification
///   kAXMenuItemSelectedNotification
///
/// Falls back to focused-element polling at 1Hz when the frontmost app doesn't support
/// kAXFocusedUIElementChangedNotification.
public final class AXObserverManager {

    public static let shared = AXObserverManager()

    private var currentObserver: AXObserver?
    private var currentPID: pid_t?
    private var currentAppElement: AXUIElement?
    private var pollTimer: Timer?

    // Cached focused-element descriptor for KeystrokeMonitor's tagging.
    public private(set) var focusedElementDescriptor: String?

    private init() {}

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleAppActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Bootstrap from current frontmost.
        if let app = NSWorkspace.shared.frontmostApplication {
            attachObserver(pid: app.processIdentifier)
        }
        // Wire KeystrokeMonitor's focused-element provider to us.
        KeystrokeMonitor.shared.focusedElementProvider = { [weak self] in self?.focusedElementDescriptor }
    }

    public func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detachObserver()
    }

    @objc private func handleAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        // App-switch event
        let from = currentPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let to = app.bundleIdentifier ?? "<unknown>"
        DispatchQueue.main.async {
            _ = EventIngester.shared.ingest(
                kind: .appSwitch,
                sourceMonitor: "AXObserverManager",
                payload: .appSwitch(fromBundle: from, toBundle: to)
            )
        }
        attachObserver(pid: pid)
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == currentPID {
            detachObserver()
        }
    }

    private func attachObserver(pid: pid_t) {
        detachObserver()
        currentPID = pid
        currentAppElement = AXUIElementCreateApplication(pid)

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let observer else {
            // Couldn't attach (likely missing AX permission for this PID). Fall back to polling.
            startPolling()
            return
        }
        currentObserver = observer

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [String] = [
            kAXFocusedUIElementChangedNotification as String,
            kAXValueChangedNotification as String,
            kAXSelectedTextChangedNotification as String,
            kAXMenuItemSelectedNotification as String
        ]
        for note in notifications {
            _ = AXObserverAddNotification(observer, currentAppElement!, note as CFString, userData)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        // Always start a slow poll alongside in case notifications are missed.
        startPolling()
        // And refresh once now.
        refreshFocusedElement()
    }

    private func detachObserver() {
        if let observer = currentObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        currentObserver = nil
        currentAppElement = nil
        currentPID = nil
        focusedElementDescriptor = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshFocusedElement()
        }
    }

    fileprivate func refreshFocusedElement() {
        guard let app = currentAppElement else { return }
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard err == .success, let element = value, CFGetTypeID(element) == AXUIElementGetTypeID() else {
            focusedElementDescriptor = nil
            return
        }
        let ax = element as! AXUIElement
        focusedElementDescriptor = describe(element: ax)
    }

    fileprivate func handleAXNotification(_ notification: String, element: AXUIElement) {
        // Update focused-element snapshot when focus or value changes
        switch notification {
        case kAXFocusedUIElementChangedNotification as String:
            focusedElementDescriptor = describe(element: element)
        case kAXMenuItemSelectedNotification as String:
            let label = (copyStringAttr(element, kAXTitleAttribute) ?? "<menu>")
            // No deep menu path here; menu items expose only their immediate title via AX.
            DispatchQueue.main.async {
                _ = EventIngester.shared.ingest(
                    kind: .click,
                    sourceMonitor: "AXObserverManager",
                    payload: .click(elementLabel: label, axRole: "AXMenuItem", modifiers: [])
                )
            }
        default:
            break
        }
    }

    private func describe(element: AXUIElement) -> String {
        let role = copyStringAttr(element, kAXRoleAttribute) ?? "AXUnknown"
        let label = copyStringAttr(element, kAXTitleAttribute)
            ?? copyStringAttr(element, kAXDescriptionAttribute)
            ?? copyStringAttr(element, kAXValueAttribute)
        if let label, !label.isEmpty {
            return "\(role)[\(label)]"
        }
        return role
    }

    private func copyStringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

// MARK: - C callback bridging

private func axCallback(observer: AXObserver, element: AXUIElement, notification: CFString, userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let manager = Unmanaged<AXObserverManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleAXNotification(notification as String, element: element)
}
