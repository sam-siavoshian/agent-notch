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
    private let checker = PermissionChecker()

    private init() {}

    public var allGranted: Bool { checker.allGranted }

    public func presentIfNeeded(_ onCompletion: @escaping () -> Void) {
        checker.refresh()
        guard !checker.allGranted else {
            onCompletion()
            return
        }
        present(onCompletion: onCompletion)
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
        window.styleMask = [.titled, .closable, .fullSizeContentView]
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

        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        window?.orderOut(nil)
        window = nil
        // Drop back to accessory mode so we don't sit in the Dock.
        NSApp.setActivationPolicy(.accessory)
    }
}
