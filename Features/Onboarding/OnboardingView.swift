//
//  OnboardingView.swift
//  Agent in the Notch
//
//  Three permission cards. Status updates live as the user toggles switches
//  in System Settings — no manual refresh.
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var checker: PermissionChecker
    let onContinue: () -> Void

    private var allGranted: Bool { checker.allGranted }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 14) {
                PermissionCard(
                    icon: "hand.tap.fill",
                    title: "Accessibility",
                    subtitle: "Lets the companion read your long-press gesture and lets the agent click and type on your behalf.",
                    status: checker.statuses[.accessibility] ?? .unknown,
                    primaryAction: { checker.requestAccessibility() },
                    settingsAction: { checker.openSettings(for: .accessibility) }
                )

                PermissionCard(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    subtitle: "Lets the agent see your screen — what you've been doing — so it can act with context.",
                    status: checker.statuses[.screenRecording] ?? .unknown,
                    primaryAction: { checker.requestScreenRecording() },
                    settingsAction: { checker.openSettings(for: .screenRecording) },
                    requiresRelaunch: true
                )

                PermissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "Lets you talk to the agent. Long-press to start speaking, release to send.",
                    status: checker.statuses[.microphone] ?? .unknown,
                    primaryAction: { checker.requestMicrophone() },
                    settingsAction: { checker.openSettings(for: .microphone) }
                )
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)

            Divider().opacity(0.4)

            footer
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .onAppear { checker.startPolling() }
        .onDisappear { checker.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Almost ready")
                    .font(.title2.weight(.semibold))
            }
            Text("Agent in the Notch needs three permissions to do its thing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            if !allGranted {
                Label("Watching for changes…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Label("All set", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Spacer()
            Button(action: onContinue) {
                Text(allGranted ? "Continue" : "Skip for now")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(allGranted ? .accentColor : .secondary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let status: PermissionChecker.Status
    let primaryAction: () -> Void
    let settingsAction: () -> Void
    var requiresRelaunch: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status == .granted && requiresRelaunch {
                    Label("Restart the app after granting", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    Button(action: primaryAction) {
                        Text(status == .granted ? "Re-prompt" : "Grant access")
                    }
                    .controlSize(.small)
                    .disabled(status == .granted)

                    Button(action: settingsAction) {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var borderColor: Color {
        switch status {
        case .granted: return .green.opacity(0.45)
        case .denied:  return .red.opacity(0.25)
        case .unknown: return .secondary.opacity(0.18)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusFill.opacity(0.18))
            Image(systemName: statusSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusFill)
                .symbolEffect(.bounce, value: status == .granted)
        }
    }

    private var statusFill: Color {
        switch status {
        case .granted: return .green
        case .denied:  return .red
        case .unknown: return .secondary
        }
    }

    private var statusSymbol: String {
        switch status {
        case .granted: return "checkmark"
        case .denied:  return "xmark"
        case .unknown: return "questionmark"
        }
    }
}
