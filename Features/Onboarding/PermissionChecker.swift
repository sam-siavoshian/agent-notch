//
//  PermissionChecker.swift
//  Agent in the Notch
//
//  Polls macOS TCC state for the three permissions we need. Publishes status
//  so the onboarding UI re-renders the moment the user toggles a switch in
//  System Settings.
//

import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices

@MainActor
public final class PermissionChecker: ObservableObject {
    public enum PermissionID: String, CaseIterable, Identifiable, Sendable {
        case accessibility, screenRecording, microphone
        public var id: String { rawValue }
    }

    public enum Status: String, Sendable {
        case unknown
        case denied
        case granted
    }

    @Published public private(set) var statuses: [PermissionID: Status] = [
        .accessibility: .unknown,
        .screenRecording: .unknown,
        .microphone: .unknown
    ]

    public var allGranted: Bool {
        statuses.values.allSatisfy { $0 == .granted }
    }

    private var timer: Timer?

    public init() {
        refresh()
    }

    public func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Register on .common so the timer keeps firing during window tracking/modal modes.
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Refresh on app activation — the user usually grants in Settings then comes back.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivate),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleActivate() {
        Task { @MainActor in self.refresh() }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    public func refresh() {
        statuses = [
            .accessibility: checkAccessibility(),
            .screenRecording: checkScreenRecording(),
            .microphone: checkMicrophone()
        ]
    }

    // MARK: - Requests

    /// Triggers the system Accessibility prompt. After clicking "Open
    /// System Settings," the user toggles the switch and macOS records the
    /// grant. We pick it up on the next poll tick.
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Forces the Screen Recording prompt by attempting a capture. macOS
    /// shows the system dialog the first time this is called per app
    /// identity. After grant, app MUST be relaunched — ScreenCaptureKit
    /// caches the denial in-process otherwise.
    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func openSettings(for id: PermissionID) {
        let urlString: String
        switch id {
        case .accessibility:    urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:  urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:       urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Checks

    private func checkAccessibility() -> Status {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private func checkScreenRecording() -> Status {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private func checkMicrophone() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .unknown
        case .denied, .restricted: return .denied
        @unknown default: return .unknown
        }
    }
}
