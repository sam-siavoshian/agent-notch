//
//  ContextDevToolsWindowController.swift
//  Agent in the Notch
//
//  Hosts context telemetry outside the notch so the user-facing surface can
//  stay focused on the agent experience.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let contextDevToolsToggleRequested = Notification.Name("AgentNotch.contextDevToolsToggleRequested")
}

@MainActor
final class ContextDevToolsWindowController: NSObject, NSWindowDelegate {
    static let shared = ContextDevToolsWindowController()

    private var window: NSWindow?
    private var shortcutMonitor: Any?
    private var localShortcutMonitor: Any?
    private var notificationObserver: NSObjectProtocol?

    func install() {
        guard shortcutMonitor == nil else { return }

        shortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isToggleShortcut(event) else { return }
            Task { @MainActor in
                ContextDevToolsWindowController.shared.toggle()
            }
        }

        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isToggleShortcut(event) else { return event }
            Task { @MainActor in
                ContextDevToolsWindowController.shared.toggle()
            }
            return nil
        }

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .contextDevToolsToggleRequested,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ContextDevToolsWindowController.shared.toggle()
            }
        }
    }

    func present() {
        let window = makeWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            present()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let rect = NSRect(x: 0, y: 0, width: 1040, height: 720)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentNotch Dev Tools"
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: ContextDebugView()
                .frame(minWidth: 860, minHeight: 560)
                .padding(16)
                .background(Color(red: 0.035, green: 0.035, blue: 0.04))
        )
        window.center()

        self.window = window
        return window
    }

    private static func isToggleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .option]
            && event.charactersIgnoringModifiers?.lowercased() == "d"
    }
}
