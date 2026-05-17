//
//  ContextModels.swift
//  Agent in the Notch
//
//  Native context data produced by the macOS app. Keep this feature-local
//  until another feature needs a stable shared type.
//

import Foundation
import CoreGraphics

public enum ContextCaptureTrigger: String, Codable, Sendable {
    case startup
    case click
    case activation
    case manual
    case appSwitch
}

public struct ContextSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let trigger: ContextCaptureTrigger
    public let appName: String
    public let windowTitle: String
    public let cursorLocation: CGPoint?
    public let jpegData: Data
    public let width: Int
    public let height: Int
    public let recognizedText: [ContextRecognizedText]

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        trigger: ContextCaptureTrigger,
        appName: String,
        windowTitle: String,
        cursorLocation: CGPoint?,
        jpegData: Data,
        width: Int,
        height: Int,
        recognizedText: [ContextRecognizedText] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.appName = appName
        self.windowTitle = windowTitle
        self.cursorLocation = cursorLocation
        self.jpegData = jpegData
        self.width = width
        self.height = height
        self.recognizedText = recognizedText
    }
}

public struct ContextWindowMetadata: Sendable {
    public let appName: String
    public let windowTitle: String
}

public struct ContextDiagnostics: Sendable {
    public let snapshotCount: Int
    public let latestAppName: String
    public let latestWindowTitle: String
    public let latestTrigger: ContextCaptureTrigger?
    public let latestRecognizedTextCount: Int
    public let hasLearnedMemory: Bool
    public let isGatheringPaused: Bool

    public var summary: String {
        let state = isGatheringPaused ? "Paused" : "Live"

        guard snapshotCount > 0 else {
            return "\(state): no context captures yet."
        }

        let trigger = latestTrigger?.rawValue ?? "unknown"
        let window = latestWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled window" : latestWindowTitle
        let memory = hasLearnedMemory ? "memory ready" : "memory warming"
        return "\(state): \(snapshotCount) captures, \(latestRecognizedTextCount) OCR items, \(memory). Latest: \(trigger) in \(latestAppName), \(window)."
    }
}

public struct ContextDebugSnapshot: Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let trigger: ContextCaptureTrigger
    public let appName: String
    public let windowTitle: String
    public let jpegData: Data
    public let recognizedTextCount: Int
    public let textPreview: String
}

public struct ContextRecognizedText: Codable, Sendable {
    public let text: String
    public let confidence: Float
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct ContextActivationPacket: Sendable {
    public let generatedAt: Date
    public let capturedCount: Int
    public let elapsedSeconds: Int
    public let currentApp: String
    public let currentWindow: String
    public let recentTimeline: [String]
    public let observedTransitions: [String]
    public let learnedUIMemory: String
    public let firstActionGuidance: [String]

    public var promptText: String {
        let screenFacts = recentTimeline.isEmpty ? "- Current screenshot has no useful OCR text yet." : recentTimeline.joined(separator: "\n")
        let interactions = observedTransitions.isEmpty ? "- No useful recent interaction signal beyond the current screen." : observedTransitions.joined(separator: "\n")
        let memory = learnedUIMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "- No learned UI memory for this app yet." : learnedUIMemory
        let guidance = firstActionGuidance.isEmpty ? "- Use the live screen as ground truth." : firstActionGuidance.joined(separator: "\n")

        return """
        Local UI context:

        Current screen:
        - App: \(currentApp)
        - Window: \(currentWindow)
        \(screenFacts)

        Recent interaction signal:
        \(interactions)

        Learned UI memory:
        \(memory)

        How to use this:
        \(guidance)
        """
    }
}

public struct ContextAppMemory: Codable, Sendable {
    public var appName: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var surfaces: [ContextSurfaceMemory]
    public var transitions: [ContextTransitionMemory]
    public var negativeNotes: [ContextNegativeMemory]
    public var current: ContextCurrentWorkMemory?
    public var recent: [ContextRecentActivityEntry]
    public var entities: [ContextEntityMemory]
    public var habits: ContextHabitMemory
    public var recipes: [ContextTaskRecipe]

    public var ui: ContextUIMemory {
        get { ContextUIMemory(surfaces: surfaces) }
        set { surfaces = newValue.surfaces }
    }

    public init(appName: String, firstSeen: Date, lastSeen: Date) {
        self.appName = appName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.surfaces = []
        self.transitions = []
        self.negativeNotes = []
        self.current = nil
        self.recent = []
        self.entities = []
        self.habits = ContextHabitMemory()
        self.recipes = []
    }

