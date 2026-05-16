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
            Task { @MainActor in self?.position() }
        }
    }

    private func position() {
        guard let window, let screen = NSScreen.main else { return }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.maxY - window.frame.height
        )
        window.setFrameOrigin(origin)
    }
}

@MainActor
enum NotchSizing {
    static let openWidth: CGFloat = 520
    static let openHeight: CGFloat = 380
    static let shadowPadding: CGFloat = 24

    static func windowSize(for screen: NSScreen?) -> CGSize {
        CGSize(width: openWidth, height: openHeight + shadowPadding)
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
