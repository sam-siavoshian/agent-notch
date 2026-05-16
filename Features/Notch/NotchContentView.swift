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
    @State private var selected: NotchTab = .home
    @State private var isOpen = false
    @State private var closeTask: Task<Void, Never>?
    @State private var hoverTask: Task<Void, Never>?

    private let closedWidth: CGFloat = 220
    private let closedHeight: CGFloat = 32

    // Wider while open so the context inspector can show real debug state.
    private let openWidth: CGFloat = 640
    private let openHeight: CGFloat = 430

    private var width: CGFloat { isOpen ? openWidth : closedWidth }
    private var height: CGFloat { isOpen ? openHeight : closedHeight }
    private var cornerRadius: CGFloat { isOpen ? 22 : 10 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(bottomCornerRadius: cornerRadius)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 16, y: 6)

                if isOpen {
                    openContent
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .padding(.top, NotchSizing.notchHeight(for: NSScreen.main))
                        .frame(width: openWidth, height: openHeight, alignment: .top)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            )
                        )
                } else {
                    ClosedNotchView()
                        .frame(width: closedWidth, height: closedHeight)
                        .transition(.opacity.animation(.easeOut(duration: 0.1)))
                }
            }
            .frame(width: width, height: height)
            .contentShape(NotchShape(bottomCornerRadius: cornerRadius))
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if !isOpen && value.translation.height > 20 {
                            open()
                        } else if isOpen && value.translation.height < -20 {
                            isOpen = false
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    hoverTask?.cancel()
                    closeTask?.cancel()
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        guard !Task.isCancelled else { return }
                        open()
                    }
                } else {
                    hoverTask?.cancel()
                    hoverTask = nil
                    scheduleClose()
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: isOpen)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onChange(of: isOpen) { _, _ in
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchToggleRequested)) { _ in
            if isOpen {
                isOpen = false
            } else {
                openViaShortcut()
            }
        }
    }

    @ViewBuilder
    private var openContent: some View {
        VStack(spacing: 8) {
            NotchTabBar(selected: $selected)
                .padding(.top, 4)
            Group {
                switch selected {
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
            .id(selected)
            .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func open() {
        closeTask?.cancel()
        guard !isOpen else { return }
        isOpen = true
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
            try? await Task.sleep(for: .milliseconds(350))
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
                    withAnimation(.smooth) { selected = tab }
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
