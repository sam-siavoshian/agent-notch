import AppKit
import SwiftUI

@MainActor
public final class ContextDevToolsWindowController: NSObject {
    public static let shared = ContextDevToolsWindowController()

    private var window: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    public func install() {
        ensureWindow()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesToggleShortcut(event) else { return event }
            Task { @MainActor in self?.togglePresent() }
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesToggleShortcut(event) else { return }
            Task { @MainActor in self?.togglePresent() }
        }
    }

    private func togglePresent() {
        ensureWindow()
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let rect = NSRect(x: 0, y: 0, width: 980, height: 720)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Dev Tools"
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("AgentDevToolsWindow")

        let hosting = NSHostingView(rootView: ContextDebugView())
        window.contentView = hosting
        window.center()

        self.window = window
    }

    private static func matchesToggleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let needed: NSEvent.ModifierFlags = [.command, .shift]
        guard flags == needed else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        return chars == "i"
    }
}
