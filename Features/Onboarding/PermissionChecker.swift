//
//  PermissionChecker.swift
//  Agent in the Notch
//
//  Polls macOS TCC state for the four permissions we need and publishes
//  status so the UI re-renders the moment the user toggles a switch in
//  System Settings.
//

import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices

@MainActor
public final class PermissionChecker: ObservableObject {
    public static let shared = PermissionChecker()

    public enum PermissionID: String, CaseIterable, Sendable {
        case accessibility, screenRecording, microphone, inputMonitoring

        public var label: String {
            switch self {
            case .accessibility:    return "Accessibility"
            case .screenRecording:  return "Screen Recording"
            case .microphone:       return "Microphone"
            case .inputMonitoring:  return "Input Monitoring"
            }
        }
    }

    public enum Status: String, Sendable {
        case unknown
        case denied
        case granted
    }

    @Published public private(set) var statuses: [PermissionID: Status] = [
        .accessibility: .unknown,
        .screenRecording: .unknown,
        .microphone: .unknown,
        .inputMonitoring: .unknown
    ]

    public var allGranted: Bool {
        statuses.values.allSatisfy { $0 == .granted }
    }

    /// IDs that are not currently granted, in stable display order.
    public var missing: [PermissionID] {
        PermissionID.allCases.filter { statuses[$0] != .granted }
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
            .microphone: checkMicrophone(),
            .inputMonitoring: checkInputMonitoring()
        ]
    }

    // MARK: - Requests

    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Forces the Screen Recording prompt. After grant, the app MUST be
    /// relaunched — ScreenCaptureKit caches the denial in-process otherwise.
    public func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Separate TCC grant from Accessibility on macOS 14+ — required for
    /// CGEvent taps that observe keystrokes.
    public func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    public func openSettings(for id: PermissionID) {
        let urlString: String
        switch id {
        case .accessibility:    urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:  urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:       urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .inputMonitoring:  urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
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

    private func checkInputMonitoring() -> Status {
        CGPreflightListenEventAccess() ? .granted : .denied
    }
}
