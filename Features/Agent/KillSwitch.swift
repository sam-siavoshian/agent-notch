//
//  KillSwitch.swift
//
//  Global panic-button hotkey. 1st press: soft-stop harness + cancel session
//  task. 2nd press within 2s: SIGKILL self.
//

import AppKit
import Combine
import Darwin
import Foundation

private let log = Log(category: "killswitch")

@MainActor
public final class KillSwitch {
    public static let shared = KillSwitch()

    private static let escalationWindow: TimeInterval = 2.0

    private var monitor: Any?
    private var lastSoftStopAt: Date?
    private var cancellable: AnyCancellable?

    private init() {}

    public func start() {
        guard monitor == nil else { return }
        installMonitor()
        // Re-install on shortcut change so the captured keyCode/modifiers
        // reflect the latest setting (dropFirst skips the initial publication).
        cancellable = AgentSettingsStore.shared.$settings
            .map(\.killSwitchShortcut)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.reinstall() }
            }
        log.info("killswitch.start shortcut=\(AgentSettingsStore.shared.killSwitchShortcut.displayString)")
    }

    private func reinstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        installMonitor()
        log.info("killswitch.reinstall shortcut=\(AgentSettingsStore.shared.killSwitchShortcut.displayString)")
    }

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        let s = AgentSettingsStore.shared.settings.killSwitchShortcut
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        guard event.keyCode == s.keyCode, mods == s.modifiers else { return }

        let now = Date()
        if let last = lastSoftStopAt, now.timeIntervalSince(last) <= Self.escalationWindow {
            hardKill()
        } else {
            softStop()
            lastSoftStopAt = now
        }
    }

    private func softStop() {
        ComputerUseHarness.shared.requestStop()
        AgentSession.shared.cancelCurrentRun()
        AgentState.shared.set(.idle, detail: "Stopped — press again within 2s to force quit")
        log.warning("killswitch.soft_stop")
    }

    private func hardKill() -> Never {
        log.error("killswitch.sigkill pid=\(getpid())")
        Darwin.kill(getpid(), SIGKILL)
        exit(137) // SIGKILL is uncatchable; unreachable, satisfies `Never`.
    }
}
