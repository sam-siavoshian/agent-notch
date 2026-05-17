//
//  NotchHomeView.swift
//  Agent in the Notch
//
//  Home tab in compact soft-pill form. Surfaces an inline Grant button
//  when the agent reports a missing TCC permission, with a built-in
//  "open Settings → return → relaunch" flow so the user never has to
//  restart the app manually.
//

import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

struct NotchHomeView: View {
    @ObservedObject private var state = AgentState.shared
    @ObservedObject private var store = AgentSettingsStore.shared
    @ObservedObject private var permissions = PermissionChecker.shared

    private var isActive: Bool {
        switch state.activity {
        case .idle, .error: return false
        case .listening, .thinking, .toolCall: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !permissions.missing.isEmpty {
                permissionBanner
            }
            statusHero
            if !state.lastTranscript.isEmpty {
                lastRequestCard
            }
            if !state.activityLog.isEmpty {
                activityFeed
            } else if !isActive && state.lastTranscript.isEmpty {
                emptyState
            }
        }
    }

    private var permissionBanner: some View {
        let missing = permissions.missing
        let primary = missing.first
        let count = missing.count
        return HStack(spacing: 8) {
            StatusBadge(color: SoftPill.Status.amber, symbol: "exclamationmark.triangle.fill", size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(count == 1
                     ? "\(primary?.label ?? "Permission") not granted"
                     : "\(count) permissions missing")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SoftPill.Status.amber)
                Text("Drag the icon into Settings, or tap Grant")
                    .font(.system(size: 9))
                    .foregroundStyle(SoftPill.Text.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            DraggableAgentIcon(size: 24)
                .help("Drag onto the Privacy list in System Settings")
            if let primary {
                GrantPermissionButton(target: pickTarget(primary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.inset),
                glow: SoftPill.Status.amber,
                cornerRadius: 10
            )
        )
    }

    /// Map a PermissionChecker id onto the local nested PermissionTarget.
    /// String-based to avoid coupling the home view to the checker enum.
    private func pickTarget(_ id: PermissionChecker.PermissionID) -> PermissionTarget {
        switch String(describing: id).lowercased() {
        case let s where s.contains("screen"): return .screenRecording
        case let s where s.contains("mic"):    return .microphone
        default:                                return .accessibility
        }
    }

    private var statusHero: some View {
        HStack(spacing: 8) {
            StatusBadge(
                color: SoftPill.activityHue(state.activity),
                symbol: state.activity.symbol,
                size: 20
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(state.activity.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SoftPill.activityHue(state.activity))
                    .animation(nil, value: state.activity.label)
                Group {
                    if !state.detail.isEmpty {
                        Text(state.detail).foregroundStyle(SoftPill.Text.secondary)
                    } else {
                        Text(isActive ? "Working on it…" : "Ready when you are")
                            .foregroundStyle(SoftPill.Text.muted)
                    }
                }
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // Skip the inline Grant when the amber banner above already
            // owns the permission fix flow — avoids two competing CTAs.
            if let fix = missingPermission, permissions.missing.isEmpty {
                DraggableAgentIcon(size: 26)
                    .help("Drag onto the privacy list in System Settings to add AgentNotch")
                GrantPermissionButton(target: fix)
            }
            QuitIconButton()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.base),
                glow: SoftPill.activityHue(state.activity),
                cornerRadius: 11
            )
        )
    }

    /// Returns the permission pane to open when the status text reports a
    /// missing TCC grant. Detected from `state.activity == .error(...)` +
    /// keyword match on the message. Returns nil for unrelated errors.
    private var missingPermission: PermissionTarget? {
        guard case .error = state.activity else { return nil }
        let combined = (state.activity.label + " " + state.detail).lowercased()
        if combined.contains("accessibility") { return .accessibility }
        if combined.contains("screen recording") || combined.contains("screen capture") {
            return .screenRecording
        }
        if combined.contains("microphone") || combined.contains("mic ") {
            return .microphone
        }
        return nil
    }

    private var lastRequestCard: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 9))
                .foregroundStyle(SoftPill.Text.muted)
                .padding(.top, 1)
            Text(state.lastTranscript)
                .font(.system(size: 10.5))
                .foregroundStyle(SoftPill.Text.primary.opacity(0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.inset),
                cornerRadius: 9
            )
        )
    }

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("RECENT")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(SoftPill.Text.muted)
                .padding(.leading, 4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(state.activityLog) { entry in
                        ActivityLogRow(entry: entry)
                    }
                }
            }
            .frame(maxHeight: 110)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if AgentInterfaces.cursor == nil {
                StatusBadge(color: SoftPill.Status.amber, symbol: "exclamationmark", size: 22)
                Text("Cursor companion not connected")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.secondary)
            } else {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(store.cursorColor.swatch.opacity(0.8))
                Text("Long-press cursor to start")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SoftPill.Text.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // MARK: - Permission target (nested so it's namespaced to home)

    fileprivate enum PermissionTarget {
        case accessibility, screenRecording, microphone

        var settingsURL: URL {
            let base = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
            switch self {
            case .accessibility:   return URL(string: base + "Accessibility")!
            case .screenRecording: return URL(string: base + "ScreenCapture")!
            case .microphone:      return URL(string: base + "Microphone")!
            }
        }

        /// Live trust check. Only `.accessibility` has a synchronous,
        /// no-prompt API; for the others we assume granted once the user
        /// returns from Settings.
        var isNowGranted: Bool {
            switch self {
            case .accessibility: return AXIsProcessTrusted()
            case .screenRecording, .microphone: return true
            }
        }
    }
}

