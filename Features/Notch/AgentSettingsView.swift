//
//  AgentSettingsView.swift
//  Agent in the Notch
//

import SwiftUI
import AppKit

struct AgentSettingsView: View {
    @ObservedObject private var store = AgentSettingsStore.shared
    @State private var savedOpacity: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            reasoningEffortRow
            cursorColorRow
            ttsVoiceRow
            quitRow
            savedBadge
        }
        .onChange(of: store.settings) { _, _ in
            savedOpacity = 1
            withAnimation(.easeOut(duration: 0.4).delay(1.0)) {
                savedOpacity = 0
            }
        }
    }

    private var savedBadge: some View {
        HStack {
            Spacer()
            HStack(spacing: 5) {
                StatusBadge(color: SoftPill.Status.green, symbol: "checkmark", size: 12)
                Text("Saved")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SoftPill.Status.green)
            }
            .opacity(savedOpacity)
        }
    }

    private var reasoningEffortRow: some View {
        SettingRow(title: "Reasoning") {
            PillToolbar {
                ForEach(AgentReasoningEffort.allCases) { effort in
                    ToolbarIconButton(
                        systemImage: effortIcon(effort),
                        label: effort.displayName,
                        isActive: store.reasoningEffort == effort
                    ) {
                        store.reasoningEffort = effort
                    }
                }
            }
        }
    }

    private func effortIcon(_ effort: AgentReasoningEffort) -> String {
        effort.iconName
    }

    private var cursorColorRow: some View {
        SettingRow(title: "Cursor") {
            HStack(spacing: 2) {
                ForEach(CursorColor.allCases) { color in
                    SwatchPillButton(
                        color: color.swatch,
                        isSelected: store.cursorColor == color
                    ) {
                        store.cursorColor = color
                        AgentInterfaces.cursor?.setCursorColor(color)
                    }
                    .help(color.displayName)
                }
                Spacer(minLength: 4)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.cursorColor.swatch)
                    .shadow(color: store.cursorColor.swatch.opacity(0.7), radius: 5)
                    .animation(.smooth(duration: 0.25), value: store.cursorColor)
            }
        }
    }

    private var ttsVoiceRow: some View {
        SettingRow(title: "Voice") {
            Menu {
                ForEach(TTSVoice.allCases) { voice in
                    Button(voice.displayName) { store.ttsVoice = voice }
                }
            } label: {
                GhostPill(tint: SoftPill.Text.secondary) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                        Text(store.ttsVoice.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var quitRow: some View {
        HStack {
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                GhostPill(tint: SoftPill.Status.red) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 9, weight: .bold))
                        Text("Quit")
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Quit Agent in the Notch")
        }
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SoftPill.Text.secondary)
            Spacer(minLength: 6)
            content
        }
    }
}

private struct SaveKeyButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
                Text("Save")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(enabled ? 1.0 : 0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(SoftPill.CTA.gradient)
                        .opacity(enabled ? 1.0 : 0.35)
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                }
            )
            .shadow(
                color: SoftPill.CTA.from.opacity(enabled ? (hovered ? 0.55 : 0.30) : 0.0),
                radius: hovered ? 10 : 6,
                x: 0, y: hovered ? 4 : 2
            )
            .scaleEffect(pressed ? 0.96 : (hovered ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.18), value: hovered)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 && enabled }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if enabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}
