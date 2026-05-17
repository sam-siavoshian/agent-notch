//
//  ContextAppSwitchMonitor.swift
//  Agent in the Notch
//
//  Fires a capture whenever the user switches to a different foreground app.
//  Uses NSWorkspace notifications — no Accessibility permission required.
//

import AppKit

final class ContextAppSwitchMonitor {
    private let onSwitch: @Sendable () -> Void
    private var observer: NSObjectProtocol?

    init(onSwitch: @escaping @Sendable () -> Void) {
        self.onSwitch = onSwitch
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSwitch()
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }
}
