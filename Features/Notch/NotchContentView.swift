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
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .spotify: return "Spotify"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .spotify: return "music.note"   // unused for spotify — rendered as brand mark
        case .settings: return "gearshape.fill"
        }
    }
}

struct NotchContentView: View {
    @AppStorage("notch.selectedTab") private var selectedTabRaw: String = NotchTab.home.rawValue
    @State private var isOpen = false
    @State private var closeTask: Task<Void, Never>?
    @State private var hoverTask: Task<Void, Never>?

    private var selectedTab: NotchTab { NotchTab(rawValue: selectedTabRaw) ?? .home }
    private var selectedTabBinding: Binding<NotchTab> {
        Binding(get: { selectedTab }, set: { selectedTabRaw = $0.rawValue })
    }

    private let closedWidth: CGFloat = 180
    private let closedHeight: CGFloat = 30

    private let openWidth: CGFloat = NotchSizing.openWidth
    /// Measured height of the open content — flows from a GeometryReader in
    /// openContent. Springs to its new value when sections expand/collapse.
    @State private var measuredOpenHeight: CGFloat = 200

    private var width: CGFloat { isOpen ? openWidth : closedWidth }
    private var height: CGFloat {
        isOpen
            ? min(max(measuredOpenHeight, 120), NotchSizing.openHeightMax)
            : closedHeight
    }
    private var cornerRadius: CGFloat { isOpen ? 22 : 10 }

    var body: some View {
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
                .opacity(isOpen ? 0 : 1)
                .allowsHitTesting(!isOpen)

            openContent
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
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
        .animation(.spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0),
                   value: isOpen)
        .animation(.spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0),
                   value: measuredOpenHeight)
        .onPreferenceChange(NotchContentHeightKey.self) { newHeight in
            // Update even while closed so the first open animates to the
            // right size in a single motion (no two-step pop).
            guard newHeight > 1,
                  abs(newHeight - measuredOpenHeight) > 0.5 else { return }
            measuredOpenHeight = newHeight
        }
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
    private var openContent: some View {
        VStack(spacing: 8) {
            NotchTabBar(selected: selectedTabBinding)
                .padding(.top, 4)
            Group {
                switch selectedTab {
                case .home:
                    NotchHomeView()
                case .spotify:
                    NotchMusicView()
                case .settings:
                    ScrollView(.vertical, showsIndicators: false) {
                        AgentSettingsView()
                            .padding(.bottom, 4)
                    }
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
                SpotifyTabMark(size: 11)
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

/// Mini Spotify glyph (green circle + 3 white arcs). Local copy so the
/// tab bar doesn't depend on NotchMusicView.
private struct SpotifyTabMark: View {
    var size: CGFloat = 11
    private let green = Color(red: 0.114, green: 0.725, blue: 0.329)
    var body: some View {
        ZStack {
            Circle().fill(green)
            GeometryReader { geo in
                let w = geo.size.width
                let lw = w * 0.13
                arc(in: geo, yOffset: -0.18, radius: 0.34, lineWidth: lw)
                arc(in: geo, yOffset: -0.04, radius: 0.27, lineWidth: lw * 0.85)
                arc(in: geo, yOffset:  0.08, radius: 0.20, lineWidth: lw * 0.72)
            }
            .padding(size * 0.12)
        }
        .frame(width: size, height: size)
    }
    private func arc(in geo: GeometryProxy, yOffset: CGFloat,
                     radius: CGFloat, lineWidth: CGFloat) -> some View {
        let w = geo.size.width, h = geo.size.height
        return Path { p in
            let c = CGPoint(x: w / 2, y: h / 2 + yOffset * h)
            p.addArc(center: c, radius: w * radius,
                     startAngle: .degrees(200), endAngle: .degrees(-20),
                     clockwise: false)
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
