//
//  LaunchAtLogin.swift
//  Agent in the Notch
//
//  Wraps `SMAppService.mainApp` so the user can opt the app into macOS's
//  Login Items list with a single toggle. Available macOS 13+. The actual
//  Login Item entry shows up in System Settings → General → Login Items
//  under the app's name; the user can also revoke it from there.
//

import Foundation
import ServiceManagement

private let log = Log(category: "launchAtLogin")

@MainActor
public final class LaunchAtLogin {
    public static let shared = LaunchAtLogin()

    private init() {}

    /// True when the app is currently registered as a login item.
    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister based on the new value. No-op when already in
    /// the requested state. Errors are logged but never thrown — the toggle
    /// in settings UI tolerates failure (e.g. user denied the prompt) by
    /// keeping the stored bool but skipping the SMAppService call later.
    public func apply(enabled: Bool) {
        let svc = SMAppService.mainApp
        do {
            switch (enabled, svc.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                return
            case (true, _):
                try svc.register()
                log.info("launch.register status=\(svc.status.rawValue)")
            case (false, _):
                try svc.unregister()
                log.info("launch.unregister status=\(svc.status.rawValue)")
            }
        } catch {
            log.error("launch.apply_failed enabled=\(enabled) error=\(error)")
        }
    }

    /// Called at boot — reconciles the stored setting with the actual
    /// `SMAppService` status so a manually-revoked Login Item flips the
    /// stored bool back to false (and vice versa for a manually-added one).
    public func reconcile() {
        let actual = isEnabled
        let stored = AgentSettingsStore.shared.launchAtLogin
        if actual != stored {
            log.info("launch.reconcile drift=actual:\(actual) stored:\(stored)")
            AgentSettingsStore.shared.update { $0.launchAtLogin = actual }
        }
    }
}
