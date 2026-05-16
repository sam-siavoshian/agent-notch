//
//  AppDelegate.swift
//  Agent in the Notch
//
//  Accessory-policy app (no dock icon). Installs the notch panel at launch.
//

import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.agentnotch.app", category: "boot")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Env.load()
        NotchWindowController.shared.install()
        ContextDevToolsWindowController.shared.install()
        ContextDevToolsWindowController.shared.present()

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
        VoiceRecordingService.shared.start()
        AgentSession.shared.start()
        // Keep polling TCC state after onboarding so the Notch UI can show a
        // banner the moment a permission is revoked / not yet granted.
        PermissionChecker.shared.startPolling()
        // Spotify: user-opt-in. Resume the connection if they previously
        // tapped Connect (state persists in UserDefaults).
        SpotifyController.shared.startIfPreviouslyConnected()
        let p = PermissionChecker.shared
        log.info("boot.complete ax=\(p.statuses[.accessibility]?.rawValue ?? "?", privacy: .public) screen=\(p.statuses[.screenRecording]?.rawValue ?? "?", privacy: .public) mic=\(p.statuses[.microphone]?.rawValue ?? "?", privacy: .public)")
    }
}
