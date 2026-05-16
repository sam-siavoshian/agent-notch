//
//  OnboardingView.swift
//  Agent in the Notch
//
//  Soft-pill UI. Responsive (480-760pt), interactive (hover lift, press
//  spring, animated SF Symbols), warm two-layer shadows, gradient CTA.
//
//  Lucide animated icons are web-only. macOS equivalent: SF Symbols with
//  .symbolEffect — .pulse (continuous), .bounce (on transition),
//  .variableColor.iterative (loading shimmer). All native, all 60fps.
//
//  The app icon is still a real Finder-style drag source.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Design tokens

private enum Pill {
    static let canvas       = Color(red: 0.929, green: 0.933, blue: 0.941)
    static let surface      = Color.white
    static let text         = Color(red: 0.227, green: 0.227, blue: 0.227)
    static let muted        = Color(red: 0.612, green: 0.627, blue: 0.659)
    static let hoverFill    = Color(red: 0.957, green: 0.961, blue: 0.969)

    static let ctaFrom      = Color(red: 1.000, green: 0.478, blue: 0.713)
    static let ctaTo        = Color(red: 1.000, green: 0.702, blue: 0.420)

    static let amber        = Color(red: 0.961, green: 0.725, blue: 0.278)
    static let green        = Color(red: 0.490, green: 0.831, blue: 0.604)
    static let red          = Color(red: 0.953, green: 0.478, blue: 0.478)
    static let gray         = Color(red: 0.710, green: 0.722, blue: 0.749)
    static let onlineDot    = Color(red: 0.133, green: 0.773, blue: 0.369)

    static let shadowContact = Color.black.opacity(0.06)
    static let shadowAmbient = Color.black.opacity(0.08)
    static let shadowHover   = Color.black.opacity(0.12)
    static let ctaShadow1    = Color(red: 1.0, green: 0.47, blue: 0.62).opacity(0.30)
    static let ctaShadow2    = Color(red: 1.0, green: 0.59, blue: 0.47).opacity(0.40)
}

// MARK: - Shared modifiers / styles

private struct SoftPillBg: ViewModifier {
    var fill: Color = Pill.surface
    var radius: CGFloat = 999
    var elevated: Bool = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .shadow(color: Pill.shadowContact, radius: 1, x: 0, y: 1)
            .shadow(color: elevated ? Pill.shadowHover : Pill.shadowAmbient,
                    radius: elevated ? 18 : 12,
                    x: 0, y: elevated ? 12 : 8)
    }
}

private extension View {
    func softPill(fill: Color = Pill.surface, radius: CGFloat = 999, elevated: Bool = false) -> some View {
        modifier(SoftPillBg(fill: fill, radius: radius, elevated: elevated))
    }
}

private struct PressSpringStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var checker: PermissionChecker
    let onContinue: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    private var allGranted: Bool { checker.allGranted }
    private var grantedCount: Int {
        checker.statuses.values.filter { $0 == .granted }.count
    }
    private var needsRelaunch: Bool {
        // Screen Recording grants take effect only after a relaunch.
        checker.statuses[.screenRecording] == .granted
    }

    var body: some View {
        ZStack {
            Pill.canvas.ignoresSafeArea()

            VStack(spacing: 22) {
                header
                permissionRows
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(minWidth: 480, idealWidth: 620, maxWidth: 760,
               minHeight: 460, idealHeight: 520)
        .onAppear {
            checker.startPolling()
            pulseScale = 2.4
        }
        .onDisappear { checker.stopPolling() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            DraggableAppIcon(pulse: grantedCount < 3)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text("Three quick permissions")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Pill.text)

                Text("Drag the icon into System Settings, or tap Grant.")
                    .font(.system(size: 13))
                    .foregroundStyle(Pill.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            progressChip
        }
    }

    private var progressChip: some View {
        HStack(spacing: 6) {
            Text("\(grantedCount)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(allGranted ? Pill.green : Pill.text)
                .contentTransition(.numericText(value: Double(grantedCount)))
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: grantedCount)
            Text("/ 3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pill.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .softPill()
    }

    // MARK: Permission rows

    private var permissionRows: some View {
        VStack(spacing: 12) {
            PermPill(
                icon: "hand.tap.fill",
                title: "Accessibility",
                blurb: "Read long-press, click and type on your behalf.",
                status: checker.statuses[.accessibility] ?? .unknown,
                onGrant: {
                    checker.requestAccessibility()
                    checker.openSettings(for: .accessibility)
                },
                onSettings: { checker.openSettings(for: .accessibility) }
            )
            PermPill(
                icon: "rectangle.on.rectangle",
                title: "Screen Recording",
                blurb: "See recent screen activity for context. Needs a relaunch after grant.",
                status: checker.statuses[.screenRecording] ?? .unknown,
                onGrant: {
                    checker.requestScreenRecording()
                    checker.openSettings(for: .screenRecording)
                },
                onSettings: { checker.openSettings(for: .screenRecording) }
            )
            PermPill(
                icon: "mic.fill",
                title: "Microphone",
                blurb: "Hold the cursor to talk, release to send.",
                status: checker.statuses[.microphone] ?? .unknown,
                onGrant: { checker.requestMicrophone() },
                onSettings: { checker.openSettings(for: .microphone) }
            )
        }
    }

    // MARK: Footer — responsive (wraps to two rows on narrow widths)

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { footerControls }
            VStack(spacing: 10) {
                HStack { statusDotPill; Spacer() }
                HStack(spacing: 10) {
                    Spacer()
                    secondaryButtons
                    continueButton
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: allGranted)
        .animation(.easeInOut(duration: 0.2), value: needsRelaunch)
    }

    @ViewBuilder
    private var footerControls: some View {
        statusDotPill
        Spacer(minLength: 8)
        secondaryButtons
        continueButton
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        if !allGranted {
            ghostPill(label: "Skip", dashed: true, action: onContinue)
                .help("Skip setup — you can grant later from settings")
        }
        if needsRelaunch {
            ghostPill(label: "Relaunch", icon: "arrow.clockwise", dashed: false, action: relaunch)
                .help("Restart so new grants take effect")
        }
    }

    private var continueButton: some View {
        ContinueCTA(allGranted: allGranted, action: onContinue)
    }

    private var statusDotPill: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(allGranted ? Pill.onlineDot : Pill.amber)
                    .frame(width: 8, height: 8)
                if !allGranted {
                    Circle()
                        .stroke(Pill.amber.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulseScale)
                        .opacity(2 - pulseScale)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false),
                                   value: pulseScale)
                }
            }
            Text(allGranted ? "Ready" : "Waiting")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pill.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .softPill()
    }

    private func ghostPill(label: String, icon: String? = nil, dashed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Pill.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .strokeBorder(
                        Pill.gray,
                        style: dashed
                            ? StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                            : StrokeStyle(lineWidth: 1.5)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressSpringStyle())
    }

    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        // Helper waits until our PID actually exits before spawning a fresh
        // instance. Without the wait, LaunchServices dedupes against the
        // dying process and `open -n` silently no-ops.
        let cmd = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done
        /usr/bin/open -n '\(escaped)'
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run()
        } catch {
            NSLog("[Onboarding] relaunch helper spawn failed: \(error)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
        }
    }
}

