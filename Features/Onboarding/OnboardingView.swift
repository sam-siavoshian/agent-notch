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

import Darwin
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

/// White-pill background. Three states with distinct visual language:
/// - rest: inset highlight (top) + inset floor (bottom), 2-layer outer shadow
/// - hover: ADD ring, ADD tinted glow, scale up, brighten — light leaks in
/// - pressed: FLIP insets (dark top, bright bottom rim), kill glow + ambient,
///            scale DOWN. Reads as a real button punched into the canvas.
private struct SoftPillBg: ViewModifier {
    var fill: Color = Pill.surface
    var radius: CGFloat = 999
    var hovered: Bool = false
    var pressed: Bool = false
    var glow: Color = Color(red: 1.0, green: 0.71, blue: 0.55)
    var glowIntensity: Double = 0.35

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(fill))
            // Inset edges only when pressed. REST/HOVER: no border ring.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.18),
                            .clear,
                            Color.white.opacity(0.55)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
                .opacity(pressed ? 1 : 0)
            )
            // Outer shadows. Hover lifts via deeper ambient + tinted glow.
            .shadow(color: pressed ? Color.black.opacity(0.10) : Pill.shadowContact,
                    radius: 1, x: 0, y: 1)
            .shadow(color: pressed
                        ? .clear
                        : (hovered ? Pill.shadowHover : Pill.shadowAmbient),
                    radius: hovered ? 14 : 12,
                    x: 0, y: hovered ? 9 : 8)
            .shadow(color: glow.opacity((hovered && !pressed) ? glowIntensity * 0.5 : 0),
                    radius: 14, x: 0, y: 0)
            .scaleEffect(pressed ? 0.98 : (hovered ? 1.005 : 1.0))
            .brightness(pressed ? -0.04 : (hovered ? 0.015 : 0))
            .saturation(pressed ? 0.98 : (hovered ? 1.02 : 1.0))
            .animation(pressed
                        ? .easeOut(duration: 0.08)
                        : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.18),
                       value: pressed)
            .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.18), value: hovered)
    }
}

private extension View {
    func softPill(fill: Color = Pill.surface,
                  radius: CGFloat = 999,
                  hovered: Bool = false,
                  pressed: Bool = false,
                  glow: Color = Color(red: 1.0, green: 0.71, blue: 0.55),
                  glowIntensity: Double = 0.35) -> some View {
        modifier(SoftPillBg(fill: fill, radius: radius,
                            hovered: hovered, pressed: pressed,
                            glow: glow, glowIntensity: glowIntensity))
    }
}

