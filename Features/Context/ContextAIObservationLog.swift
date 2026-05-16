//
//  ContextAIObservationLog.swift
//  Agent in the Notch
//
//  Local telemetry for screenshot-to-AI processing. This is the operator
//  console layer: which calls ran, which were skipped, how long they took,
//  and what useful UI facts they produced.
//

import Foundation

public struct ContextAIObservationEvent: Codable, Identifiable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case gemini
    }

    public enum Status: String, Codable, Sendable {
        case queued
        case skipped
        case completed
        case failed
    }

    public let id: UUID
    public let happenedAt: Date
    public let provider: Provider
    public let status: Status
    public let model: String
    public let promptVersion: String
    public let trigger: ContextCaptureTrigger
    public let appName: String
    public let windowTitle: String
    public let reason: String
    public let source: String?
    public let latencyMilliseconds: Int?
    public let confidence: Double?
    public let surfaceLabel: String?
    public let summary: String?
    public let controlsCount: Int
    public let affordancesCount: Int
    public let entitiesCount: Int

    public init(
        id: UUID = UUID(),
        happenedAt: Date = Date(),
        provider: Provider = .gemini,
        status: Status,
        model: String = ContextGeminiObservationService.defaultModel,
        promptVersion: String = ContextGeminiObservationService.promptVersion,
        trigger: ContextCaptureTrigger,
        appName: String,
        windowTitle: String,
        reason: String,
        source: String? = nil,
        latencyMilliseconds: Int? = nil,
        confidence: Double? = nil,
        surfaceLabel: String? = nil,
        summary: String? = nil,
        controlsCount: Int = 0,
        affordancesCount: Int = 0,
        entitiesCount: Int = 0
    ) {
        self.id = id
        self.happenedAt = happenedAt
        self.provider = provider
        self.status = status
        self.model = model
        self.promptVersion = promptVersion
        self.trigger = trigger
        self.appName = appName
        self.windowTitle = windowTitle
        self.reason = reason
        self.source = source
        self.latencyMilliseconds = latencyMilliseconds
        self.confidence = confidence
        self.surfaceLabel = surfaceLabel
        self.summary = summary
        self.controlsCount = controlsCount
        self.affordancesCount = affordancesCount
        self.entitiesCount = entitiesCount
    }
}

public struct ContextAIObservationSummary: Sendable {
    public let recentEventCount: Int
    public let queuedCount: Int
    public let skippedCount: Int
    public let completedLiveCount: Int
    public let completedCacheCount: Int
    public let failedCount: Int
    public let averageLatencyMilliseconds: Int?
    public let latestStatusLine: String

    public var statusLine: String {
        let latency = averageLatencyMilliseconds.map { ", avg \($0)ms" } ?? ""
        return "\(recentEventCount) events: \(queuedCount) queued, \(completedLiveCount) live, \(completedCacheCount) cached, \(skippedCount) skipped, \(failedCount) failed\(latency). \(latestStatusLine)"
    }
}

