//
//  AgentTabView.swift
//  Agent in the Notch
//
//  The Agent tab inside the opened notch: live state on top, settings below.
//

import SwiftUI

struct AgentTabView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentStateView()
            ScrollView(.vertical, showsIndicators: false) {
                AgentSettingsView()
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
