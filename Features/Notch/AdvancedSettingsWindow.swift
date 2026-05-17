//
//  AdvancedSettingsWindow.swift
//  Agent in the Notch
//
//  Floating native NSPanel that drops down under the notch and hosts the
//  rarely-touched controls (Voice / Mic / Output) plus the API-key fields.
//  Pattern mirrors `ContextDevToolsWindowController`: a singleton @MainActor
//  controller that lazily builds an NSPanel and toggles its visibility.
//

import AppKit
import SwiftUI

@MainActor
final class AdvancedSettingsWindowController: NSObject {
    static let shared = AdvancedSettingsWindowController()

    private var panel: NSPanel?
    private var screenObserver: NSObjectProtocol?

    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 490
    static let gapBelowNotch: CGFloat = 6

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        ensurePanel()
        repositionUnderNotch()
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let rect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .nonactivatingPanel,
            .utilityWindow, .fullSizeContentView
        ]
        let p = NSPanel(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        p.title = "Advanced"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .visible
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: AdvancedSettingsView())

        panel = p

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionUnderNotch() }
        }
    }

    private func repositionUnderNotch() {
        guard let panel else { return }
        guard let host = NotchWindowController.shared.notchHostFrame() else { return }
        let originX = host.midX - Self.panelWidth / 2
        let originY = host.minY - Self.gapBelowNotch - Self.panelHeight
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
