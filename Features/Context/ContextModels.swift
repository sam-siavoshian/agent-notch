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

    public init(appName: String, firstSeen: Date, lastSeen: Date) {
        self.appName = appName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.surfaces = []
        self.transitions = []
        self.negativeNotes = []
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
        uncertaintyHighlights: [String] = []
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
