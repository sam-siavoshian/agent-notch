//
//  AgentSettingsView.swift
//  Agent in the Notch
//
//  The four-knob settings panel (PRD §6.2). User-facing inputs only; nothing
//  about JSON shape leaks into the UI.
//

import SwiftUI
import AppKit

struct AgentSettingsView: View {
    @ObservedObject private var store = AgentSettingsStore.shared
    @State private var showSystemPrompt = false
    @State private var diagnosticsStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            reasoningEffortRow
            cursorColorRow
            contextDiagnosticsRow
            preferencesRow
            systemPromptRow
        }
    }

    // MARK: Reasoning effort

    private var reasoningEffortRow: some View {
        SettingRow(title: "Reasoning effort") {
            Picker("", selection: Binding(
                get: { store.reasoningEffort },
                set: { store.reasoningEffort = $0 }
            )) {
                ForEach(AgentReasoningEffort.allCases) { effort in
                    Text(effort.displayName).tag(effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }

    // MARK: Cursor color

    private var cursorColorRow: some View {
        SettingRow(title: "Cursor color") {
            HStack(spacing: 8) {
                ForEach(CursorColor.allCases) { color in
                    Button {
                        store.cursorColor = color
                        AgentInterfaces.cursor?.setCursorColor(color)
                    } label: {
                        Circle()
                            .fill(color.swatch)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(
                                        store.cursorColor == color ? Color.white : Color.white.opacity(0.18),
                                        lineWidth: store.cursorColor == color ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(color.displayName)
                }
            }
        }
    }

    // MARK: Context diagnostics

    private var contextDiagnosticsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(title: "Context") {
                HStack(spacing: 8) {
                    Button {
                        openDirectory(ContextMemoryStore.defaultDirectoryURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Open learned UI memory")

                    Button {
                        openDirectory(AgentMetricsStore.defaultDirectoryURL)
                    } label: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    .help("Open computer-use run metrics")

                    Button {
                        copyActivationContext()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy current activation context packet")
                }
                .buttonStyle(.borderless)
            }

            if !diagnosticsStatus.isEmpty {
                Text(diagnosticsStatus)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    // MARK: Preferences

    private var preferencesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferences")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextEditor(text: Binding(
                get: { store.preferences },
                set: { store.preferences = $0 }
            ))
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 70, maxHeight: 90)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(alignment: .topLeading) {
                if store.preferences.isEmpty {
                    Text("e.g. \u{201C}When I say \u{2018}open Twitter\u{2019}, I mean x.com.\u{201D}")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: System prompt

    private var systemPromptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showSystemPrompt.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showSystemPrompt ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("System prompt override")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            if showSystemPrompt {
                TextEditor(text: Binding(
                    get: { store.systemPrompt },
                    set: { store.systemPrompt = $0 }
                ))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 60, maxHeight: 80)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
    }

    private func openDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        diagnosticsStatus = "Opened \(url.lastPathComponent)."
    }

    private func copyActivationContext() {
        Task { @MainActor in
            let context = await AgentInterfaces.context?.getRecentActivityContext() ?? ""
            let text = context.isEmpty ? "No activation context available yet." : context
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            diagnosticsStatus = "Copied activation context."
        }
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 12)
            content
        }
    }
}
