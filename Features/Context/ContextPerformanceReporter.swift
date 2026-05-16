//
//  ContextPerformanceReporter.swift
//  Agent in the Notch
//
//  Local-only demo and benchmark reporting for Context memory artifacts and
//  Agent run metrics. This intentionally reads JSON defensively instead of
//  depending on exact Codable model shapes, so older artifacts can still be
//  summarized after the app changes.
//

import Foundation

public struct ContextPerformanceReporter {
    public let applicationSupportURL: URL

    private var contextMemoryURL: URL {
        applicationSupportURL.appendingPathComponent("ContextMemory", isDirectory: true)
    }

    private var appMemoriesURL: URL {
        contextMemoryURL.appendingPathComponent("Apps", isDirectory: true)
    }

    private var observationsURL: URL {
        contextMemoryURL.appendingPathComponent("observations.jsonl")
    }

    private var agentMetricsURL: URL {
        applicationSupportURL
            .appendingPathComponent("AgentMetrics", isDirectory: true)
            .appendingPathComponent("runs.jsonl")
    }

    public init(applicationSupportURL: URL = Self.defaultApplicationSupportURL()) {
        self.applicationSupportURL = applicationSupportURL
    }

    public static func defaultApplicationSupportURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
    }

    public func markdownReport(
        now: Date = Date(),
        recentRunLimit: Int = 5,
        recentObservationLimit: Int = 12
    ) -> String {
        let memorySummaries = loadMemorySummaries()
        let observationSummaries = loadObservationSummaries(limit: recentObservationLimit)
        let runSummaries = loadRunSummaries(limit: recentRunLimit)

        let totalSurfaces = memorySummaries.reduce(0) { $0 + $1.surfaceCount }
        let totalTransitions = memorySummaries.reduce(0) { $0 + $1.transitionCount }
        let totalNegativeNotes = memorySummaries.reduce(0) { $0 + $1.negativeNoteCount }
        let totalObservations = countJSONLLines(at: observationsURL)
        let totalRuns = countJSONLLines(at: agentMetricsURL)
        let latestOCRCount = observationSummaries.first?.ocrCount
        let latestOCRText = latestOCRCount.map(String.init) ?? "n/a"

        var lines: [String] = [
            "# Context Performance Report",
            "",
            "- Generated: \(formatDate(now))",
            "- Artifact root: `\(applicationSupportURL.path)`",
            "- App memories: \(memorySummaries.count) apps, \(totalSurfaces) surfaces, \(totalTransitions) transitions, \(totalNegativeNotes) caution notes",
            "- Captures observed: \(totalObservations) observation records, latest OCR count: \(latestOCRText)",
            "- Agent runs: \(totalRuns) metric records",
            "",
            "## App Memories"
        ]

        if memorySummaries.isEmpty {
            lines.append("- No app memory files found in `\(appMemoriesURL.path)`.")
        } else {
            for memory in memorySummaries.prefix(8) {
                lines.append("- \(memory.appName): \(memory.surfaceCount) surfaces, \(memory.observationCount) observations, \(memory.clickCount) clicks, last seen \(formatDate(memory.lastSeen))")
            }
        }

        lines.append("")
        lines.append("## Recent Captures")
        if observationSummaries.isEmpty {
            lines.append("- No observation records found in `\(observationsURL.path)`.")
        } else {
            for observation in observationSummaries {
                let window = observation.windowTitle.isEmpty ? "Untitled window" : observation.windowTitle
                lines.append("- \(formatDate(observation.capturedAt)): \(observation.trigger) in \(observation.appName), \(window) | OCR \(observation.ocrCount) | \(observation.width)x\(observation.height)")
            }
        }

        lines.append("")
        lines.append("## Recent Agent Runs")
        if runSummaries.isEmpty {
            lines.append("- No agent run metrics found in `\(agentMetricsURL.path)`.")
        } else {
            for run in runSummaries {
                let fallback = run.usedFallback ? ", fallback" : ""
                let firstAction = run.timeToFirstNonScreenshotActionMs.map { ", first action \($0)ms" } ?? ""
                lines.append("- \(formatDate(run.startedAt)): \(run.finalStatus), \(run.durationMs)ms, \(run.toolCallCount) tools, \(run.screenshotToolCallCount) screenshots, context \(run.contextLength) chars\(firstAction)\(fallback)")
                if !run.topActions.isEmpty {
                    lines.append("  Actions: \(run.topActions.joined(separator: ", "))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    public func writeMarkdownReport(
        to outputURL: URL,
        now: Date = Date(),
        recentRunLimit: Int = 5,
        recentObservationLimit: Int = 12
    ) throws {
        let report = markdownReport(
            now: now,
            recentRunLimit: recentRunLimit,
            recentObservationLimit: recentObservationLimit
        )
        try report.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func loadMemorySummaries() -> [MemorySummary] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: appMemoriesURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(loadMemorySummary)
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    private func loadMemorySummary(from url: URL) -> MemorySummary? {
        guard let object = loadJSONObject(at: url) else { return nil }
        let surfaces = object.arrayValue("surfaces")
        let transitions = object.arrayValue("transitions")
        let negativeNotes = object.arrayValue("negativeNotes")

        let observationCount = surfaces.reduce(0) { total, surface in
            total + surface.intValue("observationCount")
        }
        let clickCount = surfaces.reduce(0) { total, surface in
            total + surface.intValue("clickCount")
        }

        return MemorySummary(
            appName: object.stringValue("appName", fallback: url.deletingPathExtension().lastPathComponent),
            lastSeen: object.dateValue("lastSeen") ?? .distantPast,
            surfaceCount: surfaces.count,
            transitionCount: transitions.count,
            negativeNoteCount: negativeNotes.count,
            observationCount: observationCount,
            clickCount: clickCount
        )
    }

    private func loadObservationSummaries(limit: Int) -> [ObservationSummary] {
        recentJSONLLines(at: observationsURL, limit: limit)
            .compactMap { line in
                guard let object = parseJSONObject(line) else { return nil }
                let recognizedText = object.arrayValue("recognizedText")
                return ObservationSummary(
                    capturedAt: object.dateValue("capturedAt") ?? .distantPast,
                    trigger: object.stringValue("trigger", fallback: "unknown"),
                    appName: object.stringValue("appName", fallback: "Unknown app"),
                    windowTitle: object.stringValue("windowTitle", fallback: ""),
                    ocrCount: recognizedText.count,
                    width: object.intValue("width"),
                    height: object.intValue("height")
                )
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    private func loadRunSummaries(limit: Int) -> [RunSummary] {
        recentJSONLLines(at: agentMetricsURL, limit: limit)
            .compactMap { line in
                guard let object = parseJSONObject(line) else { return nil }
                return RunSummary(
                    startedAt: object.dateValue("startedAt") ?? .distantPast,
                    durationMs: object.intValue("durationMs"),
                    contextLength: object.intValue("contextLength"),
                    toolCallCount: object.intValue("toolCallCount"),
                    screenshotToolCallCount: object.intValue("screenshotToolCallCount"),
                    usedFallback: object.boolValue("usedFallback"),
                    timeToFirstNonScreenshotActionMs: object.optionalIntValue("timeToFirstNonScreenshotActionMs"),
                    finalStatus: object.stringValue("finalStatus", fallback: "unknown"),
                    topActions: topActions(from: object.dictionaryValue("actionCounts"))
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func loadJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func recentJSONLLines(at url: URL, limit: Int) -> [String] {
        guard limit > 0, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        let lines = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return Array(lines.suffix(limit))
    }

    private func countJSONLLines(at url: URL) -> Int {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }

        return contents
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private func topActions(from counts: [String: Any]) -> [String] {
        counts
            .compactMap { key, value -> (String, Int)? in
                if let intValue = value as? Int {
                    return (key, intValue)
                }
                if let number = value as? NSNumber {
                    return (key, number.intValue)
                }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 > rhs.1
            }
            .prefix(4)
            .map { "\($0.0) \($0.1)" }
    }

    private func formatDate(_ date: Date) -> String {
        guard date > .distantPast else { return "unknown" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct MemorySummary {
    let appName: String
    let lastSeen: Date
    let surfaceCount: Int
    let transitionCount: Int
    let negativeNoteCount: Int
    let observationCount: Int
    let clickCount: Int
}

private struct ObservationSummary {
    let capturedAt: Date
    let trigger: String
    let appName: String
    let windowTitle: String
    let ocrCount: Int
    let width: Int
    let height: Int
}

private struct RunSummary {
    let startedAt: Date
    let durationMs: Int
    let contextLength: Int
    let toolCallCount: Int
    let screenshotToolCallCount: Int
    let usedFallback: Bool
    let timeToFirstNonScreenshotActionMs: Int?
    let finalStatus: String
    let topActions: [String]
}

private extension Dictionary where Key == String, Value == Any {
    func stringValue(_ key: String, fallback: String) -> String {
        self[key] as? String ?? fallback
    }

    func intValue(_ key: String) -> Int {
        optionalIntValue(key) ?? 0
    }

    func optionalIntValue(_ key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    func boolValue(_ key: String) -> Bool {
        if let value = self[key] as? Bool {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.boolValue
        }
        return false
    }

    func arrayValue(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }

    func dictionaryValue(_ key: String) -> [String: Any] {
        self[key] as? [String: Any] ?? [:]
    }

    func dateValue(_ key: String) -> Date? {
        guard let value = self[key] as? String else { return nil }
        return ContextPerformanceDateParser.date(from: value)
    }
}

private enum ContextPerformanceDateParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}