    private enum CodingKeys: String, CodingKey {
        case appName
        case firstSeen
        case lastSeen
        case surfaces
        case transitions
        case negativeNotes
        case current
        case recent
        case entities
        case habits
        case recipes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appName = try container.decode(String.self, forKey: .appName)
        self.firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        self.lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        self.surfaces = try container.decodeIfPresent([ContextSurfaceMemory].self, forKey: .surfaces) ?? []
        self.transitions = try container.decodeIfPresent([ContextTransitionMemory].self, forKey: .transitions) ?? []
        self.negativeNotes = try container.decodeIfPresent([ContextNegativeMemory].self, forKey: .negativeNotes) ?? []
        self.current = try container.decodeIfPresent(ContextCurrentWorkMemory.self, forKey: .current)
        self.recent = try container.decodeIfPresent([ContextRecentActivityEntry].self, forKey: .recent) ?? []
        self.entities = try container.decodeIfPresent([ContextEntityMemory].self, forKey: .entities) ?? []
        self.habits = try container.decodeIfPresent(ContextHabitMemory.self, forKey: .habits) ?? ContextHabitMemory()
        self.recipes = try container.decodeIfPresent([ContextTaskRecipe].self, forKey: .recipes) ?? []
    }
}

public struct ContextTaskRecipe: Codable, Identifiable, Sendable {
    public var id: String
    public var appKey: String
    public var fromSurfaceID: String
    public var name: String
    public var intentKeywords: [String]
    public var stepsProse: [String]
    public var evidenceCount: Int
    public var firstSeen: Date
    public var lastUsed: Date
    public var confidence: Double

    public init(
        id: String,
        appKey: String,
        fromSurfaceID: String,
        name: String,
        intentKeywords: [String],
        stepsProse: [String],
        evidenceCount: Int,
        firstSeen: Date,
        lastUsed: Date,
        confidence: Double
    ) {
        self.id = id
        self.appKey = appKey
        self.fromSurfaceID = fromSurfaceID
        self.name = name
        self.intentKeywords = intentKeywords
        self.stepsProse = stepsProse
        self.evidenceCount = evidenceCount
        self.firstSeen = firstSeen
        self.lastUsed = lastUsed
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case id, appKey, fromSurfaceID, name, intentKeywords, stepsProse, evidenceCount, firstSeen, lastUsed, confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.appKey = try container.decodeIfPresent(String.self, forKey: .appKey) ?? ""
        self.fromSurfaceID = try container.decodeIfPresent(String.self, forKey: .fromSurfaceID) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.intentKeywords = try container.decodeIfPresent([String].self, forKey: .intentKeywords) ?? []
        self.stepsProse = try container.decodeIfPresent([String].self, forKey: .stepsProse) ?? []
        self.evidenceCount = try container.decodeIfPresent(Int.self, forKey: .evidenceCount) ?? 0
        let now = Date()
        self.firstSeen = try container.decodeIfPresent(Date.self, forKey: .firstSeen) ?? now
        self.lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed) ?? now
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }
}

public struct ContextUIMemory: Codable, Sendable {
    public var surfaces: [ContextSurfaceMemory]

    public init(surfaces: [ContextSurfaceMemory] = []) {
        self.surfaces = surfaces
    }
}

public struct ContextCurrentWorkMemory: Codable, Sendable {
    public var updatedAt: Date
    public var app: String
    public var surfaceID: String
    public var surfaceTitle: String
    public var task: String
    public var topEntities: [String]

    public init(
        updatedAt: Date,
        app: String,
        surfaceID: String,
        surfaceTitle: String,
        task: String,
        topEntities: [String]
    ) {
        self.updatedAt = updatedAt
        self.app = app
        self.surfaceID = surfaceID
        self.surfaceTitle = surfaceTitle
        self.task = task
        self.topEntities = topEntities
    }
}

public struct ContextRecentActivityEntry: Codable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var app: String
    public var surfaceID: String
    public var surfaceTitle: String
    public var summary: String
    public var trigger: ContextCaptureTrigger

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        app: String,
        surfaceID: String,
        surfaceTitle: String,
        summary: String,
        trigger: ContextCaptureTrigger
    ) {
        self.id = id
        self.timestamp = timestamp
        self.app = app
        self.surfaceID = surfaceID
        self.surfaceTitle = surfaceTitle
        self.summary = summary
        self.trigger = trigger
    }
}