public actor ContextAIObservationLog {
    public static let shared = ContextAIObservationLog()

    public static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextAI", isDirectory: true)
    }

    private let directoryURL: URL
    private let eventsURL: URL
    private var events: [ContextAIObservationEvent] = []
    private var hasLoadedFromDisk = false

    public init(directoryURL: URL = ContextAIObservationLog.defaultDirectoryURL) {
        self.directoryURL = directoryURL
        self.eventsURL = directoryURL.appendingPathComponent("events.jsonl")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func record(_ event: ContextAIObservationEvent) {
        loadIfNeeded()
        events.append(event)
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
        append(event)
    }

    public func recentEvents(limit: Int = 30) -> [ContextAIObservationEvent] {
        loadIfNeeded()
        return Array(events.suffix(max(0, limit)).reversed())
    }

    public func summary(limit: Int = 80) -> ContextAIObservationSummary {
        loadIfNeeded()
        let recent = Array(events.suffix(limit))
        let queued = recent.filter { $0.status == .queued }.count
        let skipped = recent.filter { $0.status == .skipped }.count
        let failed = recent.filter { $0.status == .failed }.count
        let completed = recent.filter { $0.status == .completed }
        let live = completed.filter { $0.source == ContextGeminiObservation.Source.gemini.rawValue }.count
        let cache = completed.filter { $0.source == ContextGeminiObservation.Source.cache.rawValue }.count
        let latencies = completed.compactMap(\.latencyMilliseconds)
        let averageLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
        let latest = recent.last.map(Self.describe) ?? "No AI observations recorded yet."

        return ContextAIObservationSummary(
            recentEventCount: recent.count,
            queuedCount: queued,
            skippedCount: skipped,
            completedLiveCount: live,
            completedCacheCount: cache,
            failedCount: failed,
            averageLatencyMilliseconds: averageLatency,
            latestStatusLine: latest
        )
    }

    private func loadIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        guard let contents = try? String(contentsOf: eventsURL, encoding: .utf8) else { return }
        let loaded = contents
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ContextAIObservationEvent? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? Self.decoder.decode(ContextAIObservationEvent.self, from: data)
            }
        events = Array(loaded.suffix(200))
    }

    private func append(_ event: ContextAIObservationEvent) {
        do {
            let data = try Self.encoder.encode(event) + Data([0x0A])
            if FileManager.default.fileExists(atPath: eventsURL.path) {
                let handle = try FileHandle(forWritingTo: eventsURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: eventsURL, options: .atomic)
            }
        } catch {
            NSLog("[ContextAIObservationLog] Failed to append AI observation event: \(error)")
        }
    }

    public static func describe(_ event: ContextAIObservationEvent) -> String {
        let app = event.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? event.appName
            : "\(event.appName), \(event.windowTitle)"
        switch event.status {
        case .queued:
            return "Queued Gemini for \(app)."
        case .skipped:
            return "Skipped Gemini for \(app): \(event.reason)."
        case .completed:
            let source = event.source == ContextGeminiObservation.Source.cache.rawValue ? "cache" : "live"
            let latency = event.latencyMilliseconds.map { " in \($0)ms" } ?? ""
            let surface = event.surfaceLabel.map { " Surface: \($0)." } ?? ""
            return "Gemini \(source) completed\(latency).\(surface)"
        case .failed:
            return "Gemini failed for \(app): \(event.reason)."
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public actor ContextGeminiObservationGate {
    private let minimumAutomaticSpacingSeconds: TimeInterval
    private var lastAutomaticQueueAt: Date?
    private var inFlightCount = 0

    public init(minimumAutomaticSpacingSeconds: TimeInterval = 8) {
        self.minimumAutomaticSpacingSeconds = minimumAutomaticSpacingSeconds
    }

    public func startDecision(
        trigger: ContextCaptureTrigger,
        isAPIKeyConfigured: Bool,
        now: Date = Date()
    ) -> ContextGeminiObservationDecision {
        guard trigger != .activation else {
            return .skip("activation capture stays OCR-only to protect long-press latency")
        }

        guard isAPIKeyConfigured else {
            return .skip("GEMINI_API_KEY is not configured")
        }

        let isManual = trigger == .manual
        if inFlightCount > 0 && !isManual {
            return .skip("another Gemini observation is already running")
        }

        if !isManual, let lastAutomaticQueueAt {
            let elapsed = now.timeIntervalSince(lastAutomaticQueueAt)
            if elapsed < minimumAutomaticSpacingSeconds {
                return .skip("rate limited; last automatic Gemini call was \(Int(elapsed))s ago")
            }
        }

        inFlightCount += 1
        if !isManual {
            lastAutomaticQueueAt = now
        }
        return .run
    }

    public func finish() {
        inFlightCount = max(0, inFlightCount - 1)
    }
}

public enum ContextGeminiObservationDecision: Sendable {
    case run
    case skip(String)
}