// MARK: - Continue CTA

private struct ContinueCTA: View {
    let allGranted: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.variableColor.iterative.reversing,
                                  options: .repeating)
                Text(allGranted ? "Continue" : "Continue anyway")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [Pill.ctaFrom, Pill.ctaTo],
                    startPoint: hover ? .topTrailing : .topLeading,
                    endPoint: hover ? .bottomLeading : .bottomTrailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: Pill.ctaShadow1, radius: 2, x: 0, y: 1)
            .shadow(color: Pill.ctaShadow2,
                    radius: hover ? 22 : 16,
                    x: 0, y: hover ? 12 : 9)
            .scaleEffect(hover ? 1.03 : 1.0)
        }
        .buttonStyle(PressSpringStyle())
        .keyboardShortcut(.defaultAction)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.25)) { hover = h }
        }
        .help(allGranted ? "Open the agent" : "Continue without full grants")
    }
}

// MARK: - Permission pill row

private struct PermPill: View {
    let icon: String
    let title: String
    let blurb: String
    let status: PermissionChecker.Status
    let onGrant: () -> Void
    let onSettings: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusBadge(status: status)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Pill.muted)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Pill.text)
                }
                Text(blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(Pill.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            actionArea
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .softPill(radius: 22, elevated: hover)
        .scaleEffect(hover ? 1.005 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: status)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
        .onHover { h in hover = h }
    }

    @ViewBuilder
    private var actionArea: some View {
        if status == .granted {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Pill.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Pill.green.opacity(0.14)))
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: onGrant) {
                Text("Grant")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Pill.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Pill.hoverFill))
            }
            .buttonStyle(PressSpringStyle())
        }

        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pill.muted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Pill.hoverFill))
        }
        .buttonStyle(PressSpringStyle())
        .help("Open in System Settings")
    }
}

// MARK: - Animated status badge

private struct StatusBadge: View {
    let status: PermissionChecker.Status

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: status == .granted)
                .symbolEffect(.pulse,
                              options: .repeating,
                              isActive: status == .unknown)
        }
    }

    private var fill: Color {
        switch status {
        case .granted: Pill.green
        case .denied:  Pill.red
        case .unknown: Pill.amber
        }
    }

    private var symbol: String {
        switch status {
        case .granted: "checkmark"
        case .denied:  "xmark"
        case .unknown: "info"
        }
    }
}

// MARK: - Draggable app icon (animated marching-ants outline while pending)

private struct DraggableAppIcon: View {
    let pulse: Bool
    @State private var hover = false

    var body: some View {
        AppIconImage()
            .shadow(color: .black.opacity(hover ? 0.28 : 0.18),
                    radius: hover ? 14 : 10,
                    x: 0, y: hover ? 9 : 6)
            .scaleEffect(hover ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
            .onHover { h in hover = h }
        .onDrag {
            let url = Bundle.main.bundleURL as NSURL
            let provider = NSItemProvider(object: url)
            provider.suggestedName = Bundle.main.bundleURL.lastPathComponent
            return provider
        } preview: {
            AppIconImage().frame(width: 96, height: 96)
        }
        .help("Drag onto Privacy & Security in System Settings")
    }
}

private struct AppIconImage: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.image = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        v.imageScaling = .scaleProportionallyUpOrDown
        v.unregisterDraggedTypes()
        return v
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}