public struct ContextHabitMemory: Codable, Sendable {
    public var totalVisits: Int
    public var totalDwellMs: Int
    public var topSurfaces: [ContextSurfaceCount]
    public var commonTransitions: [ContextTransitionCount]
    public var timeOfDayBuckets: [String: Int]

    public init(
        totalVisits: Int = 0,
        totalDwellMs: Int = 0,
        topSurfaces: [ContextSurfaceCount] = [],
        commonTransitions: [ContextTransitionCount] = [],
        timeOfDayBuckets: [String: Int] = [:]
    ) {
        self.totalVisits = totalVisits
        self.totalDwellMs = totalDwellMs
        self.topSurfaces = topSurfaces
        self.commonTransitions = commonTransitions
        self.timeOfDayBuckets = timeOfDayBuckets
    }
}

public struct ContextSurfaceCount: Codable, Sendable {
    public var surfaceID: String
    public var title: String
    public var count: Int

    public init(surfaceID: String, title: String, count: Int) {
        self.surfaceID = surfaceID
        self.title = title
        self.count = count
    }
}

public struct ContextTransitionCount: Codable, Sendable {
    public var fromSurfaceID: String
    public var toSurfaceID: String
    public var fromTitle: String
    public var toTitle: String
    public var count: Int

    public init(
        fromSurfaceID: String,
        toSurfaceID: String,
        fromTitle: String,
        toTitle: String,
        count: Int
    ) {
        self.fromSurfaceID = fromSurfaceID
        self.toSurfaceID = toSurfaceID
        self.fromTitle = fromTitle
        self.toTitle = toTitle
        self.count = count
    }
}

public struct ContextSurfaceMemory: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var observationCount: Int
    public var clickCount: Int
    public var activationCount: Int
    public var textHighlights: [String]
    public var semanticHighlights: [String]
    public var controlHighlights: [String]
    public var affordanceHighlights: [String]
    public var uncertaintyHighlights: [String]
    public var facts: [ContextMemoryFact]
    public var controls: [ContextControlMemory]
    public var entities: [ContextEntityMemory]
    public var fingerprintTokens: [String]
    public var surfaceFingerprint: String
    public var description: String
    public var fingerprintRefreshedAt: Date

    public init(
        id: String,
        title: String,
        firstSeen: Date,
        lastSeen: Date,
        observationCount: Int,
        clickCount: Int,
        activationCount: Int,
        textHighlights: [String] = [],
        semanticHighlights: [String] = [],
        controlHighlights: [String] = [],
        affordanceHighlights: [String] = [],
        uncertaintyHighlights: [String] = [],
        facts: [ContextMemoryFact] = [],
        controls: [ContextControlMemory] = [],
        entities: [ContextEntityMemory] = [],
        fingerprintTokens: [String] = [],
        surfaceFingerprint: String = "",
        description: String = "",
        fingerprintRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.observationCount = observationCount
        self.clickCount = clickCount
        self.activationCount = activationCount
        self.textHighlights = textHighlights
        self.semanticHighlights = semanticHighlights
        self.controlHighlights = controlHighlights
        self.affordanceHighlights = affordanceHighlights
        self.uncertaintyHighlights = uncertaintyHighlights
        self.facts = facts
        self.controls = controls
        self.entities = entities
        self.fingerprintTokens = fingerprintTokens
        self.surfaceFingerprint = surfaceFingerprint
        self.description = description
        self.fingerprintRefreshedAt = fingerprintRefreshedAt ?? firstSeen
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case firstSeen
        case lastSeen
        case observationCount
        case clickCount
        case activationCount
        case textHighlights
        case semanticHighlights
        case controlHighlights
        case affordanceHighlights
        case uncertaintyHighlights
        case facts
        case controls
        case entities
        case fingerprintTokens
        case surfaceFingerprint
        case description
        case fingerprintRefreshedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        self.lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        self.observationCount = try container.decode(Int.self, forKey: .observationCount)
        self.clickCount = try container.decode(Int.self, forKey: .clickCount)
        self.activationCount = try container.decode(Int.self, forKey: .activationCount)
        self.textHighlights = try container.decodeIfPresent([String].self, forKey: .textHighlights) ?? []
        self.semanticHighlights = try container.decodeIfPresent([String].self, forKey: .semanticHighlights) ?? []
        self.controlHighlights = try container.decodeIfPresent([String].self, forKey: .controlHighlights) ?? []
        self.affordanceHighlights = try container.decodeIfPresent([String].self, forKey: .affordanceHighlights) ?? []
        self.uncertaintyHighlights = try container.decodeIfPresent([String].self, forKey: .uncertaintyHighlights) ?? []
        self.facts = try container.decodeIfPresent([ContextMemoryFact].self, forKey: .facts) ?? []
        self.controls = try container.decodeIfPresent([ContextControlMemory].self, forKey: .controls) ?? []
        self.entities = try container.decodeIfPresent([ContextEntityMemory].self, forKey: .entities) ?? []
        self.fingerprintTokens = try container.decodeIfPresent([String].self, forKey: .fingerprintTokens) ?? []
        self.surfaceFingerprint = try container.decodeIfPresent(String.self, forKey: .surfaceFingerprint) ?? ""
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.fingerprintRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .fingerprintRefreshedAt) ?? self.firstSeen
    }
}