// MARK: - Quit icon button
//
// Tiny power glyph that terminates AgentNotch. Lives in the status hero so
// it is one click away without diving into Settings. Hover tints red to
// signal destructive intent; press scales down for tactile feedback.

private struct QuitIconButton: View {
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hover ? SoftPill.Status.red : SoftPill.Text.muted)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(
                        hover ? SoftPill.Status.red.opacity(0.14) : SoftPill.Surface.inset
                    )
                )
                .overlay(
                    Circle().stroke(
                        hover ? SoftPill.Status.red.opacity(0.40) : Color.clear,
                        lineWidth: 0.6
                    )
                )
                .scaleEffect(pressed ? 0.90 : (hover ? 1.05 : 1.0))
        }
        .buttonStyle(PressTrackingStyle(pressed: $pressed))
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .help("Quit Agent in the Notch")
    }
}

// MARK: - Activity feed row

private struct ActivityLogRow: View {
    let entry: AgentLogEntry

    var body: some View {
        HStack(spacing: 6) {
            StatusBadge(
                color: SoftPill.activityHue(entry.activity),
                symbol: entry.activity.symbol,
                size: 12
            )
            Text(rowLabel)
                .font(.system(size: 10))
                .foregroundStyle(SoftPill.Text.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(entry.timestamp, style: .relative)
                .font(.system(size: 8.5))
                .foregroundStyle(SoftPill.Text.muted)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.inset),
                cornerRadius: 8
            )
        )
    }

    private var rowLabel: String {
        entry.detail.isEmpty ? entry.activity.label : entry.detail
    }
}

// MARK: - Inline Grant button
//
// First tap: opens System Settings → Privacy & Security at the right pane
// + arms a one-shot observer. When the user returns to AgentNotch and the
// grant has actually flipped, label morphs into "Relaunch". Second tap
// execs a fresh process (required — macOS caches the TCC trust answer per
// process, so an in-place reload won't pick up the change).

private struct GrantPermissionButton: View {
    let target: NotchHomeView.PermissionTarget
    @State private var hover = false
    @State private var pressed = false
    @State private var armed = false
    @State private var activateObserver: NSObjectProtocol?

    private static let gradientStart = Color(red: 0.953, green: 0.478, blue: 0.478)
    private static let gradientEnd   = Color(red: 1.0,   green: 0.62,  blue: 0.42)
    private static let glow          = Color(red: 1.0,   green: 0.55,  blue: 0.50)

