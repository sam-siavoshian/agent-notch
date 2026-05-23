//
//  AdvancedSettingsView.swift
//  Agent in the Notch
//
//  Content of the Advanced floating panel. Hosts the audio controls that
//  used to live inline in `AgentSettingsView` plus SecureField inputs for the
//  four API keys, persisted to Keychain via `Core/Secrets.swift`.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject private var store = AgentSettingsStore.shared
    @ObservedObject private var audio = AudioDeviceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Agent") {
                SettingRow(title: "Model") {
                    PillToolbar {
                        ForEach(AgentModel.allCases) { model in
                            ToolbarIconButton(
                                systemImage: model.iconName,
                                label: model.displayName,
                                isActive: store.agentModel == model
                            ) {
                                store.agentModel = model
                            }
                        }
                    }
                }
                // Read-only indicator of which computer-use beta the harness
                // will send with the currently-selected model. Two values
                // exist (2025-01-24 for Haiku; 2025-11-24 for Sonnet 4.6 +
                // Opus 4.x) and the wrong one produces HTTP 400 — surfacing
                // it here makes the model/beta pairing visible at a glance.
                SettingRow(title: "Computer-use") {
                    HStack(spacing: 6) {
                        Text(store.agentModel.computerUseBetaHeader
                                .replacingOccurrences(of: "computer-use-", with: ""))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text("(\(store.agentModel.computerUseToolType))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                SettingRow(title: "Reasoning") {
                    PillToolbar {
                        ForEach(AgentReasoningEffort.allCases) { effort in
                            ToolbarIconButton(
                                systemImage: effort.iconName,
                                label: effort.displayName,
                                isActive: store.reasoningEffort == effort
                            ) {
                                store.reasoningEffort = effort
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.25)

            section("Display") {
                SettingRow(title: "Visible in lock screen") {
                    miniSwitch(
                        get: { store.showEverywhere },
                        set: { store.showEverywhere = $0 },
                        help: "Bumps the notch panel to .screenSaver level so it stays visible above mission control, full-screen apps, and the idle screen saver. Cannot draw over the macOS login window (different security session)."
                    )
                }
                SettingRow(title: "Run on boot") {
                    miniSwitch(
                        get: { store.launchAtLogin },
                        set: { store.launchAtLogin = $0 },
                        help: "Registers AgentNotch as a macOS login item via SMAppService. Manage in System Settings → General → Login Items."
                    )
                }
            }

            Divider().opacity(0.25)

            section("Audio") {
                SettingRow(title: "Voice") { voicePicker }
                SettingRow(title: "Mic") {
                    DevicePickerMenu(
                        icon: "mic.fill",
                        placeholder: "System Default",
                        devices: audio.inputs,
                        selectedUID: store.voiceInputDeviceUID,
                        onSelect: { store.voiceInputDeviceUID = $0 }
                    )
                }
                SettingRow(title: "Output") {
                    DevicePickerMenu(
                        icon: "speaker.wave.2.fill",
                        placeholder: "System Default",
                        devices: audio.outputs,
                        selectedUID: store.voiceOutputDeviceUID,
                        onSelect: { store.voiceOutputDeviceUID = $0 }
                    )
                }
            }

            Divider().opacity(0.25)

            section("API Keys") {
                APIKeyRow(label: "Anthropic",
                          placeholder: "sk-ant-…",
                          read: { Secrets.anthropicAPIKey },
                          write: { Secrets.setAnthropicAPIKey($0) })
                APIKeyRow(label: "OpenAI",
                          placeholder: "sk-…",
                          read: { Secrets.openAIAPIKey },
                          write: { Secrets.setOpenAIAPIKey($0) })
                APIKeyRow(label: "OpenRouter",
                          placeholder: "sk-or-…",
                          read: { Secrets.openRouterAPIKey },
                          write: { Secrets.setOpenRouterAPIKey($0) })
                APIKeyRow(label: "Gemini",
                          placeholder: "AIza…",
                          read: { Secrets.geminiAPIKey },
                          write: { Secrets.setGeminiAPIKey($0) })
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Shrunk SwiftUI switch — the native `.switch` style is huge in a
    /// dense settings panel; scale + frame caps it to row-row height.
    private func miniSwitch(get: @escaping () -> Bool,
                            set: @escaping (Bool) -> Void,
                            help: String) -> some View {
        Toggle("", isOn: Binding(get: get, set: set))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .scaleEffect(0.8, anchor: .trailing)
            .frame(width: 28, height: 16, alignment: .trailing)
            .help(help)
    }

    private var voicePicker: some View {
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

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(SoftPill.Text.muted)
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }
}

private struct APIKeyRow: View {
    let label: String
    let placeholder: String
    let read: () -> String?
    let write: (String) -> Void

    @State private var value: String = ""
    @State private var reveal: Bool = false
    @State private var stored: Bool = false
    @State private var savedFlash: Bool = false

    var body: some View {
        SettingRow(title: label) {
            HStack(spacing: 6) {
                statusDot
                Group {
                    if reveal {
                        TextField(placeholder, text: $value, onCommit: commit)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(placeholder, text: $value, onCommit: commit)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: 170)

                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SoftPill.Text.muted)
                }
                .buttonStyle(.plain)
                .help(reveal ? "Hide" : "Reveal")
            }
        }
        .onAppear(perform: hydrate)
    }

    private var statusDot: some View {
        Circle()
            .fill(stored ? SoftPill.Status.green : SoftPill.Text.muted.opacity(0.35))
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(Color.white.opacity(savedFlash ? 0.6 : 0), lineWidth: 1)
            )
            .help(stored ? "Saved" : "Not set")
    }

    private func hydrate() {
        let current = read() ?? ""
        value = current
        stored = !current.isEmpty
    }

    private func commit() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        write(trimmed)
        stored = true
        withAnimation(.easeOut(duration: 0.15)) { savedFlash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.4)) { savedFlash = false }
        }
    }
}
