//
//  ContextDevToolsWindowController.swift
//  Agent in the Notch
//
//  Hosts the Dev Tools panel. Cmd+Option+D toggles visibility; the window is
//  created lazily and kept around between presentations so SwiftUI state
//  persists. Floating level so it stays above the user's working windows.
//

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

    public func present() {
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func togglePresent() {
        ensureWindow()
        if let window, window.isVisible {
            dismiss()
        } else {
            present()
        }
    }

    public func dismiss() {
        window?.orderOut(nil)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let rect = NSRect(x: 0, y: 0, width: 980, height: 720)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let panel = NSPanel(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent Dev Tools"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 760, height: 520)

        let hosting = NSHostingView(rootView: ContextDebugView())
        panel.contentView = hosting
        panel.center()

        window = panel
    }

    private static func matchesToggleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let needed: NSEvent.ModifierFlags = [.command, .option]
        guard flags == needed else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        return chars == "d"
    }
}
