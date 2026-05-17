//
//  ContextDebugView+Packet.swift
//  Agent in the Notch
//
//  Full activation-packet inspector. Pulls the current preview from the
//  coordinator and exposes it in a monospaced read-only editor.
//

import SwiftUI
import AppKit

extension ContextDebugView {
    var packetPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activation packet")
                    .font(.headline)
                Spacer()
                let lineCount = activationPreview.split(separator: "\n", omittingEmptySubsequences: false).count
                let charCount = activationPreview.count
                Text("\(lineCount) lines · \(charCount) chars")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(activationPreview, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the activation packet to the clipboard")
            }

            if activationPreview.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No activation packet available yet — trigger a capture or wait for one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TextEditor(text: .constant(activationPreview))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.06))
                        )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
