//
//  ContextGeminiObservationService+Parsing.swift
//  Agent in the Notch
//

import CryptoKit
import Foundation

extension ContextGeminiObservationService {

    static func parseObservation(
        _ rawText: String,
        input: ContextGeminiObservationInput,
        imageHash: String,
        model: String,
        promptVersion: String
    ) throws -> ContextGeminiObservation {
        let data = cleanedJSONString(rawText).data(using: .utf8) ?? Data()
        let payload = try decoder.decode(ObservationPayload.self, from: data)
        let fallbackApp = clean(input.appName) ?? "Unknown app"
        let fallbackWindow = clean(input.windowTitle) ?? "Unknown window"
        let appLabel = clean(payload.appLabel) ?? fallbackApp
        let windowTitle = clean(payload.windowTitle) ?? fallbackWindow
        let surfaceLabel = clean(payload.surfaceLabel) ?? "Visible surface"

        return ContextGeminiObservation(
            id: cacheObservationID(imageHash: imageHash, model: model, promptVersion: promptVersion),
            observedAt: Date(),
            source: .gemini,
            model: model,
            promptVersion: promptVersion,
            imageHash: imageHash,
            appLabel: appLabel,
            windowTitle: windowTitle,
            surfaceID: clean(payload.surfaceID) ?? slug([appLabel, surfaceLabel].joined(separator: "-")),
            surfaceLabel: surfaceLabel,
            summary: clean(payload.summary) ?? "Screen observation unavailable.",
            screenType: clean(payload.screenType) ?? "",
            primaryTask: clean(payload.primaryTask) ?? "",
            layoutSummary: clean(payload.layoutSummary) ?? "",
            contentSummary: clean(payload.contentSummary) ?? "",
            visibleControls: payload.visibleControls.prefix(24).map {
                ContextGeminiObservation.VisibleControl(
                    label: clean($0.label) ?? "Unlabeled control",
                    role: clean($0.role) ?? "control",
                    region: clean($0.region) ?? "unknown-region",
                    actionHint: clean($0.actionHint),
                    confidence: clamp($0.confidence)
                )
            },
            landmarks: cleanStrings(payload.landmarks, maxCount: 16),
            entities: cleanStrings(payload.entities, maxCount: 24),
            affordances: cleanStrings(payload.affordances, maxCount: 16),
            stateIndicators: cleanStrings(payload.stateIndicators, maxCount: 12),
            navigationPaths: cleanStrings(payload.navigationPaths, maxCount: 12),
            dataRegions: cleanStrings(payload.dataRegions, maxCount: 12),
            workflowHints: cleanStrings(payload.workflowHints, maxCount: 12),
            negativeCues: cleanStrings(payload.negativeCues, maxCount: 12),
            memoryCandidates: cleanStrings(payload.memoryCandidates, maxCount: 16),
            uncertainty: cleanStrings(payload.uncertainty, maxCount: 12),
            confidence: clamp(payload.confidence)
        )
    }

    static func parseLaneObservation(
        _ rawText: String,
        lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        imageHash: String,
        model: String,
        promptVersion: String
    ) throws -> ContextGeminiLaneObservation {
        let data = cleanedJSONString(rawText).data(using: .utf8) ?? Data()
        let payload = try decoder.decode(LaneObservationPayload.self, from: data)
        let fallbackApp = clean(input.appName) ?? "Unknown app"
        let fallbackWindow = clean(input.windowTitle) ?? "Unknown window"
        let appLabel = clean(payload.appLabel) ?? fallbackApp
        let windowTitle = clean(payload.windowTitle) ?? fallbackWindow
        let surfaceLabel = clean(payload.surfaceLabel) ?? clean(payload.summary) ?? "Visible surface"

        return ContextGeminiLaneObservation(
            id: cacheObservationID(imageHash: imageHash, model: model, promptVersion: "\(promptVersion)-\(lane.rawValue)"),
            observedAt: Date(),
            source: .gemini,
            model: model,
            promptVersion: promptVersion,
            imageHash: imageHash,
            lane: lane,
            appLabel: appLabel,
            windowTitle: windowTitle,
            surfaceID: clean(payload.surfaceID) ?? slug([appLabel, surfaceLabel, lane.rawValue].joined(separator: "-")),
            surfaceLabel: surfaceLabel,
            screenType: clean(payload.screenType) ?? "",
            summary: clean(payload.summary) ?? "\(lane.label) observation unavailable.",
            primaryTask: clean(payload.primaryTask) ?? "",
            contentSummary: clean(payload.contentSummary) ?? "",
            layoutRegions: cleanStrings(payload.layoutRegions, maxCount: 18),
            controls: payload.controls.prefix(24).map {
                ContextGeminiObservation.VisibleControl(
                    label: clean($0.label) ?? "Unlabeled control",
                    role: clean($0.role) ?? "control",
                    region: clean($0.region) ?? "unknown-region",
                    actionHint: clean($0.actionHint),
                    confidence: clamp($0.confidence)
                )
            },
            entities: cleanStrings(payload.entities, maxCount: 28),
            stateIndicators: cleanStrings(payload.stateIndicators, maxCount: 18),
            workflows: cleanStrings(payload.workflows, maxCount: 18),
            navigation: cleanStrings(payload.navigation, maxCount: 18),
            negativeCues: cleanStrings(payload.negativeCues, maxCount: 18),
            memoryCards: cleanStrings(payload.memoryCards, maxCount: 24),
            uncertainty: cleanStrings(payload.uncertainty, maxCount: 16),
            confidence: clamp(payload.confidence)
        )
    }

