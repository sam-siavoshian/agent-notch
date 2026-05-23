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
        VStack(alignment: .leading, spacing: 11) {
            cursorColorRow
            cursorModeRow
            providerRow
            everywhereRow
            advancedRow
            killSwitchRow
            quitRow
            savedBadge
        }
        // idealHeight (not minHeight) propagates through the parent's
        // .fixedSize(vertical:true) so the notch GeometryReader measures
        // a tall settings frame and grows the notch accordingly.
        .frame(maxWidth: .infinity, idealHeight: 280, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
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

    private var cursorColorRow: some View {
        let activeSwatch = store.cursorColor.swatch
        return SettingRow(title: "Cursor") {
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
                    .foregroundStyle(activeSwatch)
                    .shadow(color: activeSwatch.opacity(0.7), radius: 5)
                    .animation(.smooth(duration: 0.25), value: store.cursorColor)
            }
        }
    }

    private var cursorModeRow: some View {
        SettingRow(title: "Mode") {
            HStack(spacing: 4) {
                ToolbarIconButton(
                    systemImage: "cursorarrow",
                    label: "Companion",
                    isActive: store.cursorMode == .companion
                ) {
                    store.cursorMode = .companion
                }
                ToolbarIconButton(
                    systemImage: "circle.dotted",
                    label: "Glow",
                    isActive: store.cursorMode == .glow
                ) {
                    store.cursorMode = .glow
                }
            }
        }
    }

    /// Toggle between Anthropic API (default) and the user's local
    /// `claude` CLI as the agent backend. Settings persist; takes effect on
    /// the next long-press.
    private var providerRow: some View {
        SettingRow(title: "Provider") {
            HStack(spacing: 4) {
                ToolbarIconButton(
                    systemImage: "cloud",
                    label: "Anthropic",
                    isActive: store.provider == .anthropicAPI
                ) {
                    store.provider = .anthropicAPI
                }
                ToolbarIconButton(
                    systemImage: "terminal",
                    label: "Claude Code",
                    isActive: store.provider == .claudeCodeCLI
                ) {
                    store.provider = .claudeCodeCLI
                }
                if store.provider == .claudeCodeCLI,
                   PermissionChecker.shared.claudeCodeInstalled == false {
                    Button {
                        ClaudeCodeInstallWindowController.shared.toggle()
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SoftPill.Status.amber)
                    }
                    .buttonStyle(.plain)
                    .help("Claude Code CLI not detected. Click for install instructions.")
                }
            }
        }
    }

    /// Notch panel visibility scope. Off (default): standard menu-bar-level
    /// floating panel. On: rides above the screen-saver layer so it stays
    /// visible during idle / mission control / full-screen apps. Cannot
    /// draw over the macOS login window (different security session).
    private var everywhereRow: some View {
        SettingRow(title: "Everywhere") {
            HStack(spacing: 4) {
                ToolbarIconButton(
                    systemImage: "rectangle.on.rectangle",
                    label: "Standard",
                    isActive: store.showEverywhere == false
                ) {
                    store.showEverywhere = false
                }
                ToolbarIconButton(
                    systemImage: "square.stack.3d.up.fill",
                    label: "Everywhere",
                    isActive: store.showEverywhere == true
                ) {
                    store.showEverywhere = true
                }
            }
        }
    }

    private var advancedRow: some View {
        HStack {
            Spacer()
            Button {
                AdvancedSettingsWindowController.shared.toggle()
            } label: {
                GhostPill(tint: SoftPill.Text.secondary) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .bold))
                        Text("Advanced")
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open audio + API key settings in a separate panel")
        }
    }

    private var killSwitchRow: some View {
        SettingRow(title: "Kill Switch") {
            ShortcutRecorderView(
                shortcut: store.killSwitchShortcut,
                onChange: { store.killSwitchShortcut = $0 }
            )
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

struct DevicePickerMenu: View {
    let icon: String
    let placeholder: String
    let devices: [AudioDevice]
    let selectedUID: String?
    let onSelect: (String?) -> Void

    private var selectedName: String {
        if let uid = selectedUID, let match = devices.first(where: { $0.uid == uid }) {
            return match.name
        }
        return placeholder
    }

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                if selectedUID == nil {
                    Label(placeholder, systemImage: "checkmark")
                } else {
                    Text(placeholder)
                }
            }
            if !devices.isEmpty { Divider() }
            ForEach(devices) { device in
                Button {
                    onSelect(device.uid)
                } label: {
                    if device.uid == selectedUID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            GhostPill(tint: SoftPill.Text.secondary) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                    Text(selectedName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SettingRow<Content: View>: View {
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

private struct ShortcutRecorderView: View {
    let shortcut: KillSwitchShortcut
    let onChange: (KillSwitchShortcut) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stopRecording() } else { startRecording() }
        } label: {
            GhostPill(tint: recording ? SoftPill.Status.amber : SoftPill.Text.secondary) {
                HStack(spacing: 4) {
                    Image(systemName: recording ? "record.circle" : "keyboard")
                        .font(.system(size: 9, weight: .bold))
                    Text(recording ? "Press keys…" : shortcut.displayString)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Click to record a new kill-switch shortcut. Press a chord with at least one modifier; Escape cancels.")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels without saving.
            if event.keyCode == 0x35 {
                stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Require at least one modifier so plain letters don't bind.
            guard !mods.isEmpty else { return nil }
            let label = (event.charactersIgnoringModifiers ?? "?").uppercased()
            onChange(KillSwitchShortcut(
                keyCode: event.keyCode,
                keyLabel: label,
                modifiers: mods.rawValue
            ))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
