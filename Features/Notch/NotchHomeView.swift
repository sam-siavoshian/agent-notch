//
//  NotchHomeView.swift
//  Agent in the Notch
//
//  Home tab in compact soft-pill form.
//

import SwiftUI

struct NotchHomeView: View {
    @ObservedObject private var state = AgentState.shared
    @ObservedObject private var store = AgentSettingsStore.shared
    @ObservedObject private var permissions = PermissionChecker.shared

    private var isActive: Bool {
        switch state.activity {
        case .idle, .error: return false
        case .listening, .thinking, .toolCall: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !permissions.missing.isEmpty {
                permissionBanner
            }
            statusHero
            if !state.lastTranscript.isEmpty {
                lastRequestCard
            }
            if !state.activityLog.isEmpty {
                activityFeed
            } else if !isActive && state.lastTranscript.isEmpty {
                emptyState
            }
        }
    }

    private var permissionBanner: some View {
        let missing = permissions.missing
        let primary = missing.first
        return Button {
            if let primary { permissions.openSettings(for: primary) }
        } label: {
            HStack(spacing: 6) {
                StatusBadge(color: SoftPill.Status.amber, symbol: "exclamationmark.triangle.fill", size: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(missing.count == 1
                         ? "\(primary?.label ?? "Permission") not granted"
                         : "\(missing.count) permissions missing")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SoftPill.Status.amber)
                    Text("Tap to open System Settings")
                        .font(.system(size: 9))
                        .foregroundStyle(SoftPill.Text.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                PillBackground(
                    fill: AnyShapeStyle(SoftPill.Surface.inset),
                    glow: SoftPill.Status.amber,
                    cornerRadius: 10
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var statusHero: some View {
        HStack(spacing: 8) {
            StatusBadge(
                color: SoftPill.activityHue(state.activity),
                symbol: state.activity.symbol,
                size: 20
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(state.activity.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SoftPill.activityHue(state.activity))
                    .animation(nil, value: state.activity.label)
                Group {
                    if !state.detail.isEmpty {
                        Text(state.detail).foregroundStyle(SoftPill.Text.secondary)
                    } else {
                        Text(isActive ? "Working on it…" : "Ready when you are")
                            .foregroundStyle(SoftPill.Text.muted)
                    }
                }
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.base),
                glow: SoftPill.activityHue(state.activity),
                cornerRadius: 11
            )
        )
    }

    private var lastRequestCard: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 9))
                .foregroundStyle(SoftPill.Text.muted)
                .padding(.top, 1)
            Text(state.lastTranscript)
                .font(.system(size: 10.5))
                .foregroundStyle(SoftPill.Text.primary.opacity(0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.inset),
                cornerRadius: 9
            )
        )
    }

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("RECENT")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(SoftPill.Text.muted)
                .padding(.leading, 4)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(state.activityLog) { entry in
                        ActivityLogRow(entry: entry)
                    }
                }
            }
            .frame(maxHeight: 110)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if AgentInterfaces.cursor == nil {
                StatusBadge(color: SoftPill.Status.amber, symbol: "exclamationmark", size: 22)
                Text("Cursor companion not connected")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.secondary)
            } else {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(store.cursorColor.swatch.opacity(0.8))
                Text("Long-press cursor to start")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SoftPill.Text.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

private struct ActivityLogRow: View {
    let entry: AgentLogEntry

    var body: some View {
        HStack(spacing: 6) {
            StatusBadge(
                color: SoftPill.activityHue(entry.activity),
                symbol: entry.activity.symbol,
                size: 12
            )
            Text(rowLabel)
                .font(.system(size: 10))
                .foregroundStyle(SoftPill.Text.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(entry.timestamp, style: .relative)
                .font(.system(size: 8.5))
                .foregroundStyle(SoftPill.Text.muted)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            PillBackground(
                fill: AnyShapeStyle(SoftPill.Surface.inset),
                cornerRadius: 8
            )
        )
    }

    private var rowLabel: String {
        entry.detail.isEmpty ? entry.activity.label : entry.detail
    }
}
