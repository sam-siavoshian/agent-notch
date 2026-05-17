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
                preserveFailureArtifacts(imageHash: imageHash, laneName: nil, reason: "no text candidate")
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
            preserveFailureArtifacts(imageHash: imageHash, laneName: nil, reason: "\(error)")
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
            let systemInstruction = Self.laneSystemInstruction(for: lane)
            let dynamicPrompt = Self.laneDynamicPrompt(for: lane, input: input, previousSnapshot: previousSnapshot)
            let fullPromptForDebug = "[SYSTEM INSTRUCTION]\n\(systemInstruction)\n\n[USER PROMPT]\n\(dynamicPrompt)"
            writeDebugData(input.imageData, imageHash: imageHash, mimeType: input.mimeType, laneName: debugName)
            writeDebugText(requestMetadata(for: input, config: config, lane: lane), imageHash: imageHash, suffix: "request.txt", laneName: debugName)
            writeDebugText(fullPromptForDebug, imageHash: imageHash, suffix: "prompt.txt", laneName: debugName)

            // Try to attach a cached system instruction. Fall back to inlining it if caching fails.
            let cachedContentName = await ContextGeminiCacheManager.shared.cachedContentName(
                for: lane,
                model: model,
                promptVersion: Self.promptVersion,
                systemInstruction: systemInstruction,
                apiKey: apiKey
            )

            // Build parts. For .interaction with a previousSnapshot, send two images
            // image-first ordered as [previous, current, text]; the user-visible prompt
            // already calls these out as FIRST/SECOND.
            var parts: [Part] = []
            if lane == .interaction, let previousSnapshot, !previousSnapshot.jpegData.isEmpty {
                parts.append(.inlineData(mimeType: "image/jpeg", data: previousSnapshot.jpegData.base64EncodedString()))
            }
            parts.append(.inlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()))

            // When caching is active, only send the dynamic per-call text; the cached
            // system instruction supplies the rules + lane goal + JSON schema.
            // When caching is not active, prepend the static system instruction to the text.
            let textPrompt: String
            if cachedContentName != nil {
                textPrompt = dynamicPrompt
            } else {
                textPrompt = systemInstruction + "\n\n" + dynamicPrompt
            }
            parts.append(.text(textPrompt))

            let request = GeminiGenerateContentRequest(
                contents: [.init(parts: parts)],
                generationConfig: .init(
                    maxOutputTokens: config.maxOutputTokens,
                    responseMimeType: "application/json",
                    mediaResolution: config.mediaResolution,
                    thinkingConfig: .init(thinkingLevel: config.thinkingLevel)
                ),
                cachedContent: cachedContentName
            )

            let result: GeminiSendResult
            do {
                result = try await send(request, apiKey: apiKey, timeoutSeconds: config.timeoutSeconds)
            } catch let error as Error where Self.isCacheMiss(error) && cachedContentName != nil {
                // Cache expired or was deleted server-side. Drop it and retry once
                // with the system instruction inlined.
                NSLog("[ContextGeminiObservationService] Cached content miss for \(lane.rawValue); rebuilding without cache.")
                await ContextGeminiCacheManager.shared.invalidate(
                    lane: lane,
                    model: model,
                    promptVersion: Self.promptVersion
                )
                var retryParts: [Part] = []
                if lane == .interaction, let previousSnapshot, !previousSnapshot.jpegData.isEmpty {
                    retryParts.append(.inlineData(mimeType: "image/jpeg", data: previousSnapshot.jpegData.base64EncodedString()))
                }
                retryParts.append(.inlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()))
                retryParts.append(.text(systemInstruction + "\n\n" + dynamicPrompt))
                let retryRequest = GeminiGenerateContentRequest(
                    contents: [.init(parts: retryParts)],
                    generationConfig: .init(
                        maxOutputTokens: config.maxOutputTokens,
                        responseMimeType: "application/json",
                        mediaResolution: config.mediaResolution,
                        thinkingConfig: .init(thinkingLevel: config.thinkingLevel)
                    ),
                    cachedContent: nil
                )
                result = try await send(retryRequest, apiKey: apiKey, timeoutSeconds: config.timeoutSeconds)
            }
            writeDebugText(result.rawBody, imageHash: imageHash, suffix: "raw-response.json", laneName: debugName)
            guard let text = result.response.firstText else {
                NSLog("[ContextGeminiObservationService] \(lane.rawValue) lane response had no text candidate.")
                preserveFailureArtifacts(imageHash: imageHash, laneName: debugName, reason: "no text candidate")
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
            preserveFailureArtifacts(imageHash: imageHash, laneName: debugName, reason: "\(error)")
            return nil
        }
    }

    /// Text-only synthesis call that merges the parallel lane outputs into the
    /// final ContextGeminiObservation persisted to memory. Prefers Claude Haiku
    /// 4.5 (sub-2s for ~800 tokens of structured JSON); falls back to Gemini
    /// when no `ANTHROPIC_API_KEY` is configured or Claude errors out.
    public func reduceObservations(
        _ lanes: [ContextGeminiLaneObservation],
        trigger: ContextCaptureTrigger
    ) async throws -> ContextGeminiObservation {
        guard !lanes.isEmpty else {
            throw Error(status: nil, body: "reduceObservations called with no lanes", underlying: nil)
        }

        let lane = ContextGeminiObservationLane.reducer
        let imageHash = lanes.first?.imageHash ?? Self.sha256Hex(Data())
        let systemInstruction = Self.laneSystemInstruction(for: lane)
        let dynamicPrompt = Self.reducerDynamicPrompt(lanes: lanes, trigger: trigger)
        let fullPromptForDebug = "[SYSTEM INSTRUCTION]\n\(systemInstruction)\n\n[USER PROMPT]\n\(dynamicPrompt)"
        writeDebugText(fullPromptForDebug, imageHash: imageHash, suffix: "prompt.txt", laneName: lane.rawValue)
        let synthesizedInput = Self.synthesizedReducerInput(from: lanes)

        // Path A: Claude Haiku 4.5 — preferred when ANTHROPIC_API_KEY is set.
        if let anthropicKey = Secrets.anthropicAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !anthropicKey.isEmpty {
            let start = Date()
            do {
                let client = AnthropicClient(apiKey: anthropicKey, betaHeaders: [])
                let text = try await client.sendPlainText(
                    model: AnthropicModel.haiku45,
                    system: systemInstruction,
                    userText: dynamicPrompt,
                    maxTokens: 1500
                )
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                writeDebugText(text, imageHash: imageHash, suffix: "raw-response.json", laneName: lane.rawValue)
                writeDebugText(text, imageHash: imageHash, suffix: "raw-text.json", laneName: lane.rawValue)
                NSLog("[ContextGeminiObservationService] reducer path=claude model=\(AnthropicModel.haiku45) latencyMs=\(elapsedMs)")
                do {
                    return try Self.parseObservation(
                        text,
                        input: synthesizedInput,
                        imageHash: imageHash,
                        model: AnthropicModel.haiku45,
                        promptVersion: Self.promptVersion
                    )
                } catch {
                    writeDebugText("\(error)", imageHash: imageHash, suffix: "error.txt", laneName: lane.rawValue)
                    preserveFailureArtifacts(imageHash: imageHash, laneName: lane.rawValue, reason: "claude reducer parse error: \(error)")
                    NSLog("[ContextGeminiObservationService] reducer claude parse failed, falling back to gemini: \(error)")
                    // Fall through to Gemini.
                }
            } catch {
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                NSLog("[ContextGeminiObservationService] reducer claude failed after \(elapsedMs)ms, falling back to gemini: \(error)")
                // Fall through to Gemini.
            }
        } else {
            NSLog("[ContextGeminiObservationService] reducer path=gemini (ANTHROPIC_API_KEY not configured)")
        }

        // Path B: Gemini text-only fallback (original behaviour).
        let config = requestConfig(for: lane)
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw Error(status: nil, body: "GEMINI_API_KEY not configured (and Claude unavailable)", underlying: nil)
        }

        let cachedContentName = await ContextGeminiCacheManager.shared.cachedContentName(
            for: lane,
            model: model,
            promptVersion: Self.promptVersion,
            systemInstruction: systemInstruction,
            apiKey: apiKey
        )

        let textPrompt: String
        if cachedContentName != nil {
            textPrompt = dynamicPrompt
        } else {
            textPrompt = systemInstruction + "\n\n" + dynamicPrompt
        }

        let request = GeminiGenerateContentRequest(
            contents: [.init(parts: [.text(textPrompt)])],
            generationConfig: .init(
                maxOutputTokens: max(config.maxOutputTokens, 1200),
                responseMimeType: "application/json",
                mediaResolution: nil,
                thinkingConfig: .init(thinkingLevel: Self.defaultThinkingLevel)
            ),
            cachedContent: cachedContentName
        )

        let geminiStart = Date()
        let result: GeminiSendResult
        do {
            result = try await send(request, apiKey: apiKey, timeoutSeconds: 12)
        } catch let error as Error where Self.isCacheMiss(error) && cachedContentName != nil {
            NSLog("[ContextGeminiObservationService] Cached content miss for reducer; rebuilding without cache.")
            await ContextGeminiCacheManager.shared.invalidate(
                lane: lane,
                model: model,
                promptVersion: Self.promptVersion
            )
            let retryRequest = GeminiGenerateContentRequest(
                contents: [.init(parts: [.text(systemInstruction + "\n\n" + dynamicPrompt)])],
                generationConfig: .init(
                    maxOutputTokens: max(config.maxOutputTokens, 1200),
                    responseMimeType: "application/json",
                    mediaResolution: nil,
                    thinkingConfig: .init(thinkingLevel: Self.defaultThinkingLevel)
                ),
                cachedContent: nil
            )
            result = try await send(retryRequest, apiKey: apiKey, timeoutSeconds: 12)
        }

        writeDebugText(result.rawBody, imageHash: imageHash, suffix: "raw-response.json", laneName: lane.rawValue)
        guard let text = result.response.firstText else {
            preserveFailureArtifacts(imageHash: imageHash, laneName: lane.rawValue, reason: "reducer no text candidate")
            throw Error(status: nil, body: "reducer response had no text candidate", underlying: nil)
        }
        writeDebugText(text, imageHash: imageHash, suffix: "raw-text.json", laneName: lane.rawValue)
        let geminiElapsedMs = Int(Date().timeIntervalSince(geminiStart) * 1000)
        NSLog("[ContextGeminiObservationService] reducer path=gemini model=\(model) latencyMs=\(geminiElapsedMs)")

        do {
            return try Self.parseObservation(
                text,
                input: synthesizedInput,
                imageHash: imageHash,
                model: model,
                promptVersion: Self.promptVersion
            )
        } catch {
            writeDebugText("\(error)", imageHash: imageHash, suffix: "error.txt", laneName: lane.rawValue)
            preserveFailureArtifacts(imageHash: imageHash, laneName: lane.rawValue, reason: "reducer parse error: \(error)")
            throw error
        }
    }

    /// Lightweight "update existing surface" call. Sends the previous reducer
    /// observation as text plus the current screenshot, and asks Gemini to
    /// return ONLY the fields that changed. Returns nil if Gemini reports
    /// `summary: "no_change"`, the request fails, or the API key is missing.
    public func observeUpdate(
        previousObservation: ContextGeminiObservation,
        input: ContextGeminiObservationInput,
        thumbnailData: Data? = nil,
        cropData: Data? = nil
    ) async -> ContextGeminiLaneObservation? {
        let lane = ContextGeminiObservationLane.update
        let config = requestConfig(for: lane)
        let imageHash = Self.sha256Hex(input.imageData)
        let debugName = lane.rawValue

        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            NSLog("[ContextGeminiObservationService] GEMINI_API_KEY is not set; skipping update lane.")
            return nil
        }

        do {
            let useTwoImage = thumbnailData != nil && cropData != nil
            let systemInstruction = Self.laneSystemInstruction(for: lane, twoImage: useTwoImage)
            let dynamicPrompt = Self.updateLaneDynamicPrompt(
                previousObservation: previousObservation,
                input: input,
                twoImage: useTwoImage
            )
            let fullPromptForDebug = "[SYSTEM INSTRUCTION]\n\(systemInstruction)\n\n[USER PROMPT]\n\(dynamicPrompt)"
            writeDebugData(input.imageData, imageHash: imageHash, mimeType: input.mimeType, laneName: debugName)
            writeDebugText(requestMetadata(for: input, config: config, lane: lane), imageHash: imageHash, suffix: "request.txt", laneName: debugName)
            writeDebugText(fullPromptForDebug, imageHash: imageHash, suffix: "prompt.txt", laneName: debugName)

            let cachedContentName = await ContextGeminiCacheManager.shared.cachedContentName(
                for: lane,
                model: "gemini-3.1-flash-lite",
                promptVersion: Self.promptVersion + (useTwoImage ? "+2img" : ""),
                systemInstruction: systemInstruction,
                apiKey: apiKey
            )

            let textPrompt = cachedContentName != nil
                ? dynamicPrompt
                : systemInstruction + "\n\n" + dynamicPrompt
            let parts: [Part] = Self.buildUpdateParts(
                input: input,
                thumbnailData: thumbnailData,
                cropData: cropData,
                textPrompt: textPrompt
            )

            let request = GeminiGenerateContentRequest(
                contents: [.init(parts: parts)],
                generationConfig: .init(
                    maxOutputTokens: config.maxOutputTokens,
                    responseMimeType: "application/json",
                    mediaResolution: "MEDIA_RESOLUTION_HIGH",
                    thinkingConfig: .init(thinkingLevel: "minimal")
                ),
                cachedContent: cachedContentName
            )

            let result: GeminiSendResult
            do {
                result = try await send(request, apiKey: apiKey, timeoutSeconds: config.timeoutSeconds)
            } catch let error as Error where Self.isCacheMiss(error) && cachedContentName != nil {
                NSLog("[ContextGeminiObservationService] Cached content miss for update; rebuilding without cache.")
                await ContextGeminiCacheManager.shared.invalidate(
                    lane: lane,
                    model: "gemini-3.1-flash-lite",
                    promptVersion: Self.promptVersion + (useTwoImage ? "+2img" : "")
                )
                let retryParts = Self.buildUpdateParts(
                    input: input,
                    thumbnailData: thumbnailData,
                    cropData: cropData,
                    textPrompt: systemInstruction + "\n\n" + dynamicPrompt
                )
                let retryRequest = GeminiGenerateContentRequest(
                    contents: [.init(parts: retryParts)],
                    generationConfig: .init(
                        maxOutputTokens: config.maxOutputTokens,
                        responseMimeType: "application/json",
                        mediaResolution: "MEDIA_RESOLUTION_HIGH",
                        thinkingConfig: .init(thinkingLevel: "minimal")
                    ),
                    cachedContent: nil
                )
                result = try await send(retryRequest, apiKey: apiKey, timeoutSeconds: config.timeoutSeconds)
            }

            writeDebugText(result.rawBody, imageHash: imageHash, suffix: "raw-response.json", laneName: debugName)
            guard let text = result.response.firstText else {
                NSLog("[ContextGeminiObservationService] update lane response had no text candidate.")
                preserveFailureArtifacts(imageHash: imageHash, laneName: debugName, reason: "update lane no text candidate")
                return nil
            }
            writeDebugText(text, imageHash: imageHash, suffix: "raw-text.json", laneName: debugName)

            let trimmed = Self.cleanedJSONString(text)
            // Short-circuit explicit no-change marker.
            if let noChange = trimmed.data(using: .utf8),
               let payload = try? Self.decoder.decode(LaneObservationPayload.self, from: noChange),
               (payload.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "no_change" {
                return nil
            }

            return try Self.parseLaneObservation(
                text,
                lane: lane,
                input: input,
                imageHash: imageHash,
                model: model,
                promptVersion: Self.promptVersion
            )
        } catch {
            writeDebugText("\(error)", imageHash: imageHash, suffix: "error.txt", laneName: debugName)
            NSLog("[ContextGeminiObservationService] update lane failed: \(error)")
            preserveFailureArtifacts(imageHash: imageHash, laneName: debugName, reason: "\(error)")
            return nil
        }
    }

    /// Merge an update-lane delta into a previous reducer observation. Only
    /// non-empty fields from the delta overwrite or extend the base. Caller is
    /// responsible for persisting and re-logging the merged observation.
    public static func mergeUpdate(
        previous: ContextGeminiObservation,
        delta: ContextGeminiLaneObservation
    ) -> ContextGeminiObservation {
        var merged = previous
        merged.observedAt = delta.observedAt
        merged.imageHash = delta.imageHash
        merged.source = .gemini

        if let value = clean(delta.appLabel) { merged.appLabel = value }
        if let value = clean(delta.windowTitle) { merged.windowTitle = value }
        if let value = clean(delta.surfaceID) { merged.surfaceID = value }
        if let value = clean(delta.surfaceLabel) { merged.surfaceLabel = value }
        if let value = clean(delta.screenType) { merged.screenType = value }
        if let value = clean(delta.primaryTask) { merged.primaryTask = value }
        if let value = clean(delta.contentSummary) { merged.contentSummary = value }
        if let value = clean(delta.summary) { merged.summary = value }

        if !delta.layoutRegions.isEmpty {
            merged.layoutSummary = delta.layoutRegions.joined(separator: " | ")
            merged.landmarks = cleanStrings(delta.layoutRegions + previous.landmarks, maxCount: 16)
            merged.dataRegions = cleanStrings(delta.layoutRegions + previous.dataRegions, maxCount: 12)
        }
        if !delta.controls.isEmpty {
            merged.visibleControls = Array(uniqueControls(delta.controls + previous.visibleControls).prefix(24))
        }
        if !delta.entities.isEmpty {
            merged.entities = cleanStrings(delta.entities + previous.entities, maxCount: 24)
        }
        if !delta.stateIndicators.isEmpty {
            merged.stateIndicators = cleanStrings(delta.stateIndicators + previous.stateIndicators, maxCount: 12)
        }
        if !delta.workflows.isEmpty {
            merged.workflowHints = cleanStrings(delta.workflows + previous.workflowHints, maxCount: 12)
        }
        if !delta.navigation.isEmpty {
            merged.navigationPaths = cleanStrings(delta.navigation + previous.navigationPaths, maxCount: 12)
        }
        if !delta.negativeCues.isEmpty {
            merged.negativeCues = cleanStrings(delta.negativeCues + previous.negativeCues, maxCount: 12)
        }
        if !delta.memoryCards.isEmpty {
            merged.memoryCandidates = cleanStrings(delta.memoryCards + previous.memoryCandidates, maxCount: 16)
        }
        if !delta.uncertainty.isEmpty {
            merged.uncertainty = cleanStrings(delta.uncertainty + previous.uncertainty, maxCount: 12)
        }
        if delta.confidence.isFinite, delta.confidence > 0 {
            merged.confidence = clamp((previous.confidence + delta.confidence) / 2)
        }
        return merged
    }

    private static func isCacheMiss(_ error: Error) -> Bool {
        guard let status = error.status else { return false }
        if status == 404 { return true }
        if status == 400, let body = error.body?.lowercased(), body.contains("cached") {
            return true
        }
        return false
    }

    private static func synthesizedReducerInput(from lanes: [ContextGeminiLaneObservation]) -> ContextGeminiObservationInput {
        let appName = lanes.first(where: { !$0.appLabel.isEmpty })?.appLabel
        let windowTitle = lanes.first(where: { !$0.windowTitle.isEmpty })?.windowTitle
        return ContextGeminiObservationInput(
            imageData: Data(),
            mimeType: "text/plain",
            appName: appName,
            windowTitle: windowTitle
        )
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

    /// Copies the most-recent debug artifacts (raw-response, raw-text, prompt,
    /// error) for a failed lane call into `Debug/Failures/` with a timestamp
    /// prefix so a subsequent successful call for the same image hash does not
    /// overwrite the evidence. LRU-prunes to keep at most 50 failures.
    private func preserveFailureArtifacts(
        imageHash: String,
        laneName: String?,
        reason: String
    ) {
        let prefix = Self.debugArtifactPrefix(imageHash: imageHash, laneName: laneName)
        let failuresDir = debugDirectoryURL.appendingPathComponent("Failures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: failuresDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[ContextGeminiObservationService] Failed to create Failures dir: \(error)")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let ts = formatter
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffixes = ["raw-response.json", "raw-text.json", "prompt.txt", "error.txt", "request.txt"]
        for suffix in suffixes {
            let src = debugDirectoryURL.appendingPathComponent("\(prefix)-\(suffix)")
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = failuresDir.appendingPathComponent("\(ts)-\(prefix)-\(suffix)")
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                NSLog("[ContextGeminiObservationService] Failed to copy failure artifact \(suffix): \(error)")
            }
        }
        let reasonURL = failuresDir.appendingPathComponent("\(ts)-\(prefix)-reason.txt")
        try? reason.write(to: reasonURL, atomically: true, encoding: .utf8)
        pruneFailureArtifacts(in: failuresDir, keep: 50)
    }

    private func pruneFailureArtifacts(in directory: URL, keep: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        // Group by timestamp+prefix (everything before "-<suffix>"). We prune
        // by group so all related files for the oldest failures fall off
        // together; "keep" counts groups, not files.
        struct Entry { let url: URL; let mtime: Date; let stem: String }
        let known = ["raw-response.json", "raw-text.json", "prompt.txt", "error.txt", "request.txt", "reason.txt"]
        let entries: [Entry] = urls.compactMap { url in
            let name = url.lastPathComponent
            guard let suffix = known.first(where: { name.hasSuffix($0) }) else { return nil }
            let stem = String(name.dropLast(suffix.count))
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return Entry(url: url, mtime: mtime, stem: stem)
        }
        var groups: [String: (latest: Date, urls: [URL])] = [:]
        for entry in entries {
            var current = groups[entry.stem] ?? (Date.distantPast, [])
            current.urls.append(entry.url)
            if entry.mtime > current.latest { current.latest = entry.mtime }
            groups[entry.stem] = current
        }
        let sortedGroups = groups.sorted { $0.value.latest > $1.value.latest }
        guard sortedGroups.count > keep else { return }
        for (_, value) in sortedGroups.dropFirst(keep) {
            for url in value.urls {
                try? fm.removeItem(at: url)
            }
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
        let timeoutSeconds: TimeInterval
        switch lane {
        case .activity:
            laneMaxOutput = 900
            timeoutSeconds = 20
        case .uiMap:
            laneMaxOutput = 1200
            timeoutSeconds = 20
        case .entityContent:
            laneMaxOutput = 1000
            timeoutSeconds = 20
        case .interaction:
            laneMaxOutput = 800
            timeoutSeconds = 20
        case .reducer:
            laneMaxOutput = 900
            timeoutSeconds = 20
        case .update:
            laneMaxOutput = 600
            timeoutSeconds = 6
        case nil:
            laneMaxOutput = defaultMaxOutputTokens
            timeoutSeconds = 20
        }

        return GeminiObservationRequestConfig(
            mediaResolution: normalizedMediaResolution(mediaResolutionOverride) == defaultMediaResolution && mediaResolutionOverride == nil
                ? configuredMediaResolution
                : normalizedMediaResolution(mediaResolutionOverride),
            thinkingLevel: normalizedThinkingLevel(thinkingLevelOverride) == defaultThinkingLevel && thinkingLevelOverride == nil
                ? configuredThinkingLevel
                : normalizedThinkingLevel(thinkingLevelOverride),
            maxOutputTokens: laneMaxOutput,
            timeoutSeconds: timeoutSeconds
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

    /// Static, cacheable system instruction for a lane. Contains rules + lane goal
    /// + JSON schema — exactly the portions that don't change between calls and
    /// can be served from a Gemini cachedContents entry.
    private static func laneSystemInstruction(for lane: ContextGeminiObservationLane, twoImage: Bool = false) -> String {
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

            CRITICAL — format each entry in the `entities` array as `"<label> [<type>]"` where <type> is exactly one of:
            person, file, url, app, ticket, record, error, message, document, account, folder, project, command, other.
            Examples: "Mara Lee [person]", "src/auth/oauth.ts [file]", "stackoverflow.com/q/123 [url]", "AUTH-412 [ticket]", "TokenExpiredError [error]", "Untitled Notion doc [document]".
            NEVER emit a bare label without the bracketed type. If you genuinely cannot classify, use "[other]" — but try first.

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


            Lane goal: explain what the user just did by comparing two screenshots taken moments apart.

            You will receive exactly TWO images, in order:
            - The FIRST image is the PREVIOUS screen, captured roughly a few seconds ago (the user prompt will include the exact elapsed time).
            - The SECOND image is the CURRENT screen, captured immediately after the user's action (a click, app switch, or manual capture trigger).

            Both images are full-display screenshots from the same Mac. The OCR text recap in the user prompt is supplemental context — the pixel diff between the FIRST and SECOND images is the primary signal.

            Your job:
            1. Identify the exact UI change between the FIRST and SECOND images: which region of the screen changed, what was added, removed, toggled, opened, or selected.
            2. Characterize the user's apparent action operationally. Do NOT say "the screen changed". Say what the user did and what the UI did in response. Example: "user clicked the second chat thread in the left sidebar, which revealed a new conversation in the main panel" or "user switched apps from Safari to Xcode, surfacing the editor tab they last had open".
            3. Note whether the action looks successful, failed, or ambiguous (e.g., "click landed but no panel opened — possible no-op").
            4. Record reusable navigation/workflow knowledge that the agent should remember (e.g., "the gear icon in the top-right opens preferences").

            Put your concise one-sentence narrative of the action into the `summary` field as a single string (this is the `interaction_summary`). Use the remaining structured fields to capture the durable workflow/navigation/state facts.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType,
            summary: string — the interaction_summary, one sentence framed as "user did X, which caused Y"
            primaryTask,
            workflows: [string],
            navigation: [string],
            stateIndicators: [string],
            negativeCues: [string],
            memoryCards: [string],
            uncertainty: [string],
            confidence: number

            Never re-describe the entire screen. Focus only on what is different between FIRST and SECOND, and what that difference implies operationally.
            """
        case .update:
            if twoImage {
                return """
                You are updating an existing UI/UX observation. You will receive:
                1. The previous structured observation of this surface (as JSON in the user prompt).
                2. The FIRST image: a downscaled thumbnail of the full screen. Use this ONLY for orientation — to confirm which app/surface you're on.
                3. The SECOND image: a high-resolution crop of the region that changed since the previous observation. Focus your analysis here.

                Your job: identify what has CHANGED inside the cropped region and return ONLY the delta — a partial observation containing fields that genuinely differ. Do NOT re-describe everything visible in the thumbnail. Examples of legitimate updates: a new notification banner appeared, a button toggled state, a value in a text field changed, a panel opened/closed, a row was added to a table.

                Output JSON matching the ContextGeminiLaneObservation schema, but include ONLY the fields that changed. For fields you're not updating, omit them entirely (don't set to empty). Region names in `visibleControls.region` must be semantic ("footer", "sidebar", "top-right") — never pixel coordinates.

                If the crop shows no meaningful change, output: {"lane":"update","summary":"no_change"}.
                """
            }
            return """
            You are updating an existing UI/UX observation. You will receive:
            1. A previous structured observation of the same surface (as JSON).
            2. A current screenshot of the (mostly unchanged) screen.

            Your job: identify what has CHANGED since the previous observation and return ONLY the delta — a partial observation containing fields that genuinely differ. Do NOT re-describe everything. Examples of legitimate updates: a new notification banner appeared, a button toggled state, a value in a text field changed, a panel opened/closed, a row was added to a table.

            Output JSON matching the ContextGeminiLaneObservation schema, but include ONLY the fields that changed. For fields you're not updating, omit them entirely (don't set to empty). Region names in `visibleControls.region` must be semantic ("footer", "sidebar", "top-right") — never pixel coordinates.

            If you genuinely see no meaningful change, output: {"lane":"update","summary":"no_change"}.
            """
        case .reducer:
            return """
            You are the reducer stage of a modular screen-understanding pipeline for a macOS computer-use agent.
            You receive structured JSON outputs from parallel lanes (activity, uiMap, entityContent, optionally interaction). Your job is to synthesize a single coherent observation that will be persisted as the agent's UI memory.

            Rules:
            - Merge overlapping facts; keep the strongest, most specific phrasing.
            - Resolve conflicts by preferring whichever lane is closest to the topic (uiMap for controls/layout, activity for task/state, entityContent for entities/content, interaction for transitions).
            - Drop generic filler. Keep operational, action-relevant facts.
            - Return strict JSON only.

            JSON fields:
            appLabel, windowTitle, surfaceID, surfaceLabel, screenType, summary, primaryTask, layoutSummary, contentSummary,
            visibleControls: [{ "label": string, "role": string, "region": string, "actionHint": string, "confidence": number }],
            landmarks: [string],
            entities: [string],
            affordances: [string],
            stateIndicators: [string],
            navigationPaths: [string],
            dataRegions: [string],
            workflowHints: [string],
            negativeCues: [string],
            memoryCandidates: [string],
            uncertainty: [string],
            confidence: number

            Keep landmarks <= 16, entities <= 24, visibleControls <= 20, and other arrays <= 12.
            """
        }
    }

    /// Dynamic per-call user prompt for a lane. Contains the metadata and previous-screen OCR
    /// recap that change every call and must not be cached.
    private static func laneDynamicPrompt(
        for lane: ContextGeminiObservationLane,
        input: ContextGeminiObservationInput,
        previousSnapshot: ContextSnapshot?
    ) -> String {
        let metadata = metadataLines(for: input)
        let previous = previousSnapshot.map(previousSnapshotLines) ?? "- No previous screen supplied."

        switch lane {
        case .interaction:
            return """
            Metadata for the CURRENT (SECOND) screen:
            \(metadata)

            Recap of the PREVIOUS (FIRST) screen:
            \(previous)

            Produce the strict JSON described in the system instruction. Reference the FIRST and SECOND images explicitly when describing what changed.
            """
        case .reducer:
            return """
            Metadata for the active screen:
            \(metadata)

            Previous screen recap:
            \(previous)

            Synthesize the lane outputs into the strict JSON described in the system instruction.
            """
        default:
            return """
            Metadata:
            \(metadata)

            Previous screen for interaction reasoning:
            \(previous)

            Produce the strict JSON described in the system instruction.
            """
        }
    }

    /// User prompt for the update lane. Embeds the previous reducer observation
    /// as compact JSON-style text so Gemini can compare it against the current
    /// screenshot and return only deltas.
    private static func updateLaneDynamicPrompt(
        previousObservation: ContextGeminiObservation,
        input: ContextGeminiObservationInput,
        twoImage: Bool = false
    ) -> String {
        let metadata = metadataLines(for: input)
        let previousJSON = serializePreviousObservationForUpdate(previousObservation)
        let imagesNote = twoImage
            ? "Two images attached. FIRST is a thumbnail for orientation; SECOND is the high-res crop of the changed region."
            : "The current full screenshot follows as the only image."
        return """
        Metadata for the current screen:
        \(metadata)

        Previous structured observation of this same surface (JSON):
        \(previousJSON)

        \(imagesNote) Identify what changed since the previous observation and return ONLY the delta as JSON per the system instruction. If nothing meaningful changed, return {"lane":"update","summary":"no_change"}.
        """
    }

    /// Build the `parts` array for an update lane request. When both a
    /// thumbnail and a crop are supplied, sends them in the order the prompt
    /// expects (thumbnail first, crop second). Falls back to the full image
    /// when either is missing.
    private static func buildUpdateParts(
        input: ContextGeminiObservationInput,
        thumbnailData: Data?,
        cropData: Data?,
        textPrompt: String
    ) -> [Part] {
        if let thumbnailData, let cropData {
            return [
                .inlineData(mimeType: "image/png", data: thumbnailData.base64EncodedString()),
                .inlineData(mimeType: "image/png", data: cropData.base64EncodedString()),
                .text(textPrompt)
            ]
        }
        return [
            .inlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()),
            .text(textPrompt)
        ]
    }

    private static func serializePreviousObservationForUpdate(_ observation: ContextGeminiObservation) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(observation), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    /// User prompt for the reducer call. Includes the lane outputs serialized as text.
    private static func reducerDynamicPrompt(
        lanes: [ContextGeminiLaneObservation],
        trigger: ContextCaptureTrigger
    ) -> String {
        let serialized = lanes.map { lane in
            laneSummaryForReducer(lane)
        }.joined(separator: "\n\n")

        let appHint = lanes.first(where: { !$0.appLabel.isEmpty })?.appLabel ?? "unknown"
        let windowHint = lanes.first(where: { !$0.windowTitle.isEmpty })?.windowTitle ?? "unknown"

        return """
        Capture trigger: \(trigger.rawValue)
        App hint: \(appHint)
        Window hint: \(windowHint)

        Lane outputs to merge:
        \(serialized)

        Synthesize a single ContextGeminiObservation JSON object per the schema in the system instruction. Prefer specifics from the lane closest to each topic (uiMap for controls/layout, activity for task/state, entityContent for entities, interaction for transitions). Drop generic filler.
        """
    }

    private static func laneSummaryForReducer(_ lane: ContextGeminiLaneObservation) -> String {
        let controls = lane.controls.prefix(12).map { control -> String in
            let hint = control.actionHint?.isEmpty == false ? " — \(control.actionHint ?? "")" : ""
            return "    - \(control.label) [\(control.role) @ \(control.region)]\(hint)"
        }.joined(separator: "\n")

        let sections: [String] = [
            "[\(lane.lane.rawValue)] confidence=\(String(format: "%.2f", lane.confidence)) source=\(lane.source.rawValue)",
            "  appLabel: \(lane.appLabel)",
            "  windowTitle: \(lane.windowTitle)",
            "  surfaceID: \(lane.surfaceID)",
            "  surfaceLabel: \(lane.surfaceLabel)",
            "  screenType: \(lane.screenType)",
            "  summary: \(lane.summary)",
            "  primaryTask: \(lane.primaryTask)",
            "  contentSummary: \(lane.contentSummary)",
            "  layoutRegions: \(lane.layoutRegions.joined(separator: " | "))",
            "  controls:\n\(controls)",
            "  entities: \(lane.entities.joined(separator: " | "))",
            "  stateIndicators: \(lane.stateIndicators.joined(separator: " | "))",
            "  workflows: \(lane.workflows.joined(separator: " | "))",
            "  navigation: \(lane.navigation.joined(separator: " | "))",
            "  negativeCues: \(lane.negativeCues.joined(separator: " | "))",
            "  memoryCards: \(lane.memoryCards.joined(separator: " | "))",
            "  uncertainty: \(lane.uncertainty.joined(separator: " | "))"
        ]
        return sections.joined(separator: "\n")
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
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// `<shortHash>-<slug>` — the filename prefix used inside Debug/. Suitable
    /// for embedding in events so a UI consumer can re-derive paths on demand
    /// without holding the full file paths in memory.
    public var artifactPrefix: String {
        // promptPath = <dir>/<prefix>-prompt.txt — strip both ends to recover it.
        let leaf = (promptPath as NSString).lastPathComponent
        if leaf.hasSuffix("-prompt.txt") {
            return String(leaf.dropLast("-prompt.txt".count))
        }
        return leaf
    }
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
    var cachedContent: String? = nil

    struct Content: Encodable {
        var parts: [Part]
    }

    struct GenerationConfig: Encodable {
        var maxOutputTokens: Int
        var responseMimeType: String
        var mediaResolution: String?
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
