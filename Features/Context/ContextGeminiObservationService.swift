//
//  ContextGeminiObservationService.swift
//  Agent in the Notch
//
//  Native Gemini observation layer for turning screenshots into compact UI
//  facts. ContextCoordinator runs it in the background after local OCR.
//

import CryptoKit
import Foundation

private let log = Log(category: "gemini")

public actor ContextGeminiObservationService {
    public static let shared = ContextGeminiObservationService()

    public static let defaultModel = "gemini-3.1-flash-lite"
    public static let promptVersion = "context-gemini-observation-v5"
    public static let defaultMediaResolution = "MEDIA_RESOLUTION_HIGH"
    public static let defaultThinkingLevel = "minimal"
    public static let defaultMaxOutputTokens = 2400

    public static var configuredModel: String {
        normalizedModel(
            Env.value("AGENTNOTCH_GEMINI_MODEL")
                ?? Env.value("GEMINI_MODEL")
        )
    }

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

    public static var configuredMediaResolution: String {
        normalizedMediaResolution(
            Env.value("AGENTNOTCH_GEMINI_MEDIA_RESOLUTION")
                ?? Env.value("GEMINI_MEDIA_RESOLUTION")
        )
    }

    public static var configuredThinkingLevel: String {
        normalizedThinkingLevel(
            Env.value("AGENTNOTCH_GEMINI_THINKING_LEVEL")
                ?? Env.value("GEMINI_THINKING_LEVEL")
        )
    }

    private let apiKeyProvider: @Sendable () -> String?
    private let cacheDirectoryURL: URL
    private let endpointBaseURL: URL
    private let model: String
    private let mediaResolutionOverride: String?
    private let thinkingLevelOverride: String?
    private let session: URLSession

    // swiftlint:disable:next force_unwrapping — hardcoded literal, never nil
    public static let defaultEndpointBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!

    public init(
        model: String = ContextGeminiObservationService.configuredModel,
        cacheDirectoryURL: URL = ContextGeminiObservationService.defaultCacheDirectoryURL,
        endpointBaseURL: URL = ContextGeminiObservationService.defaultEndpointBaseURL,
        mediaResolutionOverride: String? = nil,
        thinkingLevelOverride: String? = nil,
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            Env.value("GEMINI_API_KEY")
        }
    ) {
        self.model = model
        self.mediaResolutionOverride = mediaResolutionOverride
        self.thinkingLevelOverride = thinkingLevelOverride
        self.cacheDirectoryURL = cacheDirectoryURL
        self.endpointBaseURL = endpointBaseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
    }

    public func observe(_ input: ContextGeminiObservationInput) async -> ContextGeminiObservation? {
        let config = requestConfig()
        let imageHash = Self.sha256Hex(input.imageData)
        let cacheURL = cacheURL(imageHash: imageHash, input: input, config: config)

        if let cached = readCachedObservation(at: cacheURL) {
            var observation = cached
            observation.source = .cache
            return observation
        }

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            log.warning("GEMINI_API_KEY is not set; skipping Gemini observation.")
            return nil
        }

        do {
            let prompt = Self.prompt(for: input)
            let request = GeminiGenerateContentRequest(
                contents: [
                    .init(parts: [
                        .inlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()),
                        .text(prompt)
                    ])
                ],
                generationConfig: .init(
                    maxOutputTokens: config.maxOutputTokens,
                    responseMimeType: "application/json",
                    mediaResolution: config.mediaResolution,
                    thinkingConfig: .init(thinkingLevel: config.thinkingLevel)
                )
            )

            let result = try await send(request, apiKey: apiKey, timeoutSeconds: config.timeoutSeconds)
            guard let text = result.response.firstText else {
                log.warning("Gemini response had no text candidate.")
                return nil
            }

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
            log.error("Gemini observation failed: \(error)")
            return nil
        }
    }

    public func observe(
        imageData: Data,
        mimeType: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        recognizedText: [ContextRecognizedText] = [],
        metadata: [String: String] = [:]
    ) async -> ContextGeminiObservation? {
        await observe(ContextGeminiObservationInput(
            imageData: imageData,
            mimeType: mimeType,
            appName: appName,
            windowTitle: windowTitle,
            width: width,
            height: height,
            recognizedText: recognizedText,
            metadata: metadata
        ))
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

    public func observeLane(
        _ lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        previousSnapshot: ContextSnapshot? = nil
    ) async -> ContextGeminiLaneObservation? {
        let config = requestConfig(for: lane)
        let imageHash = Self.sha256Hex(input.imageData)
        let cacheURL = laneCacheURL(imageHash: imageHash, lane: lane, input: input, config: config)

        if let cached = readCachedLaneObservation(at: cacheURL) {
            var observation = cached
            observation.source = .cache
            return observation
        }

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            log.warning("GEMINI_API_KEY is not set; skipping \(lane.rawValue) lane.")
            return nil
        }

        do {
            let prompt = Self.lanePrompt(for: lane, input: input, previousSnapshot: previousSnapshot)
            let request = GeminiGenerateContentRequest(
                contents: [
                    .init(parts: [
                        .inlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()),
                        .text(prompt)
                    ])
                ],
                generationConfig: .init(
                    maxOutputTokens: config.maxOutputTokens,
                    responseMimeType: "application/json",
                    mediaResolution: config.mediaResolution,
                    thinkingConfig: .init(thinkingLevel: config.thinkingLevel)
                )
            )

            let result = try await send(request, apiKey: apiKey, timeoutSeconds: config.timeoutSeconds)
            guard let text = result.response.firstText else {
                log.warning("\(lane.rawValue) lane response had no text candidate.")
                return nil
            }

            let observation = try Self.parseLaneObservation(
                text,
                lane: lane,
                input: input,
                imageHash: imageHash,
                model: model,
                promptVersion: Self.promptVersion
            )
            writeCachedLaneObservation(observation, to: cacheURL)
            return observation
        } catch {
            log.error("\(lane.rawValue) lane failed: \(error)")
            return nil
        }
    }

    public static func reduceLaneObservations(
        _ lanes: [ContextGeminiLaneObservation],
        input: ContextGeminiObservationInput,
        imageHash: String,
        model: String = ContextGeminiObservationService.defaultModel,
        promptVersion: String = ContextGeminiObservationService.promptVersion
    ) -> ContextGeminiObservation? {
        guard !lanes.isEmpty else { return nil }

        let byLane = Dictionary(grouping: lanes, by: \.lane)
        let ui = byLane[.uiMap]?.first
        let activity = byLane[.activity]?.first
        let entities = byLane[.entityContent]?.first
        let interaction = byLane[.interaction]?.first
        let primary = ui ?? activity ?? entities ?? lanes[0]

        let controls = Array(uniqueControls(lanes.flatMap(\.controls)).prefix(24))
        let confidenceValues = lanes.map(\.confidence).filter { $0.isFinite }
        let confidence = confidenceValues.isEmpty ? 0.5 : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        let summaryParts = [
            activity?.summary,
            ui?.summary,
            entities?.summary,
            interaction?.summary
        ].compactMap { clean($0) }

        return ContextGeminiObservation(
            id: cacheObservationID(imageHash: imageHash, model: model, promptVersion: promptVersion),
            observedAt: Date(),
            source: lanes.contains(where: { $0.source == .gemini }) ? .gemini : .cache,
            model: model,
            promptVersion: promptVersion,
            imageHash: imageHash,
            appLabel: clean(primary.appLabel) ?? clean(input.appName) ?? "Unknown app",
            windowTitle: clean(primary.windowTitle) ?? clean(input.windowTitle) ?? "Unknown window",
            surfaceID: clean(primary.surfaceID) ?? slug([primary.appLabel, primary.surfaceLabel].joined(separator: "-")),
            surfaceLabel: clean(primary.surfaceLabel) ?? "Visible surface",
            summary: summaryParts.prefix(3).joined(separator: " "),
            screenType: clean(primary.screenType) ?? "",
            primaryTask: clean(activity?.primaryTask) ?? clean(primary.primaryTask) ?? "",
            layoutSummary: clean(ui?.layoutRegions.joined(separator: " | ")) ?? clean(primary.layoutRegions.joined(separator: " | ")) ?? "",
            contentSummary: clean(entities?.contentSummary) ?? clean(activity?.contentSummary) ?? clean(primary.contentSummary) ?? "",
            visibleControls: controls,
            landmarks: cleanStrings(lanes.flatMap(\.layoutRegions), maxCount: 18),
            entities: cleanStrings(lanes.flatMap(\.entities), maxCount: 28),
            affordances: cleanStrings((ui?.controls ?? []).map { control in
                let hint = clean(control.actionHint) ?? "use visible control"
                return "\(control.label): \(hint)"
            }, maxCount: 18),
            stateIndicators: cleanStrings(lanes.flatMap(\.stateIndicators), maxCount: 16),
            navigationPaths: cleanStrings(lanes.flatMap(\.navigation), maxCount: 16),
            dataRegions: cleanStrings((entities?.layoutRegions ?? []) + (ui?.layoutRegions ?? []), maxCount: 14),
            workflowHints: cleanStrings(lanes.flatMap(\.workflows), maxCount: 18),
            negativeCues: cleanStrings(lanes.flatMap(\.negativeCues), maxCount: 16),
            memoryCandidates: cleanStrings(lanes.flatMap(\.memoryCards), maxCount: 24),
            uncertainty: cleanStrings(lanes.flatMap(\.uncertainty), maxCount: 16),
            confidence: clamp(confidence)
        )
    }

    private func send(_ request: GeminiGenerateContentRequest, apiKey: String, timeoutSeconds: TimeInterval) async throws -> GeminiSendResult {
        do {
            return try await sendOnce(request, apiKey: apiKey, timeoutSeconds: timeoutSeconds)
        } catch let error as Error where error.isRetryable {
            log.warning("Transient error, retrying in 1s: \(error)")
            try await Task.sleep(for: .seconds(1))
            return try await sendOnce(request, apiKey: apiKey, timeoutSeconds: timeoutSeconds)
        }
    }

    private func sendOnce(_ request: GeminiGenerateContentRequest, apiKey: String, timeoutSeconds: TimeInterval) async throws -> GeminiSendResult {
        let base = endpointBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(model):generateContent") else {
            throw Error(status: nil, body: "Invalid Gemini endpoint URL.", underlying: nil)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = timeoutSeconds

        do {
            urlRequest.httpBody = try Self.requestEncoder.encode(request)
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

    private func cacheURL(imageHash: String, input: ContextGeminiObservationInput, config: GeminiObservationRequestConfig) -> URL {
        let metadataHash = Self.sha256Hex(Self.cacheMetadataString(for: input).data(using: .utf8) ?? Data())
        let key = Self.sha256Hex("\(imageHash)|\(metadataHash)|\(Self.promptVersion)|\(model)|\(input.mimeType)|\(config.cacheKey)".data(using: .utf8) ?? Data())
        return cacheDirectoryURL.appendingPathComponent("\(key).json")
    }

    private func laneCacheURL(
        imageHash: String,
        lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        config: GeminiObservationRequestConfig
    ) -> URL {
        let metadataHash = Self.sha256Hex(Self.cacheMetadataString(for: input).data(using: .utf8) ?? Data())
        let key = Self.sha256Hex("\(imageHash)|\(metadataHash)|\(Self.promptVersion)|\(model)|\(input.mimeType)|\(lane.rawValue)|\(config.cacheKey)".data(using: .utf8) ?? Data())
        return cacheDirectoryURL.appendingPathComponent("\(key)-\(lane.rawValue).json")
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

    private func readCachedLaneObservation(at url: URL) -> ContextGeminiLaneObservation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(ContextGeminiLaneObservation.self, from: data)
    }

    private func writeCachedObservation(_ observation: ContextGeminiObservation, to url: URL) {
        do {
            let data = try Self.encoder.encode(observation)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to write Gemini cache: \(error)")
        }
    }

    private func writeCachedLaneObservation(_ observation: ContextGeminiLaneObservation, to url: URL) {
        do {
            let data = try Self.encoder.encode(observation)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to write Gemini lane cache: \(error)")
        }
    }

    private func requestConfig(for lane: ContextGeminiObservationLane? = nil) -> GeminiObservationRequestConfig {
        Self.requestConfig(
            for: lane,
            mediaResolutionOverride: mediaResolutionOverride,
            thinkingLevelOverride: thinkingLevelOverride
        )
    }

    private static func requestConfig(
        for lane: ContextGeminiObservationLane?,
        mediaResolutionOverride: String? = nil,
        thinkingLevelOverride: String? = nil
    ) -> GeminiObservationRequestConfig {
        let laneMaxOutput: Int
        switch lane {
        case .activity:
            laneMaxOutput = 900
        case .uiMap:
            laneMaxOutput = 1200
        case .entityContent:
            laneMaxOutput = 1000
        case .interaction:
            laneMaxOutput = 800
        case .reducer:
            laneMaxOutput = 900
        case nil:
            laneMaxOutput = defaultMaxOutputTokens
        }

        return GeminiObservationRequestConfig(
            mediaResolution: normalizedMediaResolution(mediaResolutionOverride) == defaultMediaResolution && mediaResolutionOverride == nil
                ? configuredMediaResolution
                : normalizedMediaResolution(mediaResolutionOverride),
            thinkingLevel: normalizedThinkingLevel(thinkingLevelOverride) == defaultThinkingLevel && thinkingLevelOverride == nil
                ? configuredThinkingLevel
                : normalizedThinkingLevel(thinkingLevelOverride),
            maxOutputTokens: laneMaxOutput,
            timeoutSeconds: 20
        )
    }

    // Reused across all encode/decode calls — JSONEncoder/Decoder are not Sendable but all
    // accesses happen through actor-serialized methods or static funcs called from them.
    nonisolated(unsafe) static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    nonisolated(unsafe) static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Compact encoder for outgoing API requests — no pretty-printing overhead.
    nonisolated(unsafe) static let requestEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
