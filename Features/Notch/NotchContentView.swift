//
//  NotchContentView.swift
//  Agent in the Notch
//
//  Root SwiftUI view for the notch surface. Hosts the closed/open states,
//  the hover-driven animation between them, and the tab content.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let notchToggleRequested = Notification.Name("AgentNotch.notchToggleRequested")
}

/// Reports the intrinsic height of the open content so the surface can grow
/// when sections expand (Settings → Advanced, etc).
private struct NotchContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case home
    case spotify
    case calendar
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .spotify: return "Spotify"
        case .calendar: return "Calendar"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .spotify: return "music.note"   // unused for spotify — rendered as brand mark
        case .calendar: return "calendar"
        case .settings: return "gearshape.fill"
        }
    }
}

private struct NotchAnimKey: Equatable {
    let open: Bool
    let h: CGFloat
    let live: Bool
}

struct NotchContentView: View {
    /// Shared spring driving every animatable property on the notch surface.
    /// Hoisted so each body recompute reuses one instance instead of allocating
    /// three identical Animation values per render.
    private static let notchSpring: Animation =
        .spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0)

    /// Selected tab. Reads from UserDefaults once at init; writes are
    /// deferred via `.onChange` so a rapid tab-flip burst doesn't hammer the
    /// UserDefaults sync IPC on every tap.
    @State private var selectedTabRaw: String = UserDefaults.standard.string(forKey: "notch.selectedTab") ?? NotchTab.home.rawValue
    @State private var isOpen = false
    @State private var closeTask: Task<Void, Never>?
    @State private var hoverTask: Task<Void, Never>?
    private let agentState = AgentState.shared

    private var selectedTab: NotchTab { NotchTab(rawValue: selectedTabRaw) ?? .home }
    private var selectedTabBinding: Binding<NotchTab> {
        Binding(get: { selectedTab }, set: { selectedTabRaw = $0.rawValue })
    }

    private let closedWidth: CGFloat = 180
    private let closedHeight: CGFloat = 30

    private let liveWidth: CGFloat = 280
    private let liveContentHeight: CGFloat = 30
    /// Hardware notch eats the top middle of the surface — push the live
    /// content row below it so the text isn't clipped by the camera island.
    private var liveHeight: CGFloat {
        NotchSizing.notchHeight(for: NSScreen.main) + liveContentHeight
    }

    private let openWidth: CGFloat = NotchSizing.openWidth
    /// Measured height of the open content — flows from a GeometryReader in
    /// openContent. Springs to its new value when sections expand/collapse.
    @State private var measuredOpenHeight: CGFloat = 200

    /// True while the agent is actively doing work the user should see at a
    /// glance. Drives the intermediate "live activity" notch size.
    private var liveActive: Bool {
        switch agentState.activity {
        case .thinking, .toolCall: return true
        default: return false
        }
    }

    private var width: CGFloat {
        if isOpen { return openWidth }
        if liveActive { return liveWidth }
        return closedWidth
    }
    /// True when a computer-use tool is firing right now. Strip only ever
    /// shows the live action — past tool calls disappear the moment the
    /// next one starts.
    private var isToolCallLive: Bool {
        if case .toolCall = agentState.activity { return true }
        return false
    }

    /// Show the tool-only row instead of "thinking…" while a tool is firing.
    /// The two readouts are mutually exclusive — never stacked.
    private var liveStripActive: Bool { liveActive && !isOpen && isToolCallLive }

    private var height: CGFloat {
        if isOpen {
            return min(max(measuredOpenHeight, 120), NotchSizing.openHeightMax)
        }
        return liveActive ? liveHeight : closedHeight
    }
    private var cornerRadius: CGFloat {
        if isOpen { return 22 }
        return liveActive ? 16 : 10
    }

    var body: some View {
        notchBody
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
            .onChange(of: isOpen) { _, _ in
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            }
            .onReceive(NotificationCenter.default.publisher(for: .notchToggleRequested)) { _ in
                if isOpen {
                    close()
                } else {
                    openViaShortcut()
                }
            }
    }

    @ViewBuilder
    private var notchBody: some View {
        ZStack(alignment: .top) {
            // One compositing group below shape + shadow so the shadow
            // rasterizes against the shape once per frame, not separately.
            NotchShape(bottomCornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black,
                            isOpen ? SoftPill.Canvas.base : Color.black
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    NotchShape(bottomCornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(isOpen ? 0.06 : 0), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(isOpen ? 0.50 : 0), radius: 16, y: 6)
                .compositingGroup()

            // Both subviews always rendered, cross-faded by opacity. A single
            // animation curve below drives shape size + content opacity in
            // lock-step, so nothing appears before the box has grown.
            ClosedNotchView()
                .frame(width: closedWidth, height: closedHeight)
                .opacity(isOpen || liveActive ? 0 : 1)
                .allowsHitTesting(!isOpen && !liveActive)

            ZStack {
                // Thinking / listening / error states — generic text row.
                NotchLiveActivityView()
                    .opacity(liveActive && !liveStripActive ? 1 : 0)
                // Tool-call live action — replaces the thinking row entirely
                // while a computer-use tool is running.
                ToolCallStrip()
                    .opacity(liveStripActive ? 1 : 0)
            }
            .frame(width: liveWidth, height: liveHeight, alignment: .top)
            .opacity(!isOpen && liveActive ? 1 : 0)
            .allowsHitTesting(false)

            openContent
                .padding(.horizontal, 10)
                // Bottom padding ≥ bottom corner radius so rows near the
                // last line don't get clipped by the rounded notch curve.
                .padding(.bottom, 24)
                .padding(.top, NotchSizing.notchHeight(for: NSScreen.main) + 2)
                .frame(width: openWidth, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: NotchContentHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .frame(
                    width: openWidth,
                    height: min(max(measuredOpenHeight, 120), NotchSizing.openHeightMax),
                    alignment: .top
                )
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(NotchShape(bottomCornerRadius: cornerRadius))
        .contentShape(NotchShape(bottomCornerRadius: cornerRadius))
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if !isOpen && value.translation.height > 20 {
                        open()
                    } else if isOpen && value.translation.height < -20 {
                        close()
                    }
                }
        )
        .onHover { hovering in
            if hovering {
                hoverTask?.cancel()
                closeTask?.cancel()
                // 40ms tolerates cursor flicker without feeling laggy.
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else { return }
                    open()
                }
            } else {
                hoverTask?.cancel()
                hoverTask = nil
                scheduleClose()
            }
        }
        // Single spring drives box size + content opacity + height changes.
        // High damping kills bounce so top edge can't punch into the real
        // hardware notch. Response ~0.32 feels organic without feeling slow.
        // Combine the 3 trigger values into one composite key so SwiftUI
        // evaluates one .animation modifier instead of three.
        .animation(Self.notchSpring, value: NotchAnimKey(open: isOpen, h: measuredOpenHeight, live: liveActive))
        .onPreferenceChange(NotchContentHeightKey.self) { newHeight in
            // Update even while closed so the first open animates to the
            // right size in a single motion (no two-step pop).
            guard newHeight > 1,
                  abs(newHeight - measuredOpenHeight) > 0.5 else { return }
            measuredOpenHeight = newHeight
        }
        .onChange(of: selectedTabRaw) { _, new in
            UserDefaults.standard.set(new, forKey: "notch.selectedTab")
        }
    }

    @ViewBuilder
    private var openContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                NotchTabBar(selected: selectedTabBinding)
                BatteryStatusPill()
            }
            .padding(.top, 4)
            Group {
                switch selectedTab {
                case .home:
                    NotchHomeView()
                case .spotify:
                    NotchMusicView()
                case .calendar:
                    NotchCalendarView()
                        .padding(.bottom, 4)
                case .settings:
                    AgentSettingsView()
                        .padding(.bottom, 4)
                }
            }
            .id(selectedTabRaw)
            .transition(.opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func open() {
        closeTask?.cancel()
        guard !isOpen else { return }
        isOpen = true
    }

    private func close() {
        hoverTask?.cancel()
        closeTask?.cancel()
        guard isOpen else { return }
        isOpen = false
    }

    private func openViaShortcut() {
        closeTask?.cancel()
        guard !isOpen else { return }
        isOpen = true
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isOpen = false
        }
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            isOpen = false
        }
    }
}

