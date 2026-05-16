//
//  NotchContentView.swift
//  Agent in the Notch
//
//  Root view for the open notch surface. Tabs along the top, content below.
//

import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home
    case agent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .agent: return "Agent"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .agent: return "sparkles"
        }
    }
}

struct NotchContentView: View {
    @State private var selected: NotchTab = .agent

    var body: some View {
        VStack(spacing: 8) {
            NotchTabBar(selected: $selected)
            Group {
                switch selected {
                case .home:
                    NotchHomePlaceholder()
                case .agent:
                    AgentTabView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.black)
        .preferredColorScheme(.dark)
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
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
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
                .help(tab.label)
            }
        }
        .clipShape(Capsule())
    }
}

private struct NotchHomePlaceholder: View {
    var body: some View {
        Text("Home")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, minHeight: 100)
    }
}

struct AgentTabView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentStateView()
            ScrollView(.vertical, showsIndicators: false) {
                AgentSettingsView()
                    .padding(.bottom, 4)
            }
        }
    }
}
