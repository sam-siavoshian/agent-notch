//
//  CursorCompanionWindow.swift
//  Agent in the Notch
//
//  Borderless transparent panel that floats above every app on every Space.
//  Hosts the SwiftUI cursor sprite OR glow. Does NOT eat clicks
//  (ignoresMouseEvents). Panel size + offset switch with `setMode(_:)` so the
//  companion sprite sits beside the real pointer while the glow centers on it.
//

import AppKit
import SwiftUI

@MainActor
final class CursorCompanionWindow {
    /// Panel dimensions for each cursor mode. Companion stays compact since
    /// the dot + listening ring only need ~50pt of canvas. Glow needs a wider
    /// stage so the radial fade can taper to zero without a hard clip edge.
    private static let companionPanelSize: CGFloat = 50
    private static let glowPanelSize: CGFloat = 140

    /// Where the sprite center sits relative to the user's real cursor tip
    /// (AppKit screen coords: +x right, +y up). Companion offsets clear the
    /// system arrow body; glow centers directly under the cursor.
    private static let companionOffset = CGPoint(x: 28, y: -16)
    private static let glowOffset = CGPoint(x: 0, y: 0)

    private let panel: NSPanel
    private let hostingView: NSHostingView<CursorCompanionView>

    private var panelSize: CGFloat
    private var spriteOffsetFromCursor: CGPoint
    private var halfPanelSize: CGFloat { panelSize / 2 }

    init(viewModel: CursorCompanionViewModel) {
        let initialMode = viewModel.mode
        let size = initialMode == .glow ? Self.glowPanelSize : Self.companionPanelSize
        let offset = initialMode == .glow ? Self.glowOffset : Self.companionOffset

        let view = CursorCompanionView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(x: 0, y: 0, width: size, height: size)

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
        self.panelSize = size
        self.spriteOffsetFromCursor = offset
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Reconfigure panel geometry for a different cursor mode. Resize the
    /// hosting view first so the next layout pass already has the right
    /// dimensions before AppKit redraws the panel chrome, then snap the
    /// position so the new center lands at the current cursor.
    func setMode(_ mode: CursorMode) {
        let newSize = mode == .glow ? Self.glowPanelSize : Self.companionPanelSize
        let newOffset = mode == .glow ? Self.glowOffset : Self.companionOffset
        guard newSize != panelSize || newOffset != spriteOffsetFromCursor else { return }

        panelSize = newSize
        spriteOffsetFromCursor = newOffset

        let frame = CGRect(x: 0, y: 0, width: newSize, height: newSize)
        hostingView.frame = frame
        panel.setContentSize(frame.size)
        reposition(toCursorTip: NSEvent.mouseLocation)
    }

    /// `point` = user's real cursor tip in global screen space (AppKit
    /// origin = bottom-left of the primary screen). Positions the panel so
    /// the sprite *center* lands at cursor + spriteOffsetFromCursor.
    func reposition(toCursorTip point: NSPoint) {
        let center = CGPoint(
            x: point.x + spriteOffsetFromCursor.x,
            y: point.y + spriteOffsetFromCursor.y
        )
        let origin = CGPoint(x: center.x - halfPanelSize, y: center.y - halfPanelSize)
        panel.setFrameOrigin(origin)
    }

    /// Center the sprite at `point` directly. Bypasses the user-cursor offset
    /// so the agent driver can place the sprite exactly on its click target
    /// rather than 28pt off to the side. AppKit screen space (bottom-left).
    func setSpriteCenter(_ point: NSPoint) {
        let origin = CGPoint(x: point.x - halfPanelSize, y: point.y - halfPanelSize)
        panel.setFrameOrigin(origin)
    }
}
