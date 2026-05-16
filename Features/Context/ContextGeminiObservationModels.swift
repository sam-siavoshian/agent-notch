//
//  ContextGeminiObservationModels.swift
//  Agent in the Notch
//
//  Structured screen observations produced from screenshot images. These
//  models stay feature-local until another feature needs a stable contract.
//

import Foundation

public struct ContextGeminiObservationInput: Sendable {
    public let jpegData: Data
    public let appName: String?
    public let windowTitle: String?
    public let width: Int?
    public let height: Int?
    public let recognizedText: [ContextRecognizedText]
    public let metadata: [String: String]

    public init(
        jpegData: Data,
        appName: String? = nil,
        windowTitle: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        recognizedText: [ContextRecognizedText] = [],
        metadata: [String: String] = [:]
    ) {
        self.jpegData = jpegData
        self.appName = appName
        self.windowTitle = windowTitle
        self.width = width
        self.height = height
        self.recognizedText = recognizedText
        self.metadata = metadata
    }
}

public struct ContextGeminiObservation: Codable, Sendable, Identifiable {
    public var id: String
    public var observedAt: Date
    public var source: Source
    public var model: String
    public var promptVersion: String
    public var imageHash: String
    public var appLabel: String
    public var windowTitle: String
    public var surfaceID: String
    public var surfaceLabel: String
    public var summary: String
    public var visibleControls: [VisibleControl]
    public var landmarks: [String]
    public var entities: [String]
    public var affordances: [String]
    public var uncertainty: [String]
    public var confidence: Double

    public enum Source: String, Codable, Sendable {
        case gemini
        case cache
    }

    public struct VisibleControl: Codable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var role: String
        public var region: String
        public var actionHint: String?
        public var confidence: Double

        public init(
            id: String = UUID().uuidString,
            label: String,
            role: String,
            region: String,
            actionHint: String? = nil,
            confidence: Double
        ) {
            self.id = id
            self.label = label
            self.role = role
            self.region = region
            self.actionHint = actionHint
            self.confidence = confidence
        }
    }
}

