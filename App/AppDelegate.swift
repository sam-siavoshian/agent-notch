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
        // Force line-buffering on stdout so dev.sh's `tee` sees output live
        // instead of waiting for the 4KB block buffer to fill. Default Swift
        // behavior when stdout is a pipe (not a TTY) is fully buffered, which
        // hides errors for minutes when the app is producing only a handful
        // of log lines per second.
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
        // Critical-path: cursor + voice + session must be live before the
        // user can long-press. Cheap inits, run synchronously.
        CursorCompanion.shared.start()
        VoiceRecordingService.shared.start()
        AgentSession.shared.start()
        KillSwitch.shared.start()
        PermissionChecker.shared.startPolling()

        // Deferred: each of these blocks on IO (XPC, AppleScript, ONNX load,
        // socket bind). Off the main thread so the notch UI is interactive
        // immediately at boot.
        Task.detached(priority: .utility) {
            await MCPBridge.shared.start()
            await LaunchAtLogin.shared.reconcile()
            if await AgentSettingsStore.shared.ttsVoice.isLocal {
                await PiperTTSEngine.shared.warmup()
            }
            await SpotifyController.shared.startIfPreviouslyConnected()
        }

        log.info("boot.complete")
    }
}
