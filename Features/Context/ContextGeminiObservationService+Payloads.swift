//
//  ContextGeminiObservationService+Payloads.swift
//  Agent in the Notch
//

import Foundation

// MARK: - Error

extension ContextGeminiObservationService {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let status: Int?
        public let body: String?
        public let underlying: (any Swift.Error)?

        public var description: String {
            "ContextGeminiObservationService.Error(status: \(status.map(String.init) ?? "nil"), body: \(body ?? "nil"), underlying: \(underlying.map { "\($0)" } ?? "nil"))"
        }

        /// True for transient failures worth retrying once: network errors and 5xx server errors.
        /// 4xx client errors (bad key, bad request) are not retried — they won't self-heal.
        var isRetryable: Bool {
            guard let status else { return true }  // nil = URLSession/network failure
            return status >= 500
        }
    }
}

// MARK: - JSON Payload Types (Gemini response decoding)

struct ObservationPayload: Decodable {
    var appLabel: String?
    var windowTitle: String?
    var surfaceID: String?
    var surfaceLabel: String?
    var summary: String?
    var screenType: String?
    var primaryTask: String?
    var layoutSummary: String?
    var contentSummary: String?
    var visibleControls: [ControlPayload]
    var landmarks: [String]
    var entities: [String]
    var affordances: [String]
    var stateIndicators: [String]
    var navigationPaths: [String]
    var dataRegions: [String]
    var workflowHints: [String]
    var negativeCues: [String]
    var memoryCandidates: [String]
    var uncertainty: [String]
    var confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case appLabel
        case app
        case windowTitle
        case surfaceID
        case surfaceId
        case surfaceLabel
        case summary
        case screenType
        case primaryTask
        case layoutSummary
        case contentSummary
        case visibleControls
        case landmarks
        case entities
        case visibleEntities
        case affordances
        case likelyAffordances
        case stateIndicators
        case navigationPaths
        case dataRegions
        case workflowHints
        case negativeCues
        case memoryCandidates
        case uncertainty
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appLabel = try container.decodeIfPresent(String.self, forKey: .appLabel)
            ?? container.decodeIfPresent(String.self, forKey: .app)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
            ?? container.decodeIfPresent(String.self, forKey: .surfaceId)
        surfaceLabel = try container.decodeIfPresent(String.self, forKey: .surfaceLabel)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        screenType = try container.decodeIfPresent(String.self, forKey: .screenType)
        primaryTask = try container.decodeIfPresent(String.self, forKey: .primaryTask)
        layoutSummary = try container.decodeIfPresent(String.self, forKey: .layoutSummary)
        contentSummary = try container.decodeIfPresent(String.self, forKey: .contentSummary)
        visibleControls = try container.decodeIfPresent([ControlPayload].self, forKey: .visibleControls) ?? []
        landmarks = try container.decodeStringArrayIfPresent(forKey: .landmarks)
        entities = try container.decodeStringArrayIfPresent(forKey: .entities)
        if entities.isEmpty {
            entities = try container.decodeStringArrayIfPresent(forKey: .visibleEntities)
        }
        affordances = try container.decodeStringArrayIfPresent(forKey: .affordances)
        if affordances.isEmpty {
            affordances = try container.decodeStringArrayIfPresent(forKey: .likelyAffordances)
        }
        stateIndicators = try container.decodeStringArrayIfPresent(forKey: .stateIndicators)
        navigationPaths = try container.decodeStringArrayIfPresent(forKey: .navigationPaths)
        dataRegions = try container.decodeStringArrayIfPresent(forKey: .dataRegions)
        workflowHints = try container.decodeStringArrayIfPresent(forKey: .workflowHints)
        negativeCues = try container.decodeStringArrayIfPresent(forKey: .negativeCues)
        memoryCandidates = try container.decodeStringArrayIfPresent(forKey: .memoryCandidates)
        uncertainty = try container.decodeStringArrayIfPresent(forKey: .uncertainty)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

struct LaneObservationPayload: Decodable {
    var appLabel: String?
    var windowTitle: String?
    var surfaceID: String?
    var surfaceLabel: String?
    var screenType: String?
    var summary: String?
    var primaryTask: String?
    var contentSummary: String?
    var layoutRegions: [String]
    var controls: [ControlPayload]
    var entities: [String]
    var stateIndicators: [String]
    var workflows: [String]
    var navigation: [String]
    var negativeCues: [String]
    var memoryCards: [String]
    var uncertainty: [String]
    var confidence: Double?

