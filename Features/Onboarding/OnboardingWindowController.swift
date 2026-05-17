//
//  OnboardingWindowController.swift
//  Agent in the Notch
//
//  Plain NSWindow (not a panel) because the user needs to interact with it
//  normally. Centered, non-resizable, no minimize. Held in memory until
//  dismissed.
//

import AppKit
import SwiftUI

@MainActor
public final class OnboardingWindowController {
    public static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private let checker = PermissionChecker.shared
    private var windowDelegate: CloseDelegate?

    private init() {}

    public var allGranted: Bool { checker.allGranted }

    private let skipKey = "AgentNotch.onboardingDismissed"

    public func presentIfNeeded(_ onCompletion: @escaping () -> Void) {
        let forced = ProcessInfo.processInfo.environment["AGENTNOTCH_FORCE_ONBOARDING"] == "1"
        if forced {
            UserDefaults.standard.removeObject(forKey: skipKey)
            present(onCompletion: onCompletion)
            return
        }
        checker.refresh()
        if checker.allGranted {
            onCompletion()
            return
        }
        // Cold-start race: AXIsProcessTrusted / CGPreflightScreenCaptureAccess
        // can return stale false on the very first call after launch even
        // when TCC has the grant. Re-check after a short delay before
        // bothering the user.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            self.checker.refresh()
            if self.checker.allGranted {
                onCompletion()
                return
            }
            // User already saw + dismissed onboarding once → don't block them
            // again on subsequent launches even if our TCC check still reads
            // false (the agent itself will fail loudly if perms are truly
            // missing). They can re-trigger onboarding from the notch menu.
            if UserDefaults.standard.bool(forKey: self.skipKey) {
                onCompletion()
                return
            }
            self.present(onCompletion: onCompletion)
        }
    }

    public func present(onCompletion: @escaping () -> Void) {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(checker: checker) { [weak self] in
            self?.dismiss()
            onCompletion()
        }
        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.contentMinSize = NSSize(width: 560, height: 560)
        window.contentMaxSize = NSSize(width: 900, height: 880)
        window.setContentSize(NSSize(width: 760, height: 760))
        window.title = "Agent in the Notch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary]

        let delegate = CloseDelegate { [weak self] in
            self?.dismiss()
            onCompletion()
        }
        window.delegate = delegate
        self.windowDelegate = delegate

        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        UserDefaults.standard.set(true, forKey: skipKey)
        window?.orderOut(nil)
        window = nil
        windowDelegate = nil
        // Drop back to accessory mode so we don't sit in the Dock.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Manually re-show onboarding (e.g. from a debug menu).
    public func resetAndShow(_ onCompletion: @escaping () -> Void = {}) {
        UserDefaults.standard.removeObject(forKey: skipKey)
        present(onCompletion: onCompletion)
    }
}

private final class CloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    private var fired = false
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        guard !fired else { return }
        fired = true
        onClose()
    }
}
