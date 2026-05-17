//
//  AppDelegate.swift
//  Agent in the Notch
//
//  Accessory-policy app (no dock icon). Installs the notch panel at launch.
//

import AppKit
import SwiftUI

private let log = Log(category: "boot")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Env.load()
        NotchWindowController.shared.install()

        OnboardingWindowController.shared.presentIfNeeded { [weak self] in
            self?.bootAgent()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func bootAgent() {
        CursorCompanion.shared.start()
        ContextCoordinator.shared.start()
        ContextDevToolsWindowController.shared.install()
        VoiceRecordingService.shared.start()
        AgentSession.shared.start()
        KillSwitch.shared.start()
        // Phase 2 adapters — register so L2Snapshotter can populate `app_specific` for known apps.
        AdapterRegistry.shared.register(BrowserAdapter())
        AdapterRegistry.shared.register(TerminalAdapter())
        AdapterRegistry.shared.register(IDEAdapter())
        log.info("Registered \(AdapterRegistry.shared.allRegistered().count) app-specific adapter instance(s)")
        // Phase 1 monitors — passively collect events into EventLog via
        // EventIngester. Start order matters: KeystrokeMonitor wants
        // AXObserverManager's focused-element provider, so AXObserverManager
        // comes first.
        AXObserverManager.shared.start()
        let keystrokeOK = KeystrokeMonitor.shared.start()
        if !keystrokeOK {
            log.warning("keystroke.start denied — Input Monitoring TCC not granted; running degraded")
        }
        ClipboardWatcher.shared.start()
        DwellTimer.shared.start()
        // Phase 3 — sequence inference + rolling active_task synthesis.
        // AnchorRecorder is pure-local (no Mercury inside its tick), so it
        // always runs. ActiveTaskUpdater calls OpenRouter each tick, so we
        // gate it behind the mercuryEnabled setting to avoid surprise spend.
        AnchorRecorder.shared.start()
        if AgentSettingsStore.shared.mercuryEnabled {
            ActiveTaskUpdater.shared.start()
        } else {
            log.info("ActiveTaskUpdater disabled by settings (mercuryEnabled=false)")
        }
        // Keep polling TCC state after onboarding so the Notch UI can show a
        // banner the moment a permission is revoked / not yet granted.
        let p = PermissionChecker.shared
        p.startPolling()
        // Spotify: user-opt-in. Resume the connection if they previously
        // tapped Connect (state persists in UserDefaults).
        SpotifyController.shared.startIfPreviouslyConnected()
        log.info("boot.complete ax=\(p.statuses[.accessibility]?.rawValue ?? "?") screen=\(p.statuses[.screenRecording]?.rawValue ?? "?") mic=\(p.statuses[.microphone]?.rawValue ?? "?")")
    }
}
