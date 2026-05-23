//
//  AgentStateView.swift
//  Agent in the Notch
//
//  Live readout in soft-pill StatusChip form.
//

import SwiftUI

struct AgentStateView: View {
    private let state = AgentState.shared

    var body: some View {
        StatusChip(
            color: SoftPill.activityHue(state.activity),
            symbol: state.activity.symbol,
            label: state.activity.label,
            detail: detailText
        )
    }

    private var detailText: String {
        if !state.detail.isEmpty { return state.detail }
        if !state.lastTranscript.isEmpty { return "\u{201C}\(state.lastTranscript)\u{201D}" }
        return "Waiting for input"
    }
}