/// Real-button press: scales DOWN below rest, brightens DOWN, fast ease-out.
/// Inset/shadow inversion lives in SoftPillBg — this style is for buttons
/// whose label is the whole tap target (no backing pill on its own).
private struct PressSpringStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(configuration.isPressed
                        ? .easeOut(duration: 0.08)
                        : .spring(response: 0.28, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

/// Button style that wraps its label in a SoftPillBg and pipes press state
/// straight into it — so the inset flips, glow dies, and scale drops in one
/// place. Pass `hovered` from the caller's @State.
private struct OnbSoftPillButtonStyle: ButtonStyle {
    var hovered: Bool = false
    var fill: Color = Pill.surface
    var radius: CGFloat = 999
    var glow: Color = Color(red: 1.0, green: 0.71, blue: 0.55)
    var glowIntensity: Double = 0.35

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .softPill(fill: fill, radius: radius,
                      hovered: hovered, pressed: configuration.isPressed,
                      glow: glow, glowIntensity: glowIntensity)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var checker: PermissionChecker
    let onContinue: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var pendingRelaunch = false
    @State private var activateObserver: NSObjectProtocol?

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
        .frame(minWidth: 560, idealWidth: 760, maxWidth: 900,
               minHeight: 560, idealHeight: 760)
        .onAppear {
            checker.startPolling()
            pulseScale = 2.4
            // When user comes back from Settings after granting AX/SR, the
            // in-process TCC cache is stale. Auto-relaunch to flush it.
            activateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                guard pendingRelaunch else { return }
                let stillDenied =
                    checker.statuses[.accessibility] != .granted ||
                    checker.statuses[.screenRecording] != .granted
                if stillDenied {
                    pendingRelaunch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        relaunch()
                    }
                } else {
                    pendingRelaunch = false
                }
            }
        }
        .onDisappear {
            checker.stopPolling()
            if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            DraggableAppIcon(pulse: grantedCount < 4)
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text("Four quick permissions")
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
            Text("/ 4")
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
                icon: .accessibility,
                title: "Accessibility",
                blurb: "Read long-press, click and type on your behalf.",
                status: checker.statuses[.accessibility] ?? .unknown,
                onGrant: {
                    checker.requestAccessibility()
                    checker.openSettings(for: .accessibility)
                    pendingRelaunch = true
                },
                onSettings: { checker.openSettings(for: .accessibility) }
            )
            PermPill(
                icon: .monitor,
                title: "Screen Recording",
                blurb: "See recent screen activity for context. Needs a relaunch after grant.",
                status: checker.statuses[.screenRecording] ?? .unknown,
                onGrant: {
                    checker.requestScreenRecording()
                    checker.openSettings(for: .screenRecording)
                    pendingRelaunch = true
                },
                onSettings: { checker.openSettings(for: .screenRecording) }
            )
            PermPill(
                icon: .mic,
                title: "Microphone",
                blurb: "Hold the cursor to talk, release to send.",
                status: checker.statuses[.microphone] ?? .unknown,
                onGrant: { checker.requestMicrophone() },
                onSettings: { checker.openSettings(for: .microphone) }
            )
            PermPill(
                icon: .keyboard,
                title: "Input Monitoring",
                blurb: "Lets AgentNotch observe the keystrokes you make so it can learn the shortcuts you actually use.",
                status: checker.statuses[.inputMonitoring] ?? .unknown,
                onGrant: {
                    checker.requestInputMonitoring()
                    checker.openSettings(for: .inputMonitoring)
                },
                onSettings: { checker.openSettings(for: .inputMonitoring) }
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
            ghostPill(label: "Relaunch", icon: .rotateCW, dashed: false, action: relaunch)
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

    private func ghostPill(label: String, icon: LucideName? = nil, dashed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    LucideIcon(name: icon, size: 13, lineWidth: 2, animate: false)
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
            fputs("[ERROR] [onboarding] relaunch helper spawn failed: \(error)\n", Darwin.stderr)
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
                LucideIcon(name: .sparkles, size: 14, lineWidth: 2, animate: true)
                    .foregroundStyle(.white)
                Text(allGranted ? "Continue" : "Continue anyway")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .buttonStyle(CTAStyle(hover: hover))
        .keyboardShortcut(.defaultAction)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.25)) { hover = h }
        }
        .help(allGranted ? "Open the agent" : "Continue without full grants")
    }
}

/// Continue CTA visual. Three states:
/// - rest: pink→orange gradient, glassy top inset, warm bottom inset, soft bloom
/// - hover: brightness up, gradient flips diagonal, bloom 2x, white halo ring
/// - pressed: scale 0.97, FLIP insets (dark warm top, white bottom rim),
///            kill bloom + ambient — looks pressed into the canvas
private struct CTAStyle: ButtonStyle {
    let hover: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .background(
                LinearGradient(
                    colors: [Pill.ctaFrom, Pill.ctaTo],
                    startPoint: hover ? .topTrailing : .topLeading,
                    endPoint: hover ? .bottomLeading : .bottomTrailing
                )
            )
            // Inset edge: only when pressed (warm top + bright bottom rim).
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.16, blue: 0.31).opacity(0.40),
                            .clear,
                            .white.opacity(0.30)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
                .opacity(pressed ? 1 : 0)
            )
            .clipShape(Capsule())
            // Contact shadow always; ambient + bloom only when not pressed.
            .shadow(color: Pill.ctaShadow1, radius: 2, x: 0, y: 1)
            .shadow(color: pressed ? .clear : Pill.ctaShadow2,
                    radius: hover ? 24 : 20,
                    x: 0, y: hover ? 10 : 9)
            .shadow(color: pressed ? .clear : Pill.ctaFrom.opacity(hover ? 0.38 : 0.30),
                    radius: hover ? 22 : 18, x: 0, y: 0)
            .scaleEffect(pressed ? 0.98 : (hover ? 1.01 : 1.0))
            .brightness(pressed ? -0.05 : (hover ? 0.025 : 0))
            .saturation(pressed ? 0.95 : (hover ? 1.03 : 1.0))
            .animation(pressed
                        ? .easeOut(duration: 0.08)
                        : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.18),
                       value: pressed)
    }
}

