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
    /// Panel is bigger than the sprite so the listening halo + thinking ring
    /// don't clip. Must match the outer frame of CursorCompanionView.
    private let panelSize: CGFloat = 40

    /// Where the sprite center sits relative to the user's real cursor tip
    /// (screen coords, AppKit: +x right, +y up). Tuned so the companion sits
    /// just to the right and slightly below the cursor, like a buddy.
    private let spriteOffsetFromCursor = CGPoint(x: 14, y: -8)

    private let panel: NSPanel
    private let hostingView: NSHostingView<CursorCompanionView>

    init(viewModel: CursorCompanionViewModel) {
        let view = CursorCompanionView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: panelSize, height: panelSize)

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

    /// `point` = user's real cursor tip in global screen space (AppKit
    /// origin = bottom-left of the primary screen). Positions the panel so
    /// the sprite *center* lands at cursor + spriteOffsetFromCursor.
    func reposition(toCursorTip point: NSPoint) {
        let center = CGPoint(
            x: point.x + spriteOffsetFromCursor.x,
            y: point.y + spriteOffsetFromCursor.y
        )
        let origin = CGPoint(x: center.x - panelSize / 2, y: center.y - panelSize / 2)
        panel.setFrameOrigin(origin)
    }
}