private struct NotchTabBar: View {
    @Binding var selected: NotchTab

    var body: some View {
        PillToolbar {
            ForEach(NotchTab.allCases) { tab in
                if tab == .spotify {
                    SpotifyTabButton(isActive: selected == tab) {
                        withAnimation(.easeOut(duration: 0.14)) { selected = tab }
                    }
                } else {
                    ToolbarIconButton(
                        systemImage: tab.icon,
                        label: tab.label,
                        isActive: selected == tab
                    ) {
                        withAnimation(.easeOut(duration: 0.14)) { selected = tab }
                    }
                }
            }
        }
    }
}

/// Spotify-branded tab — green mark + "Spotify" label. Matches the active
/// pill chrome of `ToolbarIconButton` so it lines up cleanly in the toolbar.
private struct SpotifyTabButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                SpotifyMark(size: 11)
                Text("Spotify")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isActive ? SoftPill.Text.primary : SoftPill.Text.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 20)
            .background(
                Group {
                    if isActive {
                        Capsule(style: .continuous).fill(SoftPill.Surface.inset)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Battery status pill (macOS menubar-style glyph)

private struct BatteryStatusPill: View {
    @ObservedObject private var battery = BatteryService.shared
    @State private var hovered = false

    var body: some View {
        if battery.hasBattery {
            content
        }
    }

    private var color: Color {
        if battery.isCharging       { return SoftPill.Status.green }
        if battery.percentage <= 20 { return SoftPill.Status.red }
        if battery.percentage <= 50 { return SoftPill.Status.amber }
        return SoftPill.Status.green
    }

    private var glyph: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percentage {
        case ...10: return "battery.0percent"
        case ...30: return "battery.25percent"
        case ...60: return "battery.50percent"
        case ...85: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(color, SoftPill.Text.secondary)
                .shadow(color: color.opacity(0.55), radius: hovered ? 5 : 0)

            if hovered {
                Text("\(battery.percentage)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(PillBackground(fill: AnyShapeStyle(SoftPill.Surface.base)))
        .help("Battery \(battery.percentage)%\(battery.isCharging ? " · Charging" : "")")
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

