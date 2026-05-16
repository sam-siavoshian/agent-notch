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

enum NotchTab: String, CaseIterable, Identifiable {
    case home
    case settings
    case context

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .settings: return "Settings"
        case .context: return "Context"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .settings: return "gearshape.fill"
        case .context: return "eye"
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

    private let closedWidth: CGFloat = 220
    private let closedHeight: CGFloat = 32

    // Compact open size — fits home/settings/context cleanly without
    // overhanging the menu bar.
    private let openWidth: CGFloat = 420
    private let openHeight: CGFloat = 280

    private var width: CGFloat { isOpen ? openWidth : closedWidth }
    private var height: CGFloat { isOpen ? openHeight : closedHeight }
    private var cornerRadius: CGFloat { isOpen ? 22 : 10 }

    var body: some View {
        ZStack(alignment: .top) {
            // One compositing group below shape + shadow so the shadow
            // rasterizes against the shape once per frame, not separately.
            NotchShape(bottomCornerRadius: cornerRadius)
                .fill(Color.black)
                .shadow(color: .black.opacity(isOpen ? 0.40 : 0), radius: 12, y: 5)
                .compositingGroup()

            if isOpen {
                openContent
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .padding(.top, NotchSizing.notchHeight(for: NSScreen.main))
                    .frame(width: openWidth, height: openHeight, alignment: .top)
                    // Insertion: opacity + tiny scale from the notch edge.
                    // Removal: pure opacity (fastest possible exit).
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.985, anchor: .top))
                                .animation(.easeOut(duration: 0.14)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))
                        )
                    )
            } else {
                ClosedNotchView()
                    .frame(width: closedWidth, height: closedHeight)
                    .transition(.opacity.animation(.easeOut(duration: 0.07)))
            }
        }
        .frame(width: width, height: height, alignment: .top)
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
        // interactiveSpring is interruptible — fast cursor in/out won't queue
        // up stale animations. Damping kept high so the top edge cannot
        // overshoot into the real notch cutout.
        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.90, blendDuration: 0),
                   value: isOpen)
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
                case .settings:
                    ScrollView(.vertical, showsIndicators: false) {
                        AgentSettingsView()
                            .padding(.bottom, 4)
                    }
                case .context:
                    ContextDebugView()
                }
            }
            .id(selectedTabRaw)
            .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
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
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NotchTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selected = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.label)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected == tab ? .white : .white.opacity(0.45))
                    .contentShape(Capsule())
                    .background {
                        if selected == tab {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(id: "tab-bg", in: animation)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(Capsule())
    }
}