public struct ContextMemoryFact: Codable, Identifiable, Sendable {
    public var id: String
    public var category: String
    public var text: String
    public var durability: String
    public var source: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var evidenceCount: Int
    public var confidence: Double
}

public struct ContextControlMemory: Codable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var role: String
    public var region: String
    public var actionHint: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var evidenceCount: Int
    public var confidence: Double
    public var verbPhrase: String

    public init(
        id: String,
        label: String,
        role: String,
        region: String,
        actionHint: String,
        firstSeen: Date,
        lastSeen: Date,
        evidenceCount: Int,
        confidence: Double,
        verbPhrase: String = ""
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.region = region
        self.actionHint = actionHint
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.evidenceCount = evidenceCount
        self.confidence = confidence
        self.verbPhrase = verbPhrase
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, role, region, actionHint, firstSeen, lastSeen, evidenceCount, confidence, verbPhrase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.role = try container.decode(String.self, forKey: .role)
        self.region = try container.decode(String.self, forKey: .region)
        self.actionHint = try container.decode(String.self, forKey: .actionHint)
        self.firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        self.lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        self.evidenceCount = try container.decode(Int.self, forKey: .evidenceCount)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.verbPhrase = try container.decodeIfPresent(String.self, forKey: .verbPhrase) ?? ""
    }
}

public struct ContextEntityMemory: Codable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var source: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var evidenceCount: Int
    public var confidence: Double
    public var label: String
    public var type: String
    public var mentionCount: Int
    public var surfaces: [String]

    public init(
        id: String,
        text: String,
        source: String,
        firstSeen: Date,
        lastSeen: Date,
        evidenceCount: Int,
        confidence: Double,
        label: String = "",
        type: String = "entity",
        mentionCount: Int = 1,
        surfaces: [String] = []
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.evidenceCount = evidenceCount
        self.confidence = confidence
        self.label = label.isEmpty ? text : label
        self.type = type
        self.mentionCount = mentionCount
        self.surfaces = surfaces
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case source
        case firstSeen
        case lastSeen
        case evidenceCount
        case confidence
        case label
        case type
        case mentionCount
        case surfaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.source = try container.decode(String.self, forKey: .source)
        self.firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        self.lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        self.evidenceCount = try container.decode(Int.self, forKey: .evidenceCount)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? self.text
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "entity"
        self.mentionCount = try container.decodeIfPresent(Int.self, forKey: .mentionCount) ?? self.evidenceCount
        self.surfaces = try container.decodeIfPresent([String].self, forKey: .surfaces) ?? []
    }
}

public struct ContextTransitionMemory: Codable, Identifiable, Sendable {
    public var id: String
    public var fromSurfaceID: String
    public var fromTitle: String
    public var toSurfaceID: String
    public var toTitle: String
    public var trigger: ContextCaptureTrigger
    public var firstSeen: Date
    public var lastSeen: Date
    public var evidenceCount: Int
}

public struct ContextNegativeMemory: Codable, Identifiable, Sendable {
    public var id: String
    public var surfaceID: String
    public var surfaceTitle: String
    public var note: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var evidenceCount: Int
}

public struct ContextMemoryObservationRecord: Codable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let trigger: ContextCaptureTrigger
    public let appName: String
    public let windowTitle: String
    public let surfaceID: String
    public let recognizedText: [String]
    public let cursorX: Int?
    public let cursorY: Int?
    public let width: Int
    public let height: Int
}
