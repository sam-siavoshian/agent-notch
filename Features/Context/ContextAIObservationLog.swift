//
//  ContextAIObservationLog.swift
//  Agent in the Notch
//
//  Prints AI observation events to stdout. Telemetry only — no disk writes.
//

import Foundation

public struct ContextAIObservationEvent: Sendable {
    public enum Provider: String, Sendable {
        case gemini
    }

    public enum Status: String, Sendable {
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
    public let controlsCount: Int
    public let affordancesCount: Int
    public let entitiesCount: Int
    /// Prefix into ContextGeminiCache/Debug/ for `*-prompt.txt` and
    /// `*-raw-response.json`. Used by the Dev Tools AI pane to lazily load
    /// the prompt + raw response for reducer events. Format: `<shortHash>-<slug>`.
    public let debugArtifactPrefix: String?

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
        controlsCount: Int = 0,
        affordancesCount: Int = 0,
        entitiesCount: Int = 0,
        debugArtifactPrefix: String? = nil
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
        self.controlsCount = controlsCount
        self.affordancesCount = affordancesCount
        self.entitiesCount = entitiesCount
        self.debugArtifactPrefix = debugArtifactPrefix
    }
}

public actor ContextAIObservationLog {
    public static let shared = ContextAIObservationLog()

    private let capacity = 200
    private var buffer: [ContextAIObservationEvent] = []

    public func record(_ event: ContextAIObservationEvent) {
        print("[INFO]  [gemini] \(Self.describe(event))")
        buffer.append(event)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    public func recentEvents(limit: Int = 50) -> [ContextAIObservationEvent] {
        let take = min(max(limit, 0), buffer.count)
        guard take > 0 else { return [] }
        return Array(buffer.suffix(take).reversed())
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
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
}

public actor ContextGeminiObservationGate {
    public struct PendingObservation: Sendable {
        public let snapshot: ContextSnapshot
        public let imageData: Data
        public let mimeType: String
        public let previousSnapshot: ContextSnapshot?
        public let attemptID: UUID
        public let enqueuedAt: Date

        public init(
            snapshot: ContextSnapshot,
            imageData: Data,
            mimeType: String,
            previousSnapshot: ContextSnapshot?,
            attemptID: UUID = UUID(),
            enqueuedAt: Date = Date()
        ) {
            self.snapshot = snapshot
            self.imageData = imageData
            self.mimeType = mimeType
            self.previousSnapshot = previousSnapshot
            self.attemptID = attemptID
            self.enqueuedAt = enqueuedAt
        }
    }

    public enum GateAction: Sendable {
        case run
        case queued(replacedSameApp: Bool)
        case skip(String)
    }

    public struct DrainResult: Sendable {
        public let next: PendingObservation?
        public let stale: [PendingObservation]
    }

    public let stalenessSeconds: TimeInterval
    private var inFlightCount = 0
    private var pendingByApp: [String: PendingObservation] = [:]
    private var pendingOrder: [String] = []

    public init(stalenessSeconds: TimeInterval = 12) {
        self.stalenessSeconds = stalenessSeconds
    }

    public func enqueueOrRun(
        _ observation: PendingObservation,
        isAPIKeyConfigured: Bool
    ) -> GateAction {
        let trigger = observation.snapshot.trigger

        guard trigger != .activation else {
            return .skip("activation capture stays OCR-only to protect long-press latency")
        }
        guard isAPIKeyConfigured else {
            return .skip("GEMINI_API_KEY is not configured")
        }

        if inFlightCount == 0 {
            inFlightCount = 1
            return .run
        }

        let appName = observation.snapshot.appName
        let replaced = pendingByApp[appName] != nil
        let isManual = trigger == .manual

        if !replaced {
            if isManual {
                pendingOrder.insert(appName, at: 0)
            } else {
                pendingOrder.append(appName)
            }
        } else if isManual, let idx = pendingOrder.firstIndex(of: appName), idx != 0 {
            pendingOrder.remove(at: idx)
            pendingOrder.insert(appName, at: 0)
        }
        pendingByApp[appName] = observation
        return .queued(replacedSameApp: replaced)
    }

    public func finishAndDrainNext(now: Date = Date()) -> DrainResult {
        inFlightCount = max(0, inFlightCount - 1)

        var stale: [PendingObservation] = []
        var next: PendingObservation? = nil

        while !pendingOrder.isEmpty {
            let appName = pendingOrder.removeFirst()
            guard let entry = pendingByApp.removeValue(forKey: appName) else {
                continue
            }
            if now.timeIntervalSince(entry.enqueuedAt) > stalenessSeconds {
                stale.append(entry)
                continue
            }
            next = entry
            break
        }

        if next != nil {
            inFlightCount = 1
        }
        return DrainResult(next: next, stale: stale)
    }
}
