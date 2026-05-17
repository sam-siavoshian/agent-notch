//
//  NotchLiveActivityView.swift
//  Agent in the Notch
//
//  Compact live-activity bar shown in the notch while the agent is working.
//  Sits between the closed-notch dot and the full open notch — a thin pill
//  with the cursor sprite, the frontmost app icon, and a short status line
//  (e.g. "thinking…", "typing", "clicking").
//

import AppKit
import Foundation
import SwiftUI

struct NotchLiveActivityView: View {
    @ObservedObject private var state = AgentState.shared
    @ObservedObject private var store = AgentSettingsStore.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(store.cursorColor.assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .shadow(color: store.cursorColor.swatch.opacity(0.55), radius: 3)

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(statusText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, NotchSizing.notchHeight(for: NSScreen.main) + 1)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    /// Generic activity status — never the tool name. The chip strip below
    /// owns the per-tool readout so the top row stays a clean "still working"
    /// signal.
    private var statusText: String {
        switch state.activity {
        case .thinking, .toolCall:
            return "thinking…"
        case .listening:
            return "listening…"
        case .error(let msg):
            return msg
        case .idle:
            let detail = state.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "done" : detail
        }
    }
}

/// Tracks the frontmost (non-self) app icon. Shared across notch surfaces
/// that want to badge the user's actual target app.
@MainActor
final class FrontmostAppObserver: ObservableObject {
    @Published var icon: NSImage?
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Skip ourselves so the badge reflects the user's actual target app,
        // not AgentNotch when the notch panel briefly takes focus.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        icon = app.icon
    }
}
