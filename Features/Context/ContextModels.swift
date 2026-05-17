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
    public let isGatheringPaused: Bool

    public var summary: String {
        let state = isGatheringPaused ? "Paused" : "Live"

        guard snapshotCount > 0 else {
            return "\(state): no context captures yet."
        }

        let trigger = latestTrigger?.rawValue ?? "unknown"
        let window = latestWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled window" : latestWindowTitle
        return "\(state): \(snapshotCount) captures, \(latestRecognizedTextCount) OCR items. Latest: \(trigger) in \(latestAppName), \(window)."
    }
}

public struct ContextRecognizedText: Codable, Sendable {
    public let text: String
    public let confidence: Float
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}