    var body: some View {
        Button {
            if armed {
                AppRelaunch.relaunch()
            } else {
                NSWorkspace.shared.open(target.settingsURL)
                armRelaunchOnReturn()
            }
        } label: {
            Text(armed ? "Relaunch" : "Grant")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Self.gradientStart, Self.gradientEnd],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: pressed
                                ? [Color.black.opacity(0.30), .clear, Color.white.opacity(0.30)]
                                : [Color.white.opacity(hover ? 0.50 : 0.35),
                                   .clear,
                                   Color.black.opacity(0.18)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                )
                .shadow(
                    color: pressed ? .clear : Self.glow.opacity(hover ? 0.55 : 0.35),
                    radius: hover ? 12 : 6, y: hover ? 4 : 2
                )
                .scaleEffect(pressed ? 0.95 : (hover ? 1.04 : 1.0))
                .brightness(pressed ? -0.05 : (hover ? 0.05 : 0))
        }
        .buttonStyle(PressTrackingStyle(pressed: $pressed))
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
        .help(armed
              ? "Permission granted — relaunch to take effect"
              : "Open System Settings → Privacy & Security")
        .onDisappear {
            if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        }
    }

    private func armRelaunchOnReturn() {
        guard activateObserver == nil else { return }
        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Assume the user did what we sent them to do. We can't trust
            // AXIsProcessTrusted() at this moment — it's cached per-process
            // and stays `false` until a fresh exec, which is the entire
            // reason we're asking them to relaunch. Show "Relaunch" on
            // return; if they actually didn't grant, the second tap still
            // does the right thing (restart → error reappears → loop).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.easeOut(duration: 0.18)) { armed = true }
            }
        }
    }
}

// MARK: - Draggable app icon
//
// Real Finder-style drag source. Drag this onto System Settings →
// Privacy & Security → (Accessibility | Screen Recording | Microphone)
// and macOS adds AgentNotch to the list, exactly like a Finder drag.

private struct DraggableAgentIcon: View {
    var size: CGFloat = 26
    @State private var hover = false

    /// True when the bundle has a real app icon. The default Xcode template
    /// icon is a blank/placeholder rendering — fall back to a custom badge
    /// so the drag target reads as "this app" instead of "blank square".
    /// Bundle info dict never changes at runtime, so cache once.
    private static let hasRealIcon: Bool =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil
            || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
    private var hasRealIcon: Bool { Self.hasRealIcon }

    private var iconImage: NSImage? {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
    }

    @ViewBuilder
    private var icon: some View {
        if hasRealIcon, let img = iconImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            AgentNotchBadge()
        }
    }

    var body: some View {
        icon
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .shadow(color: .black.opacity(hover ? 0.40 : 0.22),
                    radius: hover ? 6 : 3, y: hover ? 3 : 1)
            .scaleEffect(hover ? 1.06 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hover)
            .onHover { h in hover = h }
            .onDrag {
                let url = Bundle.main.bundleURL as NSURL
                let provider = NSItemProvider(object: url)
                provider.suggestedName = Bundle.main.bundleURL.lastPathComponent
                return provider
            } preview: {
                icon.frame(width: 80, height: 80)
            }
    }
}

/// Drawn fallback: black rounded square with a tiny notch silhouette in
/// the top-center. Matches the product — looks like the menu-bar notch.
private struct AgentNotchBadge: View {
    private static let statusGreen = Color(red: 0.133, green: 0.773, blue: 0.369)
    private static let bgTop       = Color(red: 0.15, green: 0.16, blue: 0.20)
    private static let bgBottom    = Color(red: 0.05, green: 0.06, blue: 0.09)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Self.bgTop, Self.bgBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                // Inset top highlight
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), .clear],
                            startPoint: .top, endPoint: .center
                        ),
                        lineWidth: 0.7
                    )
                // Notch dent at top center
                Capsule()
                    .fill(Color.black)
                    .frame(width: s * 0.45, height: s * 0.16)
                    .offset(y: -s * 0.30)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            .frame(width: s * 0.45, height: s * 0.16)
                            .offset(y: -s * 0.30)
                    )
                // Tiny green status dot under the notch
                Circle()
                    .fill(Self.statusGreen)
                    .frame(width: s * 0.13, height: s * 0.13)
                    .offset(y: s * 0.05)
                    .shadow(color: Self.statusGreen.opacity(0.6),
                            radius: s * 0.10)
            }
        }
    }
}

/// Tiny ButtonStyle that exposes isPressed via a binding so the label can
/// reflect press state in its own visual chrome (instead of fighting the
/// default ButtonStyle scaling).
private struct PressTrackingStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, new in
                withAnimation(new
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.25, dampingFraction: 0.7)) {
                    pressed = new
                }
            }
    }
}
