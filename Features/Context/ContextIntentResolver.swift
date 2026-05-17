//
//  ContextIntentResolver.swift
//  Agent in the Notch
//
//  Pre-resolves "what does the user mean" before the computer-use agent runs.
//  A cheap Haiku pass converts (transcript + UI memory) into a typed
//  ContextResolvedIntent so the harness doesn't have to re-derive who/what/where
//  from scratch. Falls back to a structural guess on timeout/parse failure.
//

import Foundation
import CryptoKit

// MARK: - Public types

public struct ContextResolvedIntent: Codable, Sendable {
    public let verb: String
    public let target: String?
    public let resolvedEntities: [ContextEntityResolution]
    public let candidateRecipes: [ContextRecipeMatch]
    public let inferredGoal: String
    public let confidence: Double
    public let resolverLatencyMs: Int
    public let usedFallback: Bool

    public init(
        verb: String,
        target: String?,
        resolvedEntities: [ContextEntityResolution],
        candidateRecipes: [ContextRecipeMatch],
        inferredGoal: String,
        confidence: Double,
        resolverLatencyMs: Int,
        usedFallback: Bool
    ) {
        self.verb = verb
        self.target = target
        self.resolvedEntities = resolvedEntities
        self.candidateRecipes = candidateRecipes
        self.inferredGoal = inferredGoal
        self.confidence = confidence
        self.resolverLatencyMs = resolverLatencyMs
        self.usedFallback = usedFallback
    }
}

public struct ContextEntityResolution: Codable, Sendable {
    public let userPhrase: String
    public let entityID: String?
    public let entityLabel: String?
    public let entityType: String?
    public let confidence: Double
    public let evidence: String

