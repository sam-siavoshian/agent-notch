//
//  AppDelegate.swift
//  Agent in the Notch
//
//  Accessory-policy app (no dock icon). Installs the notch panel at launch.
//

import AppKit

private let log = Log(category: "boot")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Line-buffer stdout so dev.sh's `tee` sees output live (default is
        // fully-buffered when stdout is a pipe, hiding errors for minutes).
        setvbuf(stdout, nil, _IOLBF, 0)

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
        AdapterRegistry.shared.register(BrowserAdapter())
        AdapterRegistry.shared.register(TerminalAdapter())
        AdapterRegistry.shared.register(IDEAdapter())
        log.info("Registered \(AdapterRegistry.shared.allRegistered().count) app-specific adapter instance(s)")
        // KeystrokeMonitor depends on AXObserverManager's focused-element provider — order matters.
        AXObserverManager.shared.start()
        let keystrokeOK = KeystrokeMonitor.shared.start()
        if !keystrokeOK {
            log.warning("keystroke.start denied — Input Monitoring TCC not granted; running degraded")
        }
        ClipboardWatcher.shared.start()
        DwellTimer.shared.start()
        AnchorRecorder.shared.start()
        // ActiveTaskUpdater calls OpenRouter each tick; gate to avoid surprise spend.
        if AgentSettingsStore.shared.mercuryEnabled {
            ActiveTaskUpdater.shared.start()
        } else {
            log.info("ActiveTaskUpdater disabled by settings (mercuryEnabled=false)")
        }
        let p = PermissionChecker.shared
        p.startPolling()
        SpotifyController.shared.startIfPreviouslyConnected()
        log.info("boot.complete ax=\(p.statuses[.accessibility]?.rawValue ?? "?") screen=\(p.statuses[.screenRecording]?.rawValue ?? "?") mic=\(p.statuses[.microphone]?.rawValue ?? "?")")
    }
}
