//
//  KillSwitch.swift
//  Agent in the Notch
//
//  Global panic-button hotkey. Two-stage escalation:
//    1. First press → soft-stop: ComputerUseHarness.requestStop() +
//       AgentSession.cancelCurrentRun() (the latter cancels the wrapping
//       Task, which propagates CancellationError to in-flight URLSession
//       requests so Anthropic calls bail without finishing).
//    2. Second press within 2s → Darwin.kill(getpid(), SIGKILL). Bypasses
//       NSApp.terminate / applicationShouldTerminate — true binary kill.
//
//  Uses NSEvent.addGlobalMonitorForEvents (same precedent as Cmd+D in
//  NotchWindowController) so the shortcut fires while another app has
//  focus — exactly when a panic button is most useful.
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
        // Re-install whenever the user records a new shortcut so the captured
        // keyCode/modifiers reflect the latest setting. removeDuplicates skips
        // re-installs when unrelated settings change; dropFirst skips the
        // initial publication (we already installed eagerly above).
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
        // SIGKILL is uncatchable; this line is unreachable in practice but
        // satisfies the `Never` return type if the signal is somehow blocked.
        exit(137)
    }
}
