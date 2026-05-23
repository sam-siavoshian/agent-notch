//
//  ClaudeCodeInstallView.swift
//  Agent in the Notch
//
//  Card shown when the user picks Claude Code as the agent provider but the
//  `claude` CLI is not installed on this machine. Standalone NSPanel surfaced
//  from the Settings warning chip; status pill auto-flips to green the
//  moment PermissionChecker detects an install.
//

import SwiftUI
import AppKit

struct ClaudeCodeInstallView: View {
    @ObservedObject private var checker = PermissionChecker.shared

    private var installed: Bool { checker.claudeCodeInstalled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: installed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(installed ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code CLI")
                        .font(.system(size: 16, weight: .semibold))
                    Text(installed ? "Detected on this machine." : "Not detected — install to run in CC provider mode.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if !installed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install via either path:")
                        .font(.system(size: 12, weight: .semibold))
                    Text("• Homebrew: `brew install anthropic/tap/claude-code`")
                        .font(.system(size: 11, design: .monospaced))
                    Text("• npm:      `npm install -g @anthropic-ai/claude-code`")
                        .font(.system(size: 11, design: .monospaced))
                    Text("Then run `claude login` once to authenticate with your Anthropic account.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)

                HStack(spacing: 10) {
                    Button("Open claude.ai/code") {
                        if let url = URL(string: "https://claude.ai/code") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Re-check now") {
                        checker.refresh()
                    }
                    Spacer()
                }
            }

            Text("Status updates automatically every half-second; the chip in Settings flips green the moment the binary lands on PATH.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 420)
    }
}

@MainActor
final class ClaudeCodeInstallWindowController {
    static let shared = ClaudeCodeInstallWindowController()

    private var window: NSWindow?

    func toggle() {
        if let w = window, w.isVisible {
            w.close()
            return
        }
        present()
    }

    func present() {
        let hosting = NSHostingController(rootView: ClaudeCodeInstallView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "Claude Code Install"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
