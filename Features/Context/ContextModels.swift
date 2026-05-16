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

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        trigger: ContextCaptureTrigger,
        appName: String,
        windowTitle: String,
        cursorLocation: CGPoint?,
        jpegData: Data,
        width: Int,
        height: Int
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
    }
}

public struct ContextWindowMetadata: Sendable {
    public let appName: String
    public let windowTitle: String
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
        let timeline = recentTimeline.isEmpty ? "- No recent captures." : recentTimeline.joined(separator: "\n")
        let transitions = observedTransitions.isEmpty ? "- No window/app transitions observed yet." : observedTransitions.joined(separator: "\n")
        let memory = learnedUIMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "- No durable UI memory for this app yet." : learnedUIMemory
        let guidance = firstActionGuidance.isEmpty ? "- Use the computer screenshot tool before acting if the screen is ambiguous." : firstActionGuidance.joined(separator: "\n")

        return """
        Activation context packet:
        Captures: \(capturedCount) over \(elapsedSeconds)s.
        Current app: \(currentApp)
        Current window: \(currentWindow)

        Recent screen timeline:
        \(timeline)

        Learned navigation hints from recent use:
        \(transitions)

        Learned UI memory for current app:
        \(memory)

        First-action guidance:
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
    public let cursorX: Int?
    public let cursorY: Int?
    public let width: Int
    public let height: Int
}