    static func cleanedJSONString(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") {
            text.removeFirst("```json".count)
        } else if text.hasPrefix("```") {
            text.removeFirst("```".count)
        }
        if text.hasSuffix("```") {
            text.removeLast("```".count)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cacheObservationID(imageHash: String, model: String, promptVersion: String) -> String {
        sha256Hex("\(imageHash)|\(promptVersion)|\(model)".data(using: .utf8) ?? Data()).prefix(24).description
    }

    static func clean(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    static func cleanStrings(_ values: [String], maxCount: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let cleaned = clean(value) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
            if output.count >= maxCount { break }
        }
        return output
    }

    static func slug(_ value: String) -> String {
        let parts = value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "unknown-surface" : slug
    }

    static func clamp(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0.5 }
        if value > 1 {
            return min(1, max(0, value / 100))
        }
        return min(1, max(0, value))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).lazy.map { String(format: "%02x", $0) }.joined()
    }

    static func debugArtifactPrefix(imageHash: String, laneName: String?) -> String {
        let shortHash = String(imageHash.prefix(16))
        guard let laneName = clean(laneName) else { return shortHash }
        let safeLane = slug(laneName)
        return "\(shortHash)-\(safeLane)"
    }

    static func uniqueControls(_ controls: [ContextGeminiObservation.VisibleControl]) -> [ContextGeminiObservation.VisibleControl] {
        var seen = Set<String>()
        var output: [ContextGeminiObservation.VisibleControl] = []
        for control in controls {
            let key = [
                control.label.lowercased(),
                control.role.lowercased(),
                control.region.lowercased()
            ].joined(separator: "|")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(control)
        }
        return output
    }

    static func normalizedMediaResolution(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "MEDIA_RESOLUTION_", with: "")
        switch value {
        case "LOW":
            return "MEDIA_RESOLUTION_LOW"
        case "MEDIUM":
            return "MEDIA_RESOLUTION_MEDIUM"
        case "HIGH":
            return "MEDIA_RESOLUTION_HIGH"
        default:
            return defaultMediaResolution
        }
    }

    static func normalizedModel(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "gemini-3.1-flash-lite", "3.1-flash-lite", "flash-lite", "lite":
            return "gemini-3.1-flash-lite"
        case "gemini-3-flash", "3-flash", "flash":
            return "gemini-3-flash"
        default:
            return defaultModel
        }
    }

    static func normalizedThinkingLevel(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "minimal", "low", "medium", "high":
            return value ?? defaultThinkingLevel
        default:
            return defaultThinkingLevel
        }
    }

    static func estimatedCostDescription(model: String, config: GeminiObservationRequestConfig) -> String {
        let mediaTokens = estimatedMediaTokens(for: config.mediaResolution)
        guard let pricing = tokenPricing(for: model) else {
            return "unknown for \(model); request logs include media tokens \(mediaTokens) plus text/OCR/output tokens"
        }

        let imageInputCost = Double(mediaTokens) / 1_000_000 * pricing.inputPerMillion
        let maxOutputCost = Double(config.maxOutputTokens) / 1_000_000 * pricing.outputPerMillion
        return "\(mediaTokens) image tokens, image input approx \(dollars(imageInputCost)), max output approx \(dollars(maxOutputCost)); excludes OCR/prompt text input"
    }

    static func estimatedMediaTokens(for mediaResolution: String) -> Int {
        switch normalizedMediaResolution(mediaResolution) {
        case "MEDIA_RESOLUTION_LOW":
            return 280
        case "MEDIA_RESOLUTION_MEDIUM":
            return 560
        case "MEDIA_RESOLUTION_HIGH":
            return 1120
        default:
            return 1120
        }
    }

    static func tokenPricing(for model: String) -> (inputPerMillion: Double, outputPerMillion: Double)? {
        let lower = model.lowercased()
        if lower.contains("3.1-flash-lite") {
            return (0.25, 1.50)
        }
        if lower.contains("3-flash") {
            return (0.50, 3.00)
        }
        if lower.contains("2.5-flash-lite") {
            return (0.10, 0.40)
        }
        if lower.contains("2.5-flash") {
            return (0.30, 2.50)
        }
        return nil
    }

    static func dollars(_ value: Double) -> String {
        if value < 0.0001 {
            return String(format: "$%.6f", value)
        }
        return String(format: "$%.4f", value)
    }
}
