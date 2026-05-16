//
//  ContextGeminiObservationModels.swift
//  Agent in the Notch
//
//  Structured screen observations produced from screenshot images. These
//  models stay feature-local until another feature needs a stable contract.
//

import Foundation

public struct ContextGeminiObservationInput: Sendable {
    public let imageData: Data
    public let mimeType: String
    public let appName: String?
    public let windowTitle: String?
    public let width: Int?
    public let height: Int?
    public let recognizedText: [ContextRecognizedText]
    public let metadata: [String: String]

    public var jpegData: Data { imageData }

    public init(
        imageData: Data,
        mimeType: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        recognizedText: [ContextRecognizedText] = [],
        metadata: [String: String] = [:]
    ) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.appName = appName
        self.windowTitle = windowTitle
        self.width = width
        self.height = height
        self.recognizedText = recognizedText
        self.metadata = metadata
    }

    public init(
        jpegData: Data,
        appName: String? = nil,
        windowTitle: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        recognizedText: [ContextRecognizedText] = [],
        metadata: [String: String] = [:]
    ) {
        self.init(
            imageData: jpegData,
            mimeType: "image/jpeg",
            appName: appName,
            windowTitle: windowTitle,
            width: width,
            height: height,
            recognizedText: recognizedText,
            metadata: metadata
        )
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
    public var screenType: String
    public var primaryTask: String
    public var layoutSummary: String
    public var contentSummary: String
    public var visibleControls: [VisibleControl]
    public var landmarks: [String]
    public var entities: [String]
    public var affordances: [String]
    public var stateIndicators: [String]
    public var navigationPaths: [String]
    public var dataRegions: [String]
    public var workflowHints: [String]
    public var negativeCues: [String]
    public var memoryCandidates: [String]
    public var uncertainty: [String]
    public var confidence: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case observedAt
        case source
        case model
        case promptVersion
        case imageHash
        case appLabel
        case windowTitle
        case surfaceID
        case surfaceLabel
        case summary
        case screenType
        case primaryTask
        case layoutSummary
        case contentSummary
        case visibleControls
        case landmarks
        case entities
        case affordances
        case stateIndicators
        case navigationPaths
        case dataRegions
        case workflowHints
        case negativeCues
        case memoryCandidates
        case uncertainty
        case confidence
    }

    public init(
        id: String,
        observedAt: Date,
        source: Source,
        model: String,
        promptVersion: String,
        imageHash: String,
        appLabel: String,
        windowTitle: String,
        surfaceID: String,
        surfaceLabel: String,
        summary: String,
        screenType: String = "",
        primaryTask: String = "",
        layoutSummary: String = "",
        contentSummary: String = "",
        visibleControls: [VisibleControl],
        landmarks: [String],
        entities: [String],
        affordances: [String],
        stateIndicators: [String] = [],
        navigationPaths: [String] = [],
        dataRegions: [String] = [],
        workflowHints: [String] = [],
        negativeCues: [String] = [],
        memoryCandidates: [String] = [],
        uncertainty: [String],
        confidence: Double
    ) {
        self.id = id
        self.observedAt = observedAt
        self.source = source
        self.model = model
        self.promptVersion = promptVersion
        self.imageHash = imageHash
        self.appLabel = appLabel
        self.windowTitle = windowTitle
        self.surfaceID = surfaceID
        self.surfaceLabel = surfaceLabel
        self.summary = summary
        self.screenType = screenType
        self.primaryTask = primaryTask
        self.layoutSummary = layoutSummary
        self.contentSummary = contentSummary
        self.visibleControls = visibleControls
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
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        source = try container.decode(Source.self, forKey: .source)
        model = try container.decode(String.self, forKey: .model)
        promptVersion = try container.decode(String.self, forKey: .promptVersion)
        imageHash = try container.decode(String.self, forKey: .imageHash)
        appLabel = try container.decode(String.self, forKey: .appLabel)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        surfaceID = try container.decode(String.self, forKey: .surfaceID)
        surfaceLabel = try container.decode(String.self, forKey: .surfaceLabel)
        summary = try container.decode(String.self, forKey: .summary)
        screenType = try container.decodeIfPresent(String.self, forKey: .screenType) ?? ""
        primaryTask = try container.decodeIfPresent(String.self, forKey: .primaryTask) ?? ""
        layoutSummary = try container.decodeIfPresent(String.self, forKey: .layoutSummary) ?? ""
        contentSummary = try container.decodeIfPresent(String.self, forKey: .contentSummary) ?? ""
        visibleControls = try container.decodeIfPresent([VisibleControl].self, forKey: .visibleControls) ?? []
        landmarks = try container.decodeIfPresent([String].self, forKey: .landmarks) ?? []
        entities = try container.decodeIfPresent([String].self, forKey: .entities) ?? []
        affordances = try container.decodeIfPresent([String].self, forKey: .affordances) ?? []
        stateIndicators = try container.decodeIfPresent([String].self, forKey: .stateIndicators) ?? []
        navigationPaths = try container.decodeIfPresent([String].self, forKey: .navigationPaths) ?? []
        dataRegions = try container.decodeIfPresent([String].self, forKey: .dataRegions) ?? []
        workflowHints = try container.decodeIfPresent([String].self, forKey: .workflowHints) ?? []
        negativeCues = try container.decodeIfPresent([String].self, forKey: .negativeCues) ?? []
        memoryCandidates = try container.decodeIfPresent([String].self, forKey: .memoryCandidates) ?? []
        uncertainty = try container.decodeIfPresent([String].self, forKey: .uncertainty) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
    }

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