    private enum CodingKeys: String, CodingKey {
        case appLabel
        case app
        case windowTitle
        case surfaceID
        case surfaceId
        case surfaceLabel
        case screenType
        case summary
        case primaryTask
        case contentSummary
        case layoutRegions
        case landmarks
        case controls
        case visibleControls
        case entities
        case visibleEntities
        case stateIndicators
        case workflows
        case workflowHints
        case navigation
        case navigationPaths
        case negativeCues
        case memoryCards
        case memoryCandidates
        case uncertainty
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appLabel = try container.decodeIfPresent(String.self, forKey: .appLabel)
            ?? container.decodeIfPresent(String.self, forKey: .app)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
            ?? container.decodeIfPresent(String.self, forKey: .surfaceId)
        surfaceLabel = try container.decodeIfPresent(String.self, forKey: .surfaceLabel)
        screenType = try container.decodeIfPresent(String.self, forKey: .screenType)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        primaryTask = try container.decodeIfPresent(String.self, forKey: .primaryTask)
        contentSummary = try container.decodeIfPresent(String.self, forKey: .contentSummary)
        layoutRegions = try container.decodeStringArrayIfPresent(forKey: .layoutRegions)
        if layoutRegions.isEmpty {
            layoutRegions = try container.decodeStringArrayIfPresent(forKey: .landmarks)
        }
        controls = try container.decodeIfPresent([ControlPayload].self, forKey: .controls)
            ?? container.decodeIfPresent([ControlPayload].self, forKey: .visibleControls)
            ?? []
        entities = try container.decodeStringArrayIfPresent(forKey: .entities)
        if entities.isEmpty {
            entities = try container.decodeStringArrayIfPresent(forKey: .visibleEntities)
        }
        stateIndicators = try container.decodeStringArrayIfPresent(forKey: .stateIndicators)
        workflows = try container.decodeStringArrayIfPresent(forKey: .workflows)
        if workflows.isEmpty {
            workflows = try container.decodeStringArrayIfPresent(forKey: .workflowHints)
        }
        navigation = try container.decodeStringArrayIfPresent(forKey: .navigation)
        if navigation.isEmpty {
            navigation = try container.decodeStringArrayIfPresent(forKey: .navigationPaths)
        }
        negativeCues = try container.decodeStringArrayIfPresent(forKey: .negativeCues)
        memoryCards = try container.decodeStringArrayIfPresent(forKey: .memoryCards)
        if memoryCards.isEmpty {
            memoryCards = try container.decodeStringArrayIfPresent(forKey: .memoryCandidates)
        }
        uncertainty = try container.decodeStringArrayIfPresent(forKey: .uncertainty)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

// MARK: - Debug Paths

public struct ContextGeminiDebugPaths: Sendable {
    public let imageHash: String
    public let requestImagePath: String
    public let requestMetadataPath: String
    public let promptPath: String
    public let rawResponsePath: String
    public let errorPath: String
}

// MARK: - Request Configuration

struct GeminiObservationRequestConfig: Sendable {
    let mediaResolution: String
    let thinkingLevel: String
    let maxOutputTokens: Int
    let timeoutSeconds: TimeInterval

    var cacheKey: String {
        "\(mediaResolution)|\(thinkingLevel)|\(maxOutputTokens)|\(Int(timeoutSeconds))"
    }
}

// MARK: - Control Payload

struct ControlPayload: Decodable {
    var label: String?
    var role: String?
    var region: String?
    var actionHint: String?
    var confidence: Double?
}

// MARK: - Gemini API Request/Response Types

struct GeminiGenerateContentRequest: Encodable {
    var contents: [Content]
    var generationConfig: GenerationConfig

    struct Content: Encodable {
        var parts: [Part]
    }

    struct GenerationConfig: Encodable {
        var maxOutputTokens: Int
        var responseMimeType: String
        var mediaResolution: String
        var thinkingConfig: ThinkingConfig
    }

    struct ThinkingConfig: Encodable {
        var thinkingLevel: String
    }
}

enum Part: Encodable {
    case text(String)
    case inlineData(mimeType: String, data: String)

    private enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    private enum InlineDataKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .inlineData(let mimeType, let data):
            var inlineData = container.nestedContainer(keyedBy: InlineDataKeys.self, forKey: .inlineData)
            try inlineData.encode(mimeType, forKey: .mimeType)
            try inlineData.encode(data, forKey: .data)
        }
    }
}

struct GeminiGenerateContentResponse: Decodable {
    var candidates: [Candidate]?

    var firstText: String? {
        candidates?
            .lazy
            .compactMap { $0.content?.parts?.compactMap(\.text).joined(separator: "\n") }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    struct Candidate: Decodable {
        var content: Content?
    }

    struct Content: Decodable {
        var parts: [PartText]?
    }

    struct PartText: Decodable {
        var text: String?
    }
}

struct GeminiSendResult {
    var response: GeminiGenerateContentResponse
    var rawBody: String
}

// MARK: - KeyedDecodingContainer Extension

extension KeyedDecodingContainer {
    func decodeStringArrayIfPresent(forKey key: Key) throws -> [String] {
        if let values = try? decode([String].self, forKey: key) {
            return values
        }
        if let value = try? decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [value]
        }
        return []
    }
}
