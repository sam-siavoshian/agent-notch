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

    public static func debugPaths(
        for imageData: Data,
        mimeType: String = "image/png",
        laneName: String? = nil
    ) -> ContextGeminiDebugPaths {
        let imageHash = sha256Hex(imageData)
        let prefix = debugArtifactPrefix(imageHash: imageHash, laneName: laneName)
        let debugDirectoryURL = defaultCacheDirectoryURL.appendingPathComponent("Debug", isDirectory: true)
        let imageExtension = mimeType == "image/png" ? "png" : "jpg"
        return ContextGeminiDebugPaths(
            imageHash: imageHash,
            requestImagePath: debugDirectoryURL.appendingPathComponent("\(prefix)-request-image.\(imageExtension)").path,
            requestMetadataPath: debugDirectoryURL.appendingPathComponent("\(prefix)-request.txt").path,
            promptPath: debugDirectoryURL.appendingPathComponent("\(prefix)-prompt.txt").path,
            rawResponsePath: debugDirectoryURL.appendingPathComponent("\(prefix)-raw-response.json").path,
            errorPath: debugDirectoryURL.appendingPathComponent("\(prefix)-error.txt").path
        )
    }

    private let apiKeyProvider: @Sendable () -> String?
    private let cacheDirectoryURL: URL
    private let debugDirectoryURL: URL
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
        self.debugDirectoryURL = cacheDirectoryURL.appendingPathComponent("Debug", isDirectory: true)
        self.endpointBaseURL = endpointBaseURL
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: debugDirectoryURL, withIntermediateDirectories: true)
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
            NSLog("[ContextGeminiObservationService] GEMINI_API_KEY is not set; skipping Gemini observation.")
            return nil
        }

        do {
            let prompt = Self.prompt(for: input)
            writeDebugData(input.imageData, imageHash: imageHash, mimeType: input.mimeType)
            writeDebugText(requestMetadata(for: input, config: config), imageHash: imageHash, suffix: "request.txt")
            writeDebugText(prompt, imageHash: imageHash, suffix: "prompt.txt")
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
        previousSnapshot: ContextSnapshot? = nil,
        debugLaneName: String? = nil
    ) async -> ContextGeminiLaneObservation? {
        let config = requestConfig(for: lane)
        let imageHash = Self.sha256Hex(input.imageData)
        let cacheURL = laneCacheURL(imageHash: imageHash, lane: lane, input: input, config: config)
        let debugName = debugLaneName ?? lane.rawValue

        if let cached = readCachedLaneObservation(at: cacheURL) {
            var observation = cached
            observation.source = .cache
            return observation
        }

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            NSLog("[ContextGeminiObservationService] GEMINI_API_KEY is not set; skipping \(lane.rawValue) lane.")
            return nil
        }

        do {
            let prompt = Self.lanePrompt(for: lane, input: input, previousSnapshot: previousSnapshot)
            writeDebugData(input.imageData, imageHash: imageHash, mimeType: input.mimeType, laneName: debugName)
            writeDebugText(requestMetadata(for: input, config: config, lane: lane), imageHash: imageHash, suffix: "request.txt", laneName: debugName)
            writeDebugText(prompt, imageHash: imageHash, suffix: "prompt.txt", laneName: debugName)

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
            writeDebugText(result.rawBody, imageHash: imageHash, suffix: "raw-response.json", laneName: debugName)
            guard let text = result.response.firstText else {
                NSLog("[ContextGeminiObservationService] \(lane.rawValue) lane response had no text candidate.")
                return nil
            }
            writeDebugText(text, imageHash: imageHash, suffix: "raw-text.json", laneName: debugName)

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
            writeDebugText("\(error)", imageHash: imageHash, suffix: "error.txt", laneName: debugName)
            NSLog("[ContextGeminiObservationService] \(lane.rawValue) lane failed: \(error)")
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
            NSLog("[ContextGeminiObservationService] Transient error, retrying in 1s: \(error)")
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
            NSLog("[ContextGeminiObservationService] Failed to write Gemini cache: \(error)")
        }
    }

    private func writeCachedLaneObservation(_ observation: ContextGeminiLaneObservation, to url: URL) {
        do {
            let data = try Self.encoder.encode(observation)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[ContextGeminiObservationService] Failed to write Gemini lane cache: \(error)")
        }
    }

    private func writeDebugData(_ data: Data, imageHash: String, mimeType: String, laneName: String? = nil) {
        let prefix = Self.debugArtifactPrefix(imageHash: imageHash, laneName: laneName)
        let fileExtension = mimeType == "image/png" ? "png" : "jpg"
        do {
            try data.write(to: debugDirectoryURL.appendingPathComponent("\(prefix)-request-image.\(fileExtension)"), options: .atomic)
            try data.write(to: debugDirectoryURL.appendingPathComponent("latest-request-image.\(fileExtension)"), options: .atomic)
        } catch {
            NSLog("[ContextGeminiObservationService] Failed to write Gemini debug image: \(error)")
        }
    }

    private func writeDebugText(_ text: String, imageHash: String, suffix: String, laneName: String? = nil) {
        let prefix = Self.debugArtifactPrefix(imageHash: imageHash, laneName: laneName)
        let url = debugDirectoryURL.appendingPathComponent("\(prefix)-\(suffix)")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try text.write(to: debugDirectoryURL.appendingPathComponent("latest-\(suffix)"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("[ContextGeminiObservationService] Failed to write Gemini debug text: \(error)")
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

    private func requestMetadata(
        for input: ContextGeminiObservationInput,
        config: GeminiObservationRequestConfig,
        lane: ContextGeminiObservationLane? = nil
    ) -> String {
        let imageKB = input.imageData.count / 1024
        return """
        Gemini observation request
        model: \(model)
        promptVersion: \(Self.promptVersion)
        lane: \(lane?.rawValue ?? "monolith")
        mimeType: \(input.mimeType)
        imageBytes: \(input.imageData.count) (\(imageKB)KB)
        mediaResolution: \(config.mediaResolution)
        thinkingLevel: \(config.thinkingLevel)
        maxOutputTokens: \(config.maxOutputTokens)
        timeoutSeconds: \(Int(config.timeoutSeconds))
        estimatedCost: \(Self.estimatedCostDescription(model: model, config: config))
        temperature: default
        partOrder: image, prompt

        Image processing pipeline:
        - Capture: ScreenCaptureKit full-display CGImage with cursor included.
        - Local OCR: Apple Vision runs on the lossless PNG bytes from the capture.
        - Local preview artifact: JPEG encoded separately at capture quality for lightweight Dev Tools thumbnails.
        - Gemini request image: PNG bytes from the same capture, no crop, no downscale, no JPEG compression.
        - Gemini request format: inline_data image first, text prompt second.
        - Gemini latency knobs: global mediaResolution=\(config.mediaResolution), thinkingLevel=\(config.thinkingLevel), maxOutputTokens=\(config.maxOutputTokens).
        """
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

    private static func lanePrompt(
        for lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        previousSnapshot: ContextSnapshot?
    ) -> String {
        let metadataLines = metadataLines(for: input)
        let previous = previousSnapshot.map(previousSnapshotLines) ?? "- No previous screen supplied."
        let base = """
        You are one lane in a modular screen-understanding pipeline for a macOS computer-use agent.
        Analyze the full-display screenshot, but separate the active/frontmost work surface from background windows and AgentNotch/dev overlays.
        Your job is to preprocess useful reasoning so the future computer-use model spends fewer tokens discovering what the user is doing or how the UI works.

        Rules:
        - Use only visible evidence plus metadata. Prefer uncertainty over guessing.
        - Be specific and operational. Do not write generic labels like "button" or "sidebar" without saying what it helps do.
        - Keep output compact. Short, dense strings are better than paragraphs.
        - Mention private content only as short visible labels/entities needed for operation.
        - Return strict JSON only.

        Metadata:
        \(metadataLines)

        Previous screen for interaction reasoning:
        \(previous)
        """

        switch lane {
        case .activity:
            return base + """

            Lane goal: understand what the user is actively doing, the current work state, and what the agent should know if asked to jump in.
            Focus on task, visible content, active app/page, current state, likely intent, and recent work context. Do not catalog every control.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, primaryTask, contentSummary,
            stateIndicators: [string],
            entities: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number
            """
        case .uiMap:
            return base + """

            Lane goal: learn how this UI can be operated so a future computer-use agent can act faster.
            Focus on visible regions, controls, navigation, workflows, successful next actions, and negative/no-op cues. Treat UI/UX memory as an accelerator, not a screenshot caption.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary,
            layoutRegions: [string],
            controls: [{ "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }],
            workflows: [string],
            navigation: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number

            Every workflow must name the visible control or region it would use and the expected result.
            Every negative cue must explain what wasted action it prevents.
            """
        case .entityContent:
            return base + """

            Lane goal: harvest useful content and entities from the screen.
            Focus on files, docs, URLs, people, tickets, records, errors, messages, terminal output, selected/current items, and app-specific objects. Capture what the user is working with, not just what app is open.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, contentSummary,
            layoutRegions: [string],
            entities: [string],
            stateIndicators: [string],
            memoryCards: [string],
            negativeCues: [string],
            uncertainty: [string],
            confidence: number
            """
        case .interaction:
            return base + """

            Lane goal: compare previous and current screen hints to infer what changed after the last click/app switch/manual capture.
            Focus on action effect, transition, changed state, likely clicked target, success/failure signal, and whether the action taught a reusable navigation/workflow fact.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary,
            primaryTask,
            workflows: [string],
            navigation: [string],
            stateIndicators: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number
            """
        case .reducer:
            return base + """

            Lane goal: merge previously extracted lane outputs. If you receive a screenshot here, still keep output compact and activation-ready.
            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, primaryTask, contentSummary,
            layoutRegions: [string],
            controls: [{ "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }],
            entities: [string],
            stateIndicators: [string],
            workflows: [string],
            navigation: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number
            """
        }
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
        let ocrItems = regionOCRLines(from: input.recognizedText)
        if !ocrItems.isEmpty {
            lines.append("- OCR by screen region:")
            lines.append(contentsOf: ocrItems)
            lines.append("- Raw OCR item count: \(input.recognizedText.count)")
        }
        for key in input.metadata.keys.sorted() {
            guard let value = clean(input.metadata[key]) else { continue }
            lines.append("- \(key): \(value)")
        }
        return lines.isEmpty ? "- No metadata provided." : lines.joined(separator: "\n")
    }

    private static func previousSnapshotLines(_ snapshot: ContextSnapshot) -> String {
        let text = ContextTextSignalFilter.usefulText(from: snapshot.recognizedText, maxCount: 10)
        var lines = [
            "- Previous app: \(snapshot.appName)",
            "- Previous window: \(snapshot.windowTitle)",
            "- Previous trigger: \(snapshot.trigger.rawValue)"
        ]
        if !text.isEmpty {
            lines.append("- Previous useful OCR: \(text.joined(separator: " | "))")
        }
        if let cursorLocation = snapshot.cursorLocation {
            lines.append("- Previous cursor: x=\(Int(cursorLocation.x)), y=\(Int(cursorLocation.y))")
        }
        return lines.joined(separator: "\n")
    }

    private static func regionOCRLines(from recognizedText: [ContextRecognizedText]) -> [String] {
        guard !recognizedText.isEmpty else { return [] }
        let useful = recognizedText
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if abs(lhs.y - rhs.y) > 0.03 {
                    return lhs.y > rhs.y
                }
                return lhs.x < rhs.x
            }

        var buckets: [String: [String]] = [
            "top": [],
            "left": [],
            "center": [],
            "right": [],
            "bottom": []
        ]

        for item in useful {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bucket: String
            if item.y > 0.82 {
                bucket = "top"
            } else if item.y < 0.18 {
                bucket = "bottom"
            } else if item.x < 0.24 {
                bucket = "left"
            } else if item.x > 0.76 {
                bucket = "right"
            } else {
                bucket = "center"
            }
            if buckets[bucket, default: []].count < 12 {
                buckets[bucket, default: []].append(text)
            }
        }

        return ["top", "left", "center", "right", "bottom"].compactMap { key in
            let values = ContextTextSignalFilter.usefulText(
                from: buckets[key, default: []].map {
                    ContextRecognizedText(text: $0, confidence: 1, x: 0, y: 0, width: 0, height: 0)
                },
                maxCount: 10
            )
            guard !values.isEmpty else { return nil }
            return "  - \(key): \(values.joined(separator: " | "))"
        }
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

    private static func parseLaneObservation(
        _ rawText: String,
        lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        imageHash: String,
        model: String,
        promptVersion: String
    ) throws -> ContextGeminiLaneObservation {
        let data = cleanedJSONString(rawText).data(using: .utf8) ?? Data()
        let payload = try decoder.decode(LaneObservationPayload.self, from: data)
        let fallbackApp = clean(input.appName) ?? "Unknown app"
        let fallbackWindow = clean(input.windowTitle) ?? "Unknown window"
        let appLabel = clean(payload.appLabel) ?? fallbackApp
        let windowTitle = clean(payload.windowTitle) ?? fallbackWindow
        let surfaceLabel = clean(payload.surfaceLabel) ?? clean(payload.summary) ?? "Visible surface"

        return ContextGeminiLaneObservation(
            id: cacheObservationID(imageHash: imageHash, model: model, promptVersion: "\(promptVersion)-\(lane.rawValue)"),
            observedAt: Date(),
            source: .gemini,
            model: model,
            promptVersion: promptVersion,
            imageHash: imageHash,
            lane: lane,
            appLabel: appLabel,
            windowTitle: windowTitle,
            surfaceID: clean(payload.surfaceID) ?? slug([appLabel, surfaceLabel, lane.rawValue].joined(separator: "-")),
            surfaceLabel: surfaceLabel,
            screenType: clean(payload.screenType) ?? "",
            summary: clean(payload.summary) ?? "\(lane.label) observation unavailable.",
            primaryTask: clean(payload.primaryTask) ?? "",
            contentSummary: clean(payload.contentSummary) ?? "",
            layoutRegions: cleanStrings(payload.layoutRegions, maxCount: 18),
            controls: payload.controls.prefix(24).map {
                ContextGeminiObservation.VisibleControl(
                    label: clean($0.label) ?? "Unlabeled control",
                    role: clean($0.role) ?? "control",
                    region: clean($0.region) ?? "unknown-region",
                    actionHint: clean($0.actionHint),
                    confidence: clamp($0.confidence)
                )
            },
            entities: cleanStrings(payload.entities, maxCount: 28),
            stateIndicators: cleanStrings(payload.stateIndicators, maxCount: 18),
            workflows: cleanStrings(payload.workflows, maxCount: 18),
            navigation: cleanStrings(payload.navigation, maxCount: 18),
            negativeCues: cleanStrings(payload.negativeCues, maxCount: 18),
            memoryCards: cleanStrings(payload.memoryCards, maxCount: 24),
            uncertainty: cleanStrings(payload.uncertainty, maxCount: 16),
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
        SHA256.hash(data: data).lazy.map { String(format: "%02x", $0) }.joined()
    }

    private static func debugArtifactPrefix(imageHash: String, laneName: String?) -> String {
        let shortHash = String(imageHash.prefix(16))
        guard let laneName = clean(laneName) else { return shortHash }
        let safeLane = slug(laneName)
        return "\(shortHash)-\(safeLane)"
    }

    private static func uniqueControls(_ controls: [ContextGeminiObservation.VisibleControl]) -> [ContextGeminiObservation.VisibleControl] {
        var seen = Set<String>()
        var output: [ContextGeminiObservation.VisibleControl] = []
        for control in controls {
            let key = [
                control.label.lowercased(),
                control.role.lowercased(),
                control.region.lowercased()
            ].joined(separator: "|")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(control)
        }
        return output
    }

    private static func normalizedMediaResolution(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "MEDIA_RESOLUTION_", with: "")
        switch value {
        case "LOW":
            return "MEDIA_RESOLUTION_LOW"
        case "MEDIUM":
            return "MEDIA_RESOLUTION_MEDIUM"
        case "HIGH":
            return "MEDIA_RESOLUTION_HIGH"
        default:
            return defaultMediaResolution
        }
    }

    private static func normalizedModel(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "gemini-3.1-flash-lite", "3.1-flash-lite", "flash-lite", "lite":
            return "gemini-3.1-flash-lite"
        case "gemini-3-flash", "3-flash", "flash":
            return "gemini-3-flash"
        default:
            return defaultModel
        }
    }

    private static func normalizedThinkingLevel(_ rawValue: String?) -> String {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "minimal", "low", "medium", "high":
            return value ?? defaultThinkingLevel
        default:
            return defaultThinkingLevel
        }
    }

    private static func estimatedCostDescription(model: String, config: GeminiObservationRequestConfig) -> String {
        let mediaTokens = estimatedMediaTokens(for: config.mediaResolution)
        guard let pricing = tokenPricing(for: model) else {
            return "unknown for \(model); request logs include media tokens \(mediaTokens) plus text/OCR/output tokens"
        }

        let imageInputCost = Double(mediaTokens) / 1_000_000 * pricing.inputPerMillion
        let maxOutputCost = Double(config.maxOutputTokens) / 1_000_000 * pricing.outputPerMillion
        return "\(mediaTokens) image tokens, image input approx \(dollars(imageInputCost)), max output approx \(dollars(maxOutputCost)); excludes OCR/prompt text input"
    }

    private static func estimatedMediaTokens(for mediaResolution: String) -> Int {
        switch normalizedMediaResolution(mediaResolution) {
        case "MEDIA_RESOLUTION_LOW":
            return 280
        case "MEDIA_RESOLUTION_MEDIUM":
            return 560
        case "MEDIA_RESOLUTION_HIGH":
            return 1120
        default:
            return 1120
        }
    }

    private static func tokenPricing(for model: String) -> (inputPerMillion: Double, outputPerMillion: Double)? {
        let lower = model.lowercased()
        if lower.contains("3.1-flash-lite") {
            return (0.25, 1.50)
        }
        if lower.contains("3-flash") {
            return (0.50, 3.00)
        }
        if lower.contains("2.5-flash-lite") {
            return (0.10, 0.40)
        }
        if lower.contains("2.5-flash") {
            return (0.30, 2.50)
        }
        return nil
    }

    private static func dollars(_ value: Double) -> String {
        if value < 0.0001 {
            return String(format: "$%.6f", value)
        }
        return String(format: "$%.4f", value)
    }

    // Reused across all encode/decode calls — JSONEncoder/Decoder are not Sendable but all
    // accesses happen through actor-serialized methods or static funcs called from them.
    nonisolated(unsafe) private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    nonisolated(unsafe) private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Compact encoder for outgoing API requests — no pretty-printing overhead.
    nonisolated(unsafe) private static let requestEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

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

private struct LaneObservationPayload: Decodable {
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

public struct ContextGeminiDebugPaths: Sendable {
    public let imageHash: String
    public let requestImagePath: String
    public let requestMetadataPath: String
    public let promptPath: String
    public let rawResponsePath: String
    public let errorPath: String
}

private struct GeminiObservationRequestConfig: Sendable {
    let mediaResolution: String
    let thinkingLevel: String
    let maxOutputTokens: Int
    let timeoutSeconds: TimeInterval

    var cacheKey: String {
        "\(mediaResolution)|\(thinkingLevel)|\(maxOutputTokens)|\(Int(timeoutSeconds))"
    }
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
        var maxOutputTokens: Int
        var responseMimeType: String
        var mediaResolution: String
        var thinkingConfig: ThinkingConfig
    }

    struct ThinkingConfig: Encodable {
        var thinkingLevel: String
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
