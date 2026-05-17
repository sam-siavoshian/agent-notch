//
//  AgentSettingsView.swift
//  Agent in the Notch
//
//  Four-knob settings panel in compact soft-pill form.
//

import SwiftUI
import AppKit

struct AgentSettingsView: View {
    @ObservedObject private var store = AgentSettingsStore.shared
    @State private var showAdvanced = false
    @State private var savedOpacity: Double = 0
    @State private var diagnosticsStatus = ""
    @State private var contextHealth = "Checking context..."
    @State private var openAIKeyDraft = ""
    @State private var geminiKeyDraft = ""
    @State private var anthropicKeyDraft = ""
    @State private var openAIKeyIsSet = false
    @State private var geminiKeyIsSet = false
    @State private var anthropicKeyIsSet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            reasoningEffortRow
            cursorColorRow
            preferencesRow
            apiKeysSection
            advancedSection
            quitRow
            savedBadge
        }
        .onChange(of: store.settings) { _, _ in
            savedOpacity = 1
            withAnimation(.easeOut(duration: 0.4).delay(1.0)) {
                savedOpacity = 0
            }
        }
        .task {
            refreshKeyStatus()
            await refreshContextHealth()
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
        switch effort {
        case .low:    return "bolt.fill"
        case .medium: return "scalemass.fill"
        case .high:   return "brain.head.profile"
        }
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

    private var preferencesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preferences")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SoftPill.Text.secondary)
                .padding(.leading, 2)
            pillEditor(
                text: Binding(get: { store.preferences }, set: { store.preferences = $0 }),
                placeholder: "e.g. \u{201C}open Twitter\u{201D} means x.com",
                monospaced: false,
                minHeight: 44,
                maxHeight: 64
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

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                GhostPill(tint: SoftPill.Text.secondary) {
                    HStack(spacing: 4) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("Advanced")
                    }
                }
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 7) {
                    systemPromptEditor
                    diagnosticsRow
                    if !contextHealth.isEmpty {
                        Text(contextHealth)
                            .font(.system(size: 9))
                            .foregroundStyle(SoftPill.Text.muted)
                            .lineLimit(2)
                            .padding(.horizontal, 4)
                    }
                    if !diagnosticsStatus.isEmpty {
                        Text(diagnosticsStatus)
                            .font(.system(size: 9))
                            .foregroundStyle(SoftPill.Text.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var systemPromptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System prompt override")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SoftPill.Text.secondary)
                .padding(.leading, 2)
            pillEditor(
                text: Binding(get: { store.systemPrompt }, set: { store.systemPrompt = $0 }),
                placeholder: "Override agent system prompt…",
                monospaced: true,
                minHeight: 44,
                maxHeight: 64
            )
        }
    }

    private func refreshKeyStatus() {
        openAIKeyIsSet = Secrets.openAIAPIKey != nil
        geminiKeyIsSet = Secrets.geminiAPIKey != nil
        anthropicKeyIsSet = Secrets.anthropicAPIKey != nil
    }

    private func flashSaved() {
        savedOpacity = 1
        withAnimation(.easeOut(duration: 0.4).delay(1.0)) { savedOpacity = 0 }
    }

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("API Keys")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(SoftPill.Text.secondary)
                Text("· stored in macOS Keychain")
                    .font(.system(size: 9))
                    .foregroundStyle(SoftPill.Text.muted)
                Spacer()
            }
            .padding(.leading, 2)

            pillKeyField(
                "OpenAI",
                placeholder: "sk-proj-…",
                draft: $openAIKeyDraft,
                isSet: openAIKeyIsSet
            ) {
                Secrets.setOpenAIAPIKey(openAIKeyDraft)
                openAIKeyDraft = ""
                openAIKeyIsSet = true
                flashSaved()
            }
            pillKeyField(
                "Gemini",
                placeholder: "AIzaSy…",
                draft: $geminiKeyDraft,
                isSet: geminiKeyIsSet
            ) {
                Secrets.setGeminiAPIKey(geminiKeyDraft)
                geminiKeyDraft = ""
                geminiKeyIsSet = true
                flashSaved()
            }
            pillKeyField(
                "Anthropic",
                placeholder: "sk-ant-…",
                draft: $anthropicKeyDraft,
                isSet: anthropicKeyIsSet
            ) {
                Secrets.setAnthropicAPIKey(anthropicKeyDraft)
                anthropicKeyDraft = ""
                anthropicKeyIsSet = true
                flashSaved()
            }
        }
    }

    @ViewBuilder
    private func pillKeyField(
        _ label: String,
        placeholder: String,
        draft: Binding<String>,
        isSet: Bool,
        onSave: @escaping () -> Void
    ) -> some View {
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSave = !trimmed.isEmpty

        HStack(spacing: 8) {
            StatusBadge(
                color: isSet ? SoftPill.Status.green : SoftPill.Status.gray,
                symbol: isSet ? "checkmark" : "key.fill",
                size: 14
            )
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SoftPill.Text.primary)
                .frame(width: 56, alignment: .leading)
            SecureField(isSet ? "configured · paste to replace" : placeholder, text: draft)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SoftPill.Text.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    PillBackground(
                        fill: AnyShapeStyle(SoftPill.Surface.inset),
                        cornerRadius: 8
                    )
                )
                .onSubmit { if canSave { onSave() } }
            SaveKeyButton(enabled: canSave, action: onSave)
        }
    }

    @ViewBuilder
    private func pillEditor(
        text: Binding<String>,
        placeholder: String,
        monospaced: Bool,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11, design: monospaced ? .monospaced : .default))
            .foregroundStyle(SoftPill.Text.primary)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(
                PillBackground(
                    fill: AnyShapeStyle(SoftPill.Surface.inset),
                    cornerRadius: 11
                )
            )
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                        .foregroundStyle(SoftPill.Text.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    private var diagnosticsRow: some View {
        SettingRow(title: "Context") {
            PillToolbar {
                ToolbarIconButton(systemImage: "doc.on.doc") {
                    copyActivationContext()
                }
                ToolbarIconButton(systemImage: "arrow.clockwise") {
                    Task { await refreshContextHealth() }
                }
            }
        }
    }

    private func copyActivationContext() {
        Task { @MainActor in
            let context = await AgentInterfaces.context?.getRecentActivityContext() ?? ""
            let text = context.isEmpty ? "No activation context available yet." : context
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            diagnosticsStatus = "Copied activation context."
            await refreshContextHealth()
        }
    }

    private func refreshContextHealth() async {
        let diagnostics = await ContextCoordinator.shared.diagnostics()
        await MainActor.run { contextHealth = diagnostics.summary }
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
