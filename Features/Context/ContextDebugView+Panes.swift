//
//  ContextDebugView+Panes.swift
//  Agent in the Notch
//

import AppKit
import SwiftUI

extension ContextDebugView {

    var overviewDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pipeline") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                    pipelineCard("1. Capture", "\(snapshots.count) recent", "Screenshots stored with trigger, app, window, cursor, and OCR.", "camera.viewfinder", .cyan)
                    pipelineCard("2. OCR", "\(diagnostics?.latestRecognizedTextCount ?? 0) latest", "Vision text recognition produces the local text layer before AI.", "text.viewfinder", .mint)
                    pipelineCard("3. Gemini", aiSummary?.latestStatusLine ?? "No AI observation yet", "Runs parallel Activity, UI Map, Entity, and Interaction lanes; each lane logs its own prompt, image, and raw output.", "brain.head.profile", .purple)
                    pipelineCard("4. Memory", "\(memories.count) apps", "Lane outputs reduce into structured current-work, UI operation, entity, workflow, and caution memory.", "rectangle.stack.badge.person.crop", .orange)
                    pipelineCard("5. Injection", "\(activationPreview.count) chars", "This is the packet the computer-use agent sees at activation.", "text.badge.checkmark", .green)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                section("Latest Screen") {
                    VStack(alignment: .leading, spacing: 8) {
                        latestScreenshotPreview
                        if let latest = snapshots.first {
                            captureMetadata(latest)
                            Text(latest.textPreview.isEmpty ? "No useful OCR preview." : latest.textPreview)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(4)
                                .textSelection(.enabled)
                        } else {
                            mutedText("No screenshot captured yet.")
                        }
                    }
                }

                section("Latest Gemini Output") {
                    if let event = aiEvents.first(where: { $0.status == .completed }) {
                        aiEventSummary(event)
                    } else {
                        mutedText("No completed Gemini observation yet.")
                    }
                }
            }

            section("Injected Context Preview") {
                debugText(firstLines(activationPreview, maxLines: 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var capturesInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshots.isEmpty {
                mutedText("No captures yet. Use the camera button or interact with the Mac while gathering is live.")
            } else {
                ForEach(snapshots) { snapshot in
                    captureCard(snapshot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var aiInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(aiSummary?.statusLine ?? "No AI observations yet.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .textSelection(.enabled)

            if aiEvents.isEmpty {
                mutedText("No Gemini events yet. Use the camera button or interact with the Mac after configuring GEMINI_API_KEY.")
            } else {
                ForEach(aiEvents) { event in
                    aiEventRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var memoryInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if memories.isEmpty {
                mutedText("No app memory yet. Capture screens with OCR/Gemini enabled and this pane will show learned surfaces, controls, transitions, and negative memory.")
            } else {
                ForEach(memories, id: \.appName) { memory in
                    memoryCard(memory)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    var latestScreenshotPreview: some View {
        if let data = snapshots.first?.jpegData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 115)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("Latest screenshot")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.58))
                        .foregroundStyle(.white.opacity(0.84))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(6)
                }
        } else {
            mutedText("No screenshot preview yet.")
                .frame(maxWidth: .infinity, minHeight: 78)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
        }
    }
}
