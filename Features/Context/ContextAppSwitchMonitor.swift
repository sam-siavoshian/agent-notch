//
//  ContextAppSwitchMonitor.swift
//  Agent in the Notch
//
//  Fires a capture whenever the user switches to a different foreground app.
//  Uses NSWorkspace notifications — no Accessibility permission required.
//

import AppKit

final class ContextAppSwitchMonitor {
    private let onSwitch: @Sendable (String) -> Void
    private var observer: NSObjectProtocol?

    init(onSwitch: @escaping @Sendable (String) -> Void) {
        self.onSwitch = onSwitch
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let appName = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .localizedName ?? "Unknown"
            self?.onSwitch(appName)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }
}
