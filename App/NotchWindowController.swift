//
//  NotchWindowController.swift
//  Agent in the Notch
//
//  Owns the NotchWindow lifecycle: creates it at launch, sizes it for the
//  current screen's notch, repositions on screen-config changes.
//

import AppKit
import SwiftUI

@MainActor
final class NotchWindowController: NSObject {
    static let shared = NotchWindowController()

    private var window: NotchWindow?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var followTimer: DispatchSourceTimer?
    private var lastScreen: NSScreen?
    private var cmdDMonitor: Any?

    /// Bottom-anchor point of the notch host window in screen coordinates.
    /// Used by satellite panels (e.g. `AdvancedSettingsWindowController`) to
    /// drop down under the notch.
    func notchHostFrame() -> NSRect? {
        window?.frame
    }

    func install() {
        guard window == nil else { return }

        let size = NotchSizing.windowSize(for: NSScreen.main)
        let rect = NSRect(origin: .zero, size: size)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = NotchWindow(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: NotchContentView())
        window = panel

        position()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.position(animated: true) }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.position(animated: true) }
        }

        startFollowingActiveScreen()

        cmdDMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "d" else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .notchToggleRequested, object: nil)
            }
        }
    }

    private func position(animated: Bool = false) {
        guard let window, let screen = preferredScreen() else { return }
        let frame = screen.frame
        let size = window.frame.size
        let target = NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let screenChanged = (lastScreen != screen)
        lastScreen = screen

        if animated && screenChanged {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true)
        }
    }

    /// Pick the screen the user is currently on. Prefer the screen with a
    /// real notch (auxiliaryTopLeftArea). Fall back to the screen under the
    /// cursor, then main.
    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screenUnderCursor = screens.first { NSPointInRect(mouse, $0.frame) }
        if let s = screenUnderCursor, s.auxiliaryTopLeftArea != nil { return s }
        if let s = screenUnderCursor { return s }
        if let notched = screens.first(where: { $0.auxiliaryTopLeftArea != nil }) {
            return notched
        }
        return NSScreen.main
    }

    /// Re-check active screen at ~10Hz so the notch slides to whatever
    /// display the cursor is on. Cheap: a timer + an origin check.
    private func startFollowingActiveScreen() {
        followTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(100),
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let target = self.preferredScreen()
            if target != self.lastScreen {
                self.position(animated: true)
            }
        }
        followTimer = timer
        timer.resume()
    }
}

@MainActor
enum NotchSizing {
    static let openWidth: CGFloat = 460
    /// Upper bound on open height; the visible frame is content-driven
    /// (see NotchContentView). The window pre-allocates the maximum so the
    /// inner SwiftUI can grow without resizing the NSWindow.
    static let openHeightMax: CGFloat = 640
    static let openHeight: CGFloat = openHeightMax  // legacy alias
    static let shadowPadding: CGFloat = 24

    static func windowSize(for screen: NSScreen?) -> CGSize {
        CGSize(width: openWidth + shadowPadding * 2,
               height: openHeightMax + shadowPadding)
    }

    static func notchHeight(for screen: NSScreen?) -> CGFloat {
        let inset = screen?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : 32
    }

    static func notchWidth(for screen: NSScreen?) -> CGFloat {
        if let aux = screen?.auxiliaryTopLeftArea {
            let rightEdge = (screen?.frame.width ?? 0) - (screen?.auxiliaryTopRightArea?.width ?? aux.width)
            let leftEdge = aux.width
            let computed = rightEdge - leftEdge
            if computed > 100 { return computed }
        }
        return 220
    }
}
