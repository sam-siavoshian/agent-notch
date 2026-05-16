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
    public let attemptID: UUID?
    public let happenedAt: Date
    public let provider: Provider
    public let status: Status
    public let laneName: String?
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
    public let screenType: String?
    public let primaryTask: String?
    public let layoutSummary: String?
    public let contentSummary: String?
    public let controls: [String]?
    public let landmarks: [String]?
    public let entities: [String]?
    public let affordances: [String]?
    public let stateIndicators: [String]?
    public let navigationPaths: [String]?
    public let dataRegions: [String]?
    public let workflowHints: [String]?
    public let negativeCues: [String]?
    public let memoryCandidates: [String]?
    public let uncertainty: [String]?
    public let imageBytes: Int?
    public let requestMimeType: String?
    public let requestMediaResolution: String?
    public let requestThinkingLevel: String?
    public let ocrCount: Int?
    public let imageHash: String?
    public let requestImagePath: String?
    public let requestMetadataPath: String?
    public let captureImagePath: String?
    public let captureJSONPath: String?
    public let promptPath: String?
    public let rawResponsePath: String?
    public let errorPath: String?
    public let controlsCount: Int
    public let affordancesCount: Int
    public let entitiesCount: Int

    public init(
        id: UUID = UUID(),
        happenedAt: Date = Date(),
        provider: Provider = .gemini,
        status: Status,
        model: String = ContextGeminiObservationService.configuredModel,
        promptVersion: String = ContextGeminiObservationService.promptVersion,
        trigger: ContextCaptureTrigger,
        appName: String,
        windowTitle: String,
        reason: String,
        attemptID: UUID? = nil,
        laneName: String? = nil,
        source: String? = nil,
        latencyMilliseconds: Int? = nil,
        confidence: Double? = nil,
        surfaceLabel: String? = nil,
        summary: String? = nil,
        screenType: String? = nil,
        primaryTask: String? = nil,
        layoutSummary: String? = nil,
        contentSummary: String? = nil,
        controls: [String]? = nil,
        landmarks: [String]? = nil,
        entities: [String]? = nil,
        affordances: [String]? = nil,
        stateIndicators: [String]? = nil,
        navigationPaths: [String]? = nil,
        dataRegions: [String]? = nil,
        workflowHints: [String]? = nil,
        negativeCues: [String]? = nil,
        memoryCandidates: [String]? = nil,
        uncertainty: [String]? = nil,
        imageBytes: Int? = nil,
        requestMimeType: String? = nil,
        requestMediaResolution: String? = nil,
        requestThinkingLevel: String? = nil,
        ocrCount: Int? = nil,
        imageHash: String? = nil,
        requestImagePath: String? = nil,
        requestMetadataPath: String? = nil,
        captureImagePath: String? = nil,
        captureJSONPath: String? = nil,
        promptPath: String? = nil,
        rawResponsePath: String? = nil,
        errorPath: String? = nil,
        controlsCount: Int = 0,
        affordancesCount: Int = 0,
        entitiesCount: Int = 0
    ) {
        self.id = id
        self.attemptID = attemptID
        self.happenedAt = happenedAt
        self.provider = provider
        self.status = status
        self.laneName = laneName
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
        self.screenType = screenType
        self.primaryTask = primaryTask
        self.layoutSummary = layoutSummary
        self.contentSummary = contentSummary
        self.controls = controls
        self.landmarks = landmarks
        self.entities = entities
        self.affordances = affordances
        self.stateIndicators = stateIndicators
        self.navigationPaths = navigationPaths
        self.dataRegions = dataRegions
        self.workflowHints = workflowHints
        self.negativeCues = negativeCues
        self.memoryCandidates = memoryCandidates
        self.uncertainty = uncertainty
        self.imageBytes = imageBytes
        self.requestMimeType = requestMimeType
        self.requestMediaResolution = requestMediaResolution
        self.requestThinkingLevel = requestThinkingLevel
        self.ocrCount = ocrCount
        self.imageHash = imageHash
        self.requestImagePath = requestImagePath
        self.requestMetadataPath = requestMetadataPath
        self.captureImagePath = captureImagePath
        self.captureJSONPath = captureJSONPath
        self.promptPath = promptPath
        self.rawResponsePath = rawResponsePath
        self.errorPath = errorPath
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
        let lane = event.laneName.map { " \($0)" } ?? ""
        switch event.status {
        case .queued:
            return "Queued Gemini\(lane) for \(app)."
        case .skipped:
            return "Skipped Gemini\(lane) for \(app): \(event.reason)."
        case .completed:
            let source = event.source == ContextGeminiObservation.Source.cache.rawValue ? "cache" : "live"
            let latency = event.latencyMilliseconds.map { " in \($0)ms" } ?? ""
            let surface = event.surfaceLabel.map { " Surface: \($0)." } ?? ""
            return "Gemini\(lane) \(source) completed\(latency).\(surface)"
        case .failed:
            return "Gemini\(lane) failed for \(app): \(event.reason)."
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
