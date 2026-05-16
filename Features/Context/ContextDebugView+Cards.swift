//
//  ContextDebugView+Cards.swift
//  Agent in the Notch
//

import AppKit
import SwiftUI

extension ContextDebugView {

    func metricCard(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color.opacity(0.9))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 2)
            }

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(color.opacity(0.18), lineWidth: 1)
                )
        )
    }

    func pipelineCard(_ title: String, _ value: String, _ detail: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color.opacity(0.86))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.76))
                Spacer(minLength: 2)
            }

            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(4)
        }
        .padding(10)
        .frame(minHeight: 116, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    func captureCard(_ snapshot: ContextDebugSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = NSImage(data: snapshot.jpegData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 86)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                captureMetadata(snapshot)
                Text(snapshot.textPreview.isEmpty ? "No useful OCR text captured." : snapshot.textPreview)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(9)
        .background(rowBackground)
    }

    func captureMetadata(_ snapshot: ContextDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusPill(snapshot.trigger.rawValue, color: .cyan)
                Text(snapshot.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                Text("\(snapshot.recognizedTextCount) OCR")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.42))
            }

            Text(snapshot.appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)

            Text(snapshot.windowTitle.isEmpty ? "Untitled window" : snapshot.windowTitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
        }
    }

    func compactCaptureRow(_ snapshot: ContextDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                statusPill(snapshot.trigger.rawValue, color: .cyan)
                Text(relativeTime(snapshot.capturedAt))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Text(snapshot.appName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Text(snapshot.textPreview.isEmpty ? "No useful OCR preview." : snapshot.textPreview)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(2)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    func aiEventSummary(_ event: ContextAIObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                statusPill(event.status.rawValue, color: statusColor(event.status))
                if let laneName = event.laneName {
                    statusPill(laneName, color: .purple)
                }
                if let latency = event.latencyMilliseconds {
                    statusPill("\(latency)ms", color: .blue)
                }
                if let confidence = event.confidence {
                    statusPill("conf \(String(format: "%.2f", confidence))", color: .green)
                }
            }

            detailLine("Surface", event.surfaceLabel)
            detailLine("Task", event.primaryTask)
            detailLine("Summary", event.summary)
            detailList("Controls", event.controls)
            detailList("Affordances", event.affordances)
            detailList("Memory candidates", event.memoryCandidates)
        }
    }

    func aiEventRow(_ event: ContextAIObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                statusPill(event.status.rawValue.uppercased(), color: statusColor(event.status))
                if let laneName = event.laneName {
                    statusPill(laneName, color: .purple)
                }
                Text(event.happenedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))

                Spacer(minLength: 6)

                if let latency = event.latencyMilliseconds {
                    statusPill("\(latency)ms", color: .blue)
                }

                if let source = event.source {
                    statusPill(source, color: source == ContextGeminiObservation.Source.cache.rawValue ? .orange : .green)
                }
            }

            Text("\(event.trigger.rawValue) - \(event.appName)\(event.windowTitle.isEmpty ? "" : " - \(event.windowTitle)")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)

            Text(primaryEventText(event))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(4)
                .textSelection(.enabled)

            if event.status == .completed {
                Text("\(event.controlsCount) controls - \(event.affordancesCount) affordances - \(event.entitiesCount) entities\(confidenceText(event.confidence))\(imageText(event))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }

            aiArtifactInspector(event)

            VStack(alignment: .leading, spacing: 4) {
                detailLine("Model", event.model)
                detailLine("Attempt", event.attemptID?.uuidString)
                detailLine("Lane", event.laneName)
                detailLine("Prompt version", event.promptVersion)
                detailLine("MIME", event.requestMimeType)
                detailLine("Media resolution", event.requestMediaResolution)
                detailLine("Thinking level", event.requestThinkingLevel)
                detailLine("Surface", event.surfaceLabel)
                detailLine("Screen type", event.screenType)
                detailLine("Task", event.primaryTask)
                detailLine("Layout", event.layoutSummary)
                detailLine("Content", event.contentSummary)
                detailList("Controls", event.controls)
                detailList("Landmarks", event.landmarks)
                detailList("State", event.stateIndicators)
                detailList("Navigation", event.navigationPaths)
                detailList("Data", event.dataRegions)
                detailList("Workflow", event.workflowHints)
                detailList("Memory", event.memoryCandidates)
                detailList("Entities", event.entities)
                detailList("Affordances", event.affordances)
                detailList("Negative", event.negativeCues)
                detailList("Uncertain", event.uncertainty)
                detailLine("Image hash", event.imageHash)
                detailLine("Request image", event.requestImagePath)
                detailLine("Request metadata", event.requestMetadataPath)
                detailLine("Capture image", event.captureImagePath)
                detailLine("Capture JSON", event.captureJSONPath)
                detailLine("Prompt", event.promptPath)
                detailLine("Raw response", event.rawResponsePath)
                detailLine("Error", event.errorPath)
            }
        }
        .padding(9)
        .background(rowBackground)
    }

    @ViewBuilder
    func aiArtifactInspector(_ event: ContextAIObservationEvent) -> some View {
        if hasInlineArtifacts(event) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    requestImagePreview(event.requestImagePath)
                    artifactTextBlock("Request metadata + transformations", event.requestMetadataPath, maxCharacters: 4_000)
                    artifactTextBlock("Prompt sent to Gemini", event.promptPath, maxCharacters: 8_000)
                    artifactTextBlock("Raw Gemini response", event.rawResponsePath, maxCharacters: 8_000)
                    artifactTextBlock("Gemini error", event.errorPath, maxCharacters: 4_000)
                }
                .padding(.top, 4)
            } label: {
                Label("Inline request/response artifacts", systemImage: "tray.full")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .tint(.white.opacity(0.58))
        }
    }

    func hasInlineArtifacts(_ event: ContextAIObservationEvent) -> Bool {
        [
            event.requestImagePath,
            event.requestMetadataPath,
            event.promptPath,
            event.rawResponsePath,
            event.errorPath
        ].contains { path in
            guard let path else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    @ViewBuilder
    func requestImagePreview(_ path: String?) -> some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Screenshot sent to Gemini")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    func artifactTextBlock(_ title: String, _ path: String?, maxCharacters: Int) -> some View {
        if let path, let text = fileText(path, maxCharacters: maxCharacters), !text.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Text(text)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                    )
            }
        }
    }

    func memoryCard(_ memory: ContextAppMemory) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .foregroundStyle(.orange.opacity(0.86))
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.appName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("First seen \(relativeTime(memory.firstSeen)) - last seen \(relativeTime(memory.lastSeen))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer(minLength: 6)
                statusPill("\(memory.surfaces.count) surfaces", color: .orange)
                statusPill("\(memory.transitions.count) transitions", color: .cyan)
                statusPill("\(memory.negativeNotes.count) negative", color: .yellow)
            }

            if memory.surfaces.isEmpty {
                mutedText("No surfaces learned yet.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(memory.surfaces.sorted { $0.lastSeen > $1.lastSeen }.prefix(4)) { surface in
                        surfaceMemoryRow(surface)
                    }
                }
            }

            if !memory.transitions.isEmpty {
                detailList(
                    "Transitions",
                    memory.transitions
                        .sorted { $0.lastSeen > $1.lastSeen }
                        .prefix(6)
                        .map { "\($0.fromTitle) -> \($0.toTitle) via \($0.trigger.rawValue) (\($0.evidenceCount)x)" }
                )
            }

            if !memory.negativeNotes.isEmpty {
                detailList(
                    "Negative memory",
                    memory.negativeNotes
                        .sorted { $0.lastSeen > $1.lastSeen }
                        .prefix(6)
                        .map { "\($0.surfaceTitle): \($0.note) (\($0.evidenceCount)x)" }
                )
            }
        }
        .padding(10)
        .background(rowBackground)
    }

    func surfaceMemoryRow(_ surface: ContextSurfaceMemory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(surface.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !surface.facts.isEmpty {
                    statusPill("\(surface.facts.count) facts", color: .orange)
                }
                if !surface.controls.isEmpty {
                    statusPill("\(surface.controls.count) controls", color: .cyan)
                }
                if !surface.entities.isEmpty {
                    statusPill("\(surface.entities.count) entities", color: .green)
                }
            }

            detailList(
                "Structured facts",
                surface.facts
                    .sorted { $0.lastSeen > $1.lastSeen }
                    .prefix(10)
                    .map { "[\($0.category)/\($0.durability)] \($0.text)" }
            )
            detailList(
                "Structured controls",
                surface.controls
                    .sorted { $0.lastSeen > $1.lastSeen }
                    .prefix(10)
                    .map { control in
                        let hint = control.actionHint.isEmpty ? "" : ": \(control.actionHint)"
                        return "\(control.label) (\(control.role), \(control.region))\(hint)"
                    }
            )
            detailList("Structured entities", surface.entities.sorted { $0.lastSeen > $1.lastSeen }.prefix(12).map(\.text))
            detailList("UI facts", surface.semanticHighlights)
            detailList("Controls", surface.controlHighlights)
            detailList("Affordances", surface.affordanceHighlights)
            detailList("Text", surface.textHighlights)
            detailList("Uncertain", surface.uncertaintyHighlights)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.032))
        )
    }
}