// MARK: - Permission pill row

private struct PermPill: View {
    let icon: LucideName
    let title: String
    let blurb: String
    let status: PermissionChecker.Status
    let onGrant: () -> Void
    let onSettings: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PermStatusBadge(status: status)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    LucideIcon(name: icon, size: 14, lineWidth: 2, animate: hover)
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
        .softPill(radius: 22, hovered: hover, glow: glowColor, glowIntensity: 0.45)
        .animation(.easeInOut(duration: 0.2), value: status)
        .onHover { h in hover = h }
    }

    private var glowColor: Color {
        switch status {
        case .granted: Pill.green
        case .denied:  Pill.red
        case .unknown: Pill.amber
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        if status == .granted {
            HStack(spacing: 6) {
                LucideIcon(name: .check, size: 12, lineWidth: 2.5, trigger: status)
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Pill.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Pill.green.opacity(0.14)))
            .transition(.scale.combined(with: .opacity))
        } else {
            GrantButton(action: onGrant)
        }

        SettingsCogButton(action: onSettings)
            .help("Open in System Settings")
    }
}

// MARK: - Grant button (own hover so it pops independently of the row)

private struct GrantButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text("Grant")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Pill.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        .buttonStyle(OnbSoftPillButtonStyle(
            hovered: hover,
            fill: Pill.hoverFill,
            glow: Pill.ctaFrom,
            glowIntensity: 0.18
        ))
        .onHover { h in hover = h }
    }
}

// MARK: - Animated status badge

private struct PermStatusBadge: View {
    let status: PermissionChecker.Status

    var body: some View {
        ZStack {
            Circle().fill(fill)
            LucideIcon(name: lucideName,
                       size: 14,
                       lineWidth: 2.4,
                       animate: status == .unknown,
                       trigger: status)
                .foregroundStyle(.white)
        }
    }

    private var fill: Color {
        switch status {
        case .granted: Pill.green
        case .denied:  Pill.red
        case .unknown: Pill.amber
        }
    }

    private var lucideName: LucideName {
        switch status {
        case .granted: .check
        case .denied:  .xmark
        case .unknown: .info
        }
    }
}

// MARK: - Settings cog button (own hover state so the cog spins on hover)

private struct SettingsCogButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            LucideIcon(name: .settings, size: 16, lineWidth: 2, animate: hover)
                .foregroundStyle(Pill.muted)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(OnbSoftPillButtonStyle(
            hovered: hover,
            fill: Pill.hoverFill,
            radius: 16,
            glow: Pill.gray,
            glowIntensity: 0.20
        ))
        .onHover { h in hover = h }
    }
}

// MARK: - Draggable app icon (animated marching-ants outline while pending)

private struct DraggableAppIcon: View {
    let pulse: Bool
    @State private var hover = false

    var body: some View {
        AppIconImage()
            .shadow(color: .black.opacity(hover ? 0.22 : 0.18),
                    radius: hover ? 11 : 10,
                    x: 0, y: hover ? 7 : 6)
            .scaleEffect(hover ? 1.015 : 1.0)
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