    public init(
        userPhrase: String,
        entityID: String?,
        entityLabel: String?,
        entityType: String?,
        confidence: Double,
        evidence: String
    ) {
        self.userPhrase = userPhrase
        self.entityID = entityID
        self.entityLabel = entityLabel
        self.entityType = entityType
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct ContextRecipeMatch: Codable, Sendable {
    public let recipeID: String
    public let recipeName: String
    public let appKey: String
    public let fromSurfaceID: String?
    public let stepsProse: [String]
    public let matchScore: Double

    public init(
        recipeID: String,
        recipeName: String,
        appKey: String,
        fromSurfaceID: String?,
        stepsProse: [String],
        matchScore: Double
    ) {
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.appKey = appKey
        self.fromSurfaceID = fromSurfaceID
        self.stepsProse = stepsProse
        self.matchScore = matchScore
    }
}

// MARK: - Resolver

public actor ContextIntentResolver {
    public static let shared = ContextIntentResolver()

    public var model: String = AnthropicModel.haiku45
    public var maxTokens: Int = 600
    public var timeoutSeconds: TimeInterval = 2.5

    private struct CacheEntry {
        let intent: ContextResolvedIntent
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheCapacity = 64
    private let cacheTTL: TimeInterval = 300

    public init() {}

    public func resolve(
        transcript: String,
        currentApp: String?,
        currentSurfaceID: String?,
        appMemory: ContextAppMemory?,
        globalMemorySummary: String?
    ) async -> ContextResolvedIntent {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = makeCacheKey(
            transcript: trimmed,
            currentSurfaceID: currentSurfaceID,
            appMemory: appMemory
        )
        if let cached = cache[cacheKey], Date().timeIntervalSince(cached.storedAt) < cacheTTL {
            return cached.intent
        }

        let startedAt = Date()
        let fallback: () -> ContextResolvedIntent = { [self] in
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            return Self.structuralFallback(transcript: trimmed, latencyMs: latency)
        }

        guard !trimmed.isEmpty else {
            let intent = fallback()
            store(intent, key: cacheKey)
            return intent
        }

        guard let apiKey = Secrets.anthropicAPIKey else {
            let intent = fallback()
            store(intent, key: cacheKey)
            return intent
        }

        let client = AnthropicClient(apiKey: apiKey, betaHeaders: [])
        let memorySection = Self.renderMemorySection(appMemory: appMemory)
        let recipeHints = Self.renderRecipeHints(appMemory: appMemory, currentSurfaceID: currentSurfaceID)
        let globalSection = (globalMemorySummary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "(none)"

        let systemPrompt = Self.systemPrompt
        let userMessage = Self.buildUserMessage(
            transcript: trimmed,
            currentApp: currentApp,
            currentSurfaceID: currentSurfaceID,
            memorySection: memorySection,
            recipeHints: recipeHints,
            globalSection: globalSection
        )

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxTokens,
            system: [SystemBlock(text: systemPrompt)],
            messages: [Message(role: "user", content: [.text(userMessage)])],
            tools: [],
            toolChoice: nil
        )

        let intent: ContextResolvedIntent
        do {
            let response = try await withTimeout(seconds: timeoutSeconds) {
                try await client.send(request)
            }
            let latency = Int(Date().timeIntervalSince(startedAt) * 1000)
            let rawText = response.content.compactMap { block -> String? in
                if case .text(let t) = block { return t } else { return nil }
            }.joined(separator: "\n")
            if let parsed = Self.parseIntent(from: rawText, latencyMs: latency) {
                intent = parsed
            } else {
                NSLog("[ContextIntentResolver] Failed to parse Haiku JSON, using fallback. Raw: \(rawText.prefix(400))")
                intent = fallback()
            }
        } catch {
            NSLog("[ContextIntentResolver] Resolver failed (\(error)), using fallback.")
            intent = fallback()
        }

        store(intent, key: cacheKey)
        return intent
    }

    private func store(_ intent: ContextResolvedIntent, key: String) {
        cache[key] = CacheEntry(intent: intent, storedAt: Date())
        if cache.count > cacheCapacity {
            // Drop oldest entries.
            let sorted = cache.sorted { $0.value.storedAt < $1.value.storedAt }
            let drop = sorted.prefix(cache.count - cacheCapacity)
            for (key, _) in drop {
                cache.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Prompt + memory rendering

    public static let systemPrompt: String = """
    You are a fast intent-resolution layer that runs BEFORE a macOS computer-use agent. \
    You receive a user voice transcript plus pre-computed UI memory (the apps and surfaces the user has touched recently, with learned controls and entities). \
    Your job is to extract: \
    (1) the action verb the user wants (e.g. "send", "open", "switch", "search", "find", "create", "reply", "share"); \
    (2) the literal target as the user phrased it (e.g. "this", "the design doc", "Mara's chat") — keep the user's words; \
    (3) any entities mentioned (people, files, apps, surfaces) and try to match them to entries in the provided UI memory; \
    (4) up to 3 candidate "recipes" — sequences of UI steps from the memory that could plausibly accomplish the goal, ranked by match score; \
    (5) a one-sentence inferred goal that names the verb, the object, and (if relevant) the recipient or destination. \
    Output STRICT JSON only — no prose, no markdown fences, no commentary. Match this schema exactly:
    {
      "verb": "string",
      "target": "string or null",
      "resolvedEntities": [
        { "userPhrase": "string", "entityID": "string or null", "entityLabel": "string or null", "entityType": "person|file|app|surface|other or null", "confidence": 0.0, "evidence": "string" }
      ],
      "candidateRecipes": [
        { "recipeID": "string", "recipeName": "string", "appKey": "string", "fromSurfaceID": "string or null", "stepsProse": ["string"], "matchScore": 0.0 }
      ],
      "inferredGoal": "string",
      "confidence": 0.0
    }
    Rules: confidence values are between 0 and 1. If the transcript is vague (e.g. just "send this"), still extract the verb and a best-guess target, and rely on UI memory to fill in entities. If memory is empty or unhelpful, return empty arrays for resolvedEntities and candidateRecipes — never invent IDs. Use empty arrays, not null, for the array fields. Keep stepsProse short (3-6 imperatives). Never emit anything outside the JSON object.
    """

    private static func buildUserMessage(
        transcript: String,
        currentApp: String?,
        currentSurfaceID: String?,
        memorySection: String,
        recipeHints: String,
        globalSection: String
    ) -> String {
        let app = currentApp?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(unknown)"
        let surface = currentSurfaceID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(unknown)"
        return """
        TRANSCRIPT:
        \(transcript)

        CURRENT APP: \(app)
        CURRENT SURFACE ID: \(surface)

        APP UI MEMORY:
        \(memorySection)

        RECIPE HINTS (transitions observed on this app):
        \(recipeHints)

        GLOBAL CROSS-APP CONTEXT:
        \(globalSection)

        Return the JSON object now. No other text.
        """
    }

    private static func renderMemorySection(appMemory: ContextAppMemory?) -> String {
        guard let memory = appMemory else { return "(no app memory)" }
        var lines: [String] = []
        lines.append("App: \(memory.appName)")
        let surfaces = memory.surfaces
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(6)
        for surface in surfaces {
            lines.append("Surface[id=\(surface.id), title=\(surface.title)]")
            let controls = surface.controlHighlights.prefix(8)
            if !controls.isEmpty {
                lines.append("  Controls: \(controls.joined(separator: " | "))")
            }
            let entities = surface.entities.prefix(8).map(\.text)
            if !entities.isEmpty {
                lines.append("  Entities: \(entities.joined(separator: " | "))")
            }
            let semantic = surface.semanticHighlights.prefix(3)
            if !semantic.isEmpty {
                lines.append("  Notes: \(semantic.joined(separator: " | "))")
            }
        }
        if lines.count == 1 {
            lines.append("(no surfaces learned yet)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderRecipeHints(appMemory: ContextAppMemory?, currentSurfaceID: String?) -> String {
        guard let memory = appMemory else { return "(none)" }
        let transitions = memory.transitions
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(8)
        if transitions.isEmpty { return "(none)" }
        return transitions.map { t in
            let from = t.fromTitle.isEmpty ? t.fromSurfaceID : t.fromTitle
            let to = t.toTitle.isEmpty ? t.toSurfaceID : t.toTitle
            return "- \(from) → \(to) [trigger=\(t.trigger.rawValue), evidence=\(t.evidenceCount), id=\(t.id)]"
        }.joined(separator: "\n")
    }

    // MARK: - JSON parsing

    private static func parseIntent(from raw: String, latencyMs: Int) -> ContextResolvedIntent? {
        let stripped = extractJSON(from: raw)
        guard let data = stripped.data(using: .utf8) else { return nil }
        struct RawIntent: Decodable {
            let verb: String?
            let target: String?
            let resolvedEntities: [ContextEntityResolution]?
            let candidateRecipes: [ContextRecipeMatch]?
            let inferredGoal: String?
            let confidence: Double?
        }
        do {
            let raw = try JSONDecoder().decode(RawIntent.self, from: data)
            let verb = raw.verb?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "do"
            let target = raw.target?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let goal = raw.inferredGoal?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? verb
            let confidence = max(0.0, min(1.0, raw.confidence ?? 0.5))
            return ContextResolvedIntent(
                verb: verb,
                target: target,
                resolvedEntities: raw.resolvedEntities ?? [],
                candidateRecipes: Array((raw.candidateRecipes ?? []).prefix(3)),
                inferredGoal: goal,
                confidence: confidence,
                resolverLatencyMs: latencyMs,
                usedFallback: false
            )
        } catch {
            return nil
        }
    }

    private static func extractJSON(from raw: String) -> String {
        // Strip code fences if the model decided to wrap output.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceRange.lowerBound])
            }
        }
        // Trim to outermost { ... }.
        if let firstBrace = text.firstIndex(of: "{"),
           let lastBrace = text.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            return String(text[firstBrace...lastBrace])
        }
        return text
    }

    // MARK: - Fallback

    private static func structuralFallback(transcript: String, latencyMs: Int) -> ContextResolvedIntent {
        let verb = guessVerb(in: transcript)
        let goal = transcript.isEmpty ? verb : transcript
        return ContextResolvedIntent(
            verb: verb,
            target: nil,
            resolvedEntities: [],
            candidateRecipes: [],
            inferredGoal: goal,
            confidence: 0.0,
            resolverLatencyMs: latencyMs,
            usedFallback: true
        )
    }

    private static let knownVerbs: Set<String> = [
        "send", "open", "switch", "search", "find", "create", "reply", "share",
        "close", "show", "play", "pause", "type", "click", "scroll", "delete",
        "copy", "paste", "save", "navigate", "go", "make", "add", "remove",
        "summarize", "explain", "read", "write", "draft", "schedule", "book",
        "email", "message", "call", "post", "tweet", "translate", "fix", "run"
    ]

    private static func guessVerb(in transcript: String) -> String {
        let tokens = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for token in tokens {
            if knownVerbs.contains(token) {
                return token
            }
        }
        return tokens.first ?? "do"
    }

    // MARK: - Caching

    private func makeCacheKey(
        transcript: String,
        currentSurfaceID: String?,
        appMemory: ContextAppMemory?
    ) -> String {
        let surface = currentSurfaceID ?? ""
        let memoryStamp = appMemory.map { iso8601.string(from: $0.lastSeen) } ?? ""
        let combined = "\(transcript)|\(surface)|\(memoryStamp)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var iso8601: ISO8601DateFormatter { Self.iso8601 }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ContextIntentResolverError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum ContextIntentResolverError: Error {
    case timeout
}

// MARK: - String helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Outcome log (for offline evaluation)

public actor ContextIntentResolverOutcomeLog {
    public static let shared = ContextIntentResolverOutcomeLog()

    private let fileURL: URL
    private let maxEntries: Int = 500

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentNotch", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("IntentResolverLog.jsonl")
        }
    }

    public struct Outcome: Codable, Sendable {
        public let recordedAt: Date
        public let transcript: String
        public let intent: ContextResolvedIntent
        public let harnessStatus: String
        public let harnessErrorMessage: String?
        public let harnessDurationMs: Int?

        public init(
            recordedAt: Date,
            transcript: String,
            intent: ContextResolvedIntent,
            harnessStatus: String,
            harnessErrorMessage: String?,
            harnessDurationMs: Int?
        ) {
            self.recordedAt = recordedAt
            self.transcript = transcript
            self.intent = intent
            self.harnessStatus = harnessStatus
            self.harnessErrorMessage = harnessErrorMessage
            self.harnessDurationMs = harnessDurationMs
        }
    }

    public func record(_ outcome: Outcome) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(outcome) else { return }
        var bytes = data
        bytes.append(0x0A)

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } else {
                try bytes.write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("[ContextIntentResolverOutcomeLog] Failed to append outcome: \(error)")
            return
        }

        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxEntries else { return }
        let kept = lines.suffix(maxEntries)
        let rewritten = kept.joined(separator: "\n") + "\n"
        try? rewritten.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
