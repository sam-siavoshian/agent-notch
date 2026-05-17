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
    @StateObject private var frontmost = FrontmostAppObserver()

    var body: some View {
        HStack(spacing: 6) {
            Image(store.cursorColor.assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .shadow(color: store.cursorColor.swatch.opacity(0.55), radius: 3)

            if let icon = frontmost.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            }

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(statusText) // re-trigger transitions on text change

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var statusText: String {
        let detail = state.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state.activity {
        case .thinking:
            return "thinking…"
        case .toolCall(let name):
            if !detail.isEmpty { return detail }
            return name
        case .listening:
            return "listening…"
        case .error(let msg):
            return msg
        case .idle:
            return detail.isEmpty ? "done" : detail
        }
    }
}

@MainActor
private final class FrontmostAppObserver: ObservableObject {
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
