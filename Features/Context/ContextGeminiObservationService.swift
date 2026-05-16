//
//  ContextGeminiObservationService.swift
//  Agent in the Notch
//
//  Native Gemini observation layer for turning screenshots into compact UI
//  facts. ContextCoordinator runs it in the background after local OCR.
//

import CryptoKit
import Foundation

public actor ContextGeminiObservationService {
    public static let shared = ContextGeminiObservationService()

    public static let defaultModel = "gemini-3.1-flash-lite"
    public static let promptVersion = "context-gemini-observation-v3"

    public static var isAPIKeyConfigured: Bool {
        guard let apiKey = Env.value("GEMINI_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !apiKey.isEmpty
    }

    public static var defaultCacheDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("ContextGeminiCache", isDirectory: true)
    }

    public static func debugPaths(for jpegData: Data) -> ContextGeminiDebugPaths {
        let imageHash = sha256Hex(jpegData)
        let shortHash = String(imageHash.prefix(16))
        let debugDirectoryURL = defaultCacheDirectoryURL.appendingPathComponent("Debug", isDirectory: true)
        return ContextGeminiDebugPaths(
            imageHash: imageHash,
            promptPath: debugDirectoryURL.appendingPathComponent("\(shortHash)-prompt.txt").path,
            rawResponsePath: debugDirectoryURL.appendingPathComponent("\(shortHash)-raw-response.json").path,
            errorPath: debugDirectoryURL.appendingPathComponent("\(shortHash)-error.txt").path
        )
    }

    private let apiKeyProvider: @Sendable () -> String?
    private let cacheDirectoryURL: URL
    private let debugDirectoryURL: URL
    private let endpointBaseURL: URL
    private let model: String
    private let session: URLSession

    public init(
        model: String = ContextGeminiObservationService.defaultModel,
        cacheDirectoryURL: URL = ContextGeminiObservationService.defaultCacheDirectoryURL,
        endpointBaseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            Env.value("GEMINI_API_KEY")
        }
    ) {
        self.model = model
        self.cacheDirectoryURL = cacheDirectoryURL
        self.debugDirectoryURL = cacheDirectoryURL.appendingPathComponent("Debug", isDirectory: true)
        self.endpointBaseURL = endpointBaseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: debugDirectoryURL, withIntermediateDirectories: true)
    }

    public func observe(_ input: ContextGeminiObservationInput) async -> ContextGeminiObservation? {
        let imageHash = Self.sha256Hex(input.jpegData)
        let cacheURL = cacheURL(imageHash: imageHash, input: input)

        if let cached = readCachedObservation(at: cacheURL) {
            var observation = cached
            observation.source = .cache
            return observation
        }

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            NSLog("[ContextGeminiObservationService] GEMINI_API_KEY is not set; skipping Gemini observation.")
            return nil
        }

        do {
            let prompt = Self.prompt(for: input)
            writeDebugText(prompt, imageHash: imageHash, suffix: "prompt.txt")
            let request = GeminiGenerateContentRequest(
                contents: [
                    .init(parts: [
                        .text(prompt),
                        .inlineData(mimeType: "image/jpeg", data: input.jpegData.base64EncodedString())
                    ])
                ],
                generationConfig: .init(
                    temperature: 0,
                    maxOutputTokens: 3200,
                    responseMimeType: "application/json"
                )
            )

            let result = try await send(request, apiKey: apiKey)
            writeDebugText(result.rawBody, imageHash: imageHash, suffix: "raw-response.json")
            guard let text = result.response.firstText else {
                NSLog("[ContextGeminiObservationService] Gemini response had no text candidate.")
                return nil
            }
            writeDebugText(text, imageHash: imageHash, suffix: "raw-text.json")

            let observation = try Self.parseObservation(
                text,
                input: input,
                imageHash: imageHash,
                model: model,
                promptVersion: Self.promptVersion
            )
            writeCachedObservation(observation, to: cacheURL)
            return observation
        } catch {
            writeDebugText("\(error)", imageHash: imageHash, suffix: "error.txt")
            NSLog("[ContextGeminiObservationService] Gemini observation failed: \(error)")
            return nil
        }
    }

    public func observe(
        jpegData: Data,
        appName: String? = nil,
        windowTitle: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        recognizedText: [ContextRecognizedText] = [],
        metadata: [String: String] = [:]
    ) async -> ContextGeminiObservation? {
        await observe(ContextGeminiObservationInput(
            jpegData: jpegData,
            appName: appName,
            windowTitle: windowTitle,
            width: width,
            height: height,
            recognizedText: recognizedText,
            metadata: metadata
        ))
    }

    private func send(_ request: GeminiGenerateContentRequest, apiKey: String) async throws -> GeminiSendResult {
        let base = endpointBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(model):generateContent") else {
            throw Error(status: nil, body: "Invalid Gemini endpoint URL.", underlying: nil)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = 30

        do {
            urlRequest.httpBody = try Self.encoder.encode(request)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Error(status: nil, body: nil, underlying: error)
        }

        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw Error(status: http?.statusCode, body: String(data: data, encoding: .utf8), underlying: nil)
        }

        do {
            return GeminiSendResult(
                response: try Self.decoder.decode(GeminiGenerateContentResponse.self, from: data),
                rawBody: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            throw Error(status: http.statusCode, body: String(data: data, encoding: .utf8), underlying: error)
        }
    }

    private func cacheURL(imageHash: String, input: ContextGeminiObservationInput) -> URL {
        let metadataHash = Self.sha256Hex(Self.cacheMetadataString(for: input).data(using: .utf8) ?? Data())
        let key = Self.sha256Hex("\(imageHash)|\(metadataHash)|\(Self.promptVersion)|\(model)".data(using: .utf8) ?? Data())
        return cacheDirectoryURL.appendingPathComponent("\(key).json")
    }

    private static func cacheMetadataString(for input: ContextGeminiObservationInput) -> String {
        let usefulText = ContextTextSignalFilter.usefulText(from: input.recognizedText, maxCount: 32)
        let metadata = input.metadata.keys.sorted()
            .map { "\($0)=\(input.metadata[$0] ?? "")" }
            .joined(separator: "|")
        return [
            input.appName ?? "",
            input.windowTitle ?? "",
            input.width.map(String.init) ?? "",
            input.height.map(String.init) ?? "",
            usefulText.joined(separator: "|"),
            metadata
        ].joined(separator: "\n")
    }

    private func readCachedObservation(at url: URL) -> ContextGeminiObservation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(ContextGeminiObservation.self, from: data)
    }

    private func writeCachedObservation(_ observation: ContextGeminiObservation, to url: URL) {
        do {
            let data = try Self.encoder.encode(observation)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ContextGeminiObservationService] Failed to write Gemini cache: \(error)")
        }
    }

    private func writeDebugText(_ text: String, imageHash: String, suffix: String) {
        let shortHash = String(imageHash.prefix(16))
        let url = debugDirectoryURL.appendingPathComponent("\(shortHash)-\(suffix)")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try text.write(to: debugDirectoryURL.appendingPathComponent("latest-\(suffix)"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("[ContextGeminiObservationService] Failed to write Gemini debug text: \(error)")
        }
    }

    private static func prompt(for input: ContextGeminiObservationInput) -> String {
        let metadataLines = metadataLines(for: input)
        return """
        You are building a reusable UI/UX memory layer for a macOS computer-use agent.
        Observe this screenshot like a careful operator learning how the visible app works.
        Extract durable, action-relevant facts that would reduce future exploration.

        Prioritize:
        - visible navigation structure, tabs, panels, sidebars, toolbar regions, overlays, tables, forms, lists, modals, search fields, and status chips
        - exact visible control labels and what using them likely does
        - page/surface state: selected tabs, filters, active records, empty/error/loading states, warnings, disabled controls
        - visible data objects/entities that may be referenced later
        - workflow hints: how a user would accomplish tasks from this surface
        - negative cues: things that look clickable but are probably status text, no-op areas, stale overlays, debug chrome, or unrelated background windows
        - memory candidates: durable facts a future computer-use agent should remember

        Use only visible evidence plus the metadata. Prefer uncertainty over guessing.
        Do not describe private content beyond short visible labels/entities needed for UI operation.
        If an AgentNotch context/debug overlay is visible, separate overlay facts from the underlying app facts.
        Reject generic observations. Do not say "there is a sidebar" unless you name what is in it and why it matters.
        Prefer action memory over visual description.

        Return strict JSON only with these fields:
        appLabel: string
        windowTitle: string
        surfaceID: short stable slug for this visible surface, based on visible app/product/screen, not transient window text
        surfaceLabel: short human label for the surface
        screenType: short category such as dashboard, document, chat, terminal, browser-page, settings, modal, table, form, editor, overlay
        primaryTask: what the user appears able to do here, one short sentence
        layoutSummary: concise map of important regions and what each region contains
        contentSummary: concise summary of visible page/content state, avoiding noisy OCR fragments
        summary: one dense sentence combining what this screen is and why it matters operationally
        visibleControls: array of { "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }
        landmarks: array of short strings
        entities: array of short strings
        affordances: array of short strings
        stateIndicators: array of short strings
        navigationPaths: array of short strings, e.g. "left sidebar > Settings opens preferences"
        dataRegions: array of short strings, e.g. "center table lists deployments with status chips"
        workflowHints: array of short strings, e.g. "Use Filters to narrow failed deployments"
        negativeCues: array of short strings, e.g. "debug overlay partially obscures page"
        memoryCandidates: array of short durable facts formatted like "stable: Settings is in the left sidebar" or "transient: debug overlay is covering the page"
        uncertainty: array of short strings
        confidence: number from 0 to 1

        Use approximate regions such as top-bar, top-right, left-sidebar, center-table, right-panel, bottom-sheet, modal, overlay, browser-chrome, terminal.
        Keep each string short but information-dense. Return up to 20 controls, 16 landmarks, 24 entities, and 12 items for each other array.
        Every workflowHint should name a visible control, region, or state. Every negativeCue should explain what mistaken action it prevents.
        Do not invent hidden controls. If metadata conflicts with the image, mention that in uncertainty.

        Metadata:
        \(metadataLines)
        """
    }

    private static func metadataLines(for input: ContextGeminiObservationInput) -> String {
        var lines: [String] = []
        if let appName = clean(input.appName) {
            lines.append("- App hint: \(appName)")
        }
        if let windowTitle = clean(input.windowTitle) {
            lines.append("- Window hint: \(windowTitle)")
        }
        if let width = input.width, let height = input.height {
            lines.append("- Screenshot size: \(width)x\(height)")
        }
        let ocrItems = ContextTextSignalFilter.usefulText(from: input.recognizedText, maxCount: 32)
        if !ocrItems.isEmpty {
            lines.append("- Useful OCR text: \(ocrItems.joined(separator: " | "))")
            lines.append("- Raw OCR item count: \(input.recognizedText.count)")
        }
        for key in input.metadata.keys.sorted() {
            guard let value = clean(input.metadata[key]) else { continue }
            lines.append("- \(key): \(value)")
        }
        return lines.isEmpty ? "- No metadata provided." : lines.joined(separator: "\n")
    }

    private static func parseObservation(
        _ rawText: String,
        input: ContextGeminiObservationInput,
        imageHash: String,
        model: String,
        promptVersion: String
    ) throws -> ContextGeminiObservation {
        let data = cleanedJSONString(rawText).data(using: .utf8) ?? Data()
        let payload = try decoder.decode(ObservationPayload.self, from: data)
        let fallbackApp = clean(input.appName) ?? "Unknown app"
        let fallbackWindow = clean(input.windowTitle) ?? "Unknown window"
        let appLabel = clean(payload.appLabel) ?? fallbackApp
        let windowTitle = clean(payload.windowTitle) ?? fallbackWindow
        let surfaceLabel = clean(payload.surfaceLabel) ?? "Visible surface"

        return ContextGeminiObservation(
            id: cacheObservationID(imageHash: imageHash, model: model, promptVersion: promptVersion),
            observedAt: Date(),
            source: .gemini,
            model: model,
            promptVersion: promptVersion,
            imageHash: imageHash,
            appLabel: appLabel,
            windowTitle: windowTitle,
            surfaceID: clean(payload.surfaceID) ?? slug([appLabel, surfaceLabel].joined(separator: "-")),
            surfaceLabel: surfaceLabel,
            summary: clean(payload.summary) ?? "Screen observation unavailable.",
            screenType: clean(payload.screenType) ?? "",
            primaryTask: clean(payload.primaryTask) ?? "",
            layoutSummary: clean(payload.layoutSummary) ?? "",
            contentSummary: clean(payload.contentSummary) ?? "",
            visibleControls: payload.visibleControls.prefix(24).map {
                ContextGeminiObservation.VisibleControl(
                    label: clean($0.label) ?? "Unlabeled control",
                    role: clean($0.role) ?? "control",
                    region: clean($0.region) ?? "unknown-region",
                    actionHint: clean($0.actionHint),
                    confidence: clamp($0.confidence)
                )
            },
            landmarks: cleanStrings(payload.landmarks, maxCount: 16),
            entities: cleanStrings(payload.entities, maxCount: 24),
            affordances: cleanStrings(payload.affordances, maxCount: 16),
            stateIndicators: cleanStrings(payload.stateIndicators, maxCount: 12),
            navigationPaths: cleanStrings(payload.navigationPaths, maxCount: 12),
            dataRegions: cleanStrings(payload.dataRegions, maxCount: 12),
            workflowHints: cleanStrings(payload.workflowHints, maxCount: 12),
            negativeCues: cleanStrings(payload.negativeCues, maxCount: 12),
            memoryCandidates: cleanStrings(payload.memoryCandidates, maxCount: 16),
            uncertainty: cleanStrings(payload.uncertainty, maxCount: 12),
            confidence: clamp(payload.confidence)
        )
    }

    private static func cleanedJSONString(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") {
            text.removeFirst("```json".count)
        } else if text.hasPrefix("```") {
            text.removeFirst("```".count)
        }
        if text.hasSuffix("```") {
            text.removeLast("```".count)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cacheObservationID(imageHash: String, model: String, promptVersion: String) -> String {
        sha256Hex("\(imageHash)|\(promptVersion)|\(model)".data(using: .utf8) ?? Data()).prefix(24).description
    }

    private static func clean(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    private static func cleanStrings(_ values: [String], maxCount: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let cleaned = clean(value) else { continue }
            let key = cleaned.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(cleaned)
            if output.count >= maxCount { break }
        }
        return output
    }

    private static func slug(_ value: String) -> String {
        let parts = value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "unknown-surface" : slug
    }

    private static func clamp(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0.5 }
        if value > 1 {
            return min(1, max(0, value / 100))
        }
        return min(1, max(0, value))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension ContextGeminiObservationService {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let status: Int?
        public let body: String?
        public let underlying: (any Swift.Error)?

        public var description: String {
            "ContextGeminiObservationService.Error(status: \(status.map(String.init) ?? "nil"), body: \(body ?? "nil"), underlying: \(underlying.map { "\($0)" } ?? "nil"))"
        }
    }
}

private struct ObservationPayload: Decodable {
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

public struct ContextGeminiDebugPaths: Sendable {
    public let imageHash: String
    public let promptPath: String
    public let rawResponsePath: String
    public let errorPath: String
}

private struct ControlPayload: Decodable {
    var label: String?
    var role: String?
    var region: String?
    var actionHint: String?
    var confidence: Double?
}

private struct GeminiGenerateContentRequest: Encodable {
    var contents: [Content]
    var generationConfig: GenerationConfig

    struct Content: Encodable {
        var parts: [Part]
    }

    struct GenerationConfig: Encodable {
        var temperature: Double
        var maxOutputTokens: Int
        var responseMimeType: String
    }
}

private enum Part: Encodable {
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

private struct GeminiGenerateContentResponse: Decodable {
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

private struct GeminiSendResult {
    var response: GeminiGenerateContentResponse
    var rawBody: String
}

private extension KeyedDecodingContainer {
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
