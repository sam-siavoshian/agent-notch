//
//  AppDelegate.swift
//  Agent in the Notch
//
//  Accessory-policy app (no dock icon). Installs the notch panel at launch.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        seedSecrets()
        NotchWindowController.shared.install()

        OnboardingWindowController.shared.presentIfNeeded { [weak self] in
            self?.bootAgent()
        }
    }

    private func seedSecrets() {
        // One-shot Keychain seed for hackathon bring-up. Safe to call every launch
        // — only writes if the slot is currently empty. Rotate via Secrets.setOpenAIAPIKey.
        Secrets.bootstrapOpenAIKey("REDACTED-OPENAI-KEY")
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
    }
}
