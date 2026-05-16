//
//  NotchWindow.swift
//  Agent in the Notch
//
//  Borderless floating NSPanel that sits just under the physical notch and
//  hosts the NotchContentView. Doesn't take focus, doesn't appear in the
//  cycle, rides across all spaces.
//
//  Reference: vendored/boring.notch/boringNotch/components/Notch/BoringNotchWindow.swift
//

import Cocoa

final class NotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        hasShadow = false
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        appearance = NSAppearance(named: .darkAqua)

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
