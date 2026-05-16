//
//  CursorCompanionWindow.swift
//  Agent in the Notch
//
//  Borderless transparent panel that floats above every app on every Space.
//  Hosts the SwiftUI cursor sprite. Does NOT eat clicks (ignoresMouseEvents).
//

import AppKit
import SwiftUI

@MainActor
final class CursorCompanionWindow {
    private let panel: NSPanel
    private let hostingView: NSHostingView<CursorCompanionView>
    private let spriteSize: CGFloat = 36

    init(viewModel: CursorCompanionViewModel) {
        let view = CursorCompanionView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: spriteSize, height: spriteSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// `point` is a top-of-cursor coordinate in global screen space (AppKit
    /// origin = bottom-left of the primary screen). We offset so the sprite
    /// sits just below-right of the actual cursor tip.
    func reposition(toCursorTip point: NSPoint) {
        let offset = CGPoint(x: 14, y: -spriteSize)
        let origin = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        panel.setFrameOrigin(origin)
    }
}
