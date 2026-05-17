//
//  AgentRunMetrics.swift
//  Agent in the Notch
//

import Foundation

public struct AgentRunMetricsRecord: Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let durationMs: Int
    public let modelID: String
    public let fallbackModelID: String
    public let usedFallback: Bool
    public let transcriptLength: Int
    public let contextLength: Int
    public let contextIncluded: Bool
    public let turnCount: Int
    public let toolCallCount: Int
    public let screenshotToolCallCount: Int
    public let actionCounts: [String: Int]
    public let timeToFirstToolCallMs: Int?
    public let timeToFirstNonScreenshotActionMs: Int?
    public let finalStatus: String
    public let errorMessage: String?
}

private let metricsEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys]
    return e
}()

public func printRunMetrics(_ r: AgentRunMetricsRecord) {
    if let data = try? metricsEncoder.encode(r), let json = String(data: data, encoding: .utf8) {
        print("[INFO]  [metrics] run \(json)")
    }
    Task { await AgentRunMetricsStore.shared.append(r) }
}

public actor AgentRunMetricsStore {
    public static let shared = AgentRunMetricsStore()

    public let capacity: Int
    private var buffer: [AgentRunMetricsRecord] = []

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    public func append(_ record: AgentRunMetricsRecord) {
        buffer.append(record)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// Newest first.
    public func recentRuns(limit: Int = 50) -> [AgentRunMetricsRecord] {
        let slice = buffer.suffix(min(limit, buffer.count))
        return Array(slice.reversed())
    }

    public func clear() {
        buffer.removeAll()
    }
}

// MARK: - Per-turn harness detail

/// One Anthropic request/response inside a multi-turn harness run. Captures
/// usage tokens so prompt caching can be verified end to end, plus the tool
/// calls the model emitted that turn and a preview of their results.
public struct HarnessTurnRecord: Sendable, Identifiable {
    public let id: UUID
    public let turnIndex: Int
    public let model: String
    public let requestedAt: Date
    public let respondedAt: Date?
    public let stopReason: String?
    /// Anthropic usage (from response.usage). cache_read_input_tokens +
    /// cache_creation_input_tokens confirm prompt caching is firing.
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let toolCalls: [ToolCallRecord]

    public init(
        id: UUID = UUID(),
        turnIndex: Int,
        model: String,
        requestedAt: Date,
        respondedAt: Date?,
        stopReason: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadInputTokens: Int?,
        cacheCreationInputTokens: Int?,
        toolCalls: [ToolCallRecord]
    ) {
        self.id = id
        self.turnIndex = turnIndex
        self.model = model
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.toolCalls = toolCalls
    }

    public struct ToolCallRecord: Sendable, Identifiable {
        public let id: String
        public let name: String
        /// Pretty-printed compact JSON of the tool input.
        public let inputSummary: String
        /// For the `computer` tool, the inner action label (click, type, …).
        public let action: String?
        public let resultIsError: Bool
        /// First ~200 chars of tool result content.
        public let resultTextPreview: String

        public init(
            id: String,
            name: String,
            inputSummary: String,
            action: String?,
            resultIsError: Bool,
            resultTextPreview: String
        ) {
            self.id = id
            self.name = name
            self.inputSummary = inputSummary
            self.action = action
            self.resultIsError = resultIsError
            self.resultTextPreview = resultTextPreview
        }
    }
}

/// Full per-run harness payload: system blocks at request time, transcript,
/// resolved intent verb, and the per-turn timeline. `turns` and `finalStatus`
/// mutate as the run progresses; everything else is set once at startRun.
public struct HarnessRunDetail: Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public let transcript: String
    public let systemBlocks: [SystemBlockSummary]
    public let resolvedIntentVerb: String?
    public var turns: [HarnessTurnRecord]
    public var finalStatus: String?

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        transcript: String,
        systemBlocks: [SystemBlockSummary],
        resolvedIntentVerb: String?,
        turns: [HarnessTurnRecord] = [],
        finalStatus: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
        self.systemBlocks = systemBlocks
        self.resolvedIntentVerb = resolvedIntentVerb
        self.turns = turns
        self.finalStatus = finalStatus
    }

    public struct SystemBlockSummary: Sendable {
        public let cached: Bool
        public let charCount: Int
        /// First 240 chars of the block text.
        public let preview: String

        public init(cached: Bool, charCount: Int, preview: String) {
            self.cached = cached
            self.charCount = charCount
            self.preview = preview
        }
    }
}

/// In-memory ring of the last `capacity` harness runs, with the per-turn
/// payload the Dev Tools "Harness Detail" pane needs to verify prompt caching
/// and inspect tool dispatch.
public actor HarnessRunDetailStore {
    public static let shared = HarnessRunDetailStore()

    public let capacity: Int
    private var runs: [HarnessRunDetail] = []

    public init(capacity: Int = 10) {
        self.capacity = capacity
    }

    public func startRun(_ detail: HarnessRunDetail) {
        runs.append(detail)
        if runs.count > capacity {
            runs.removeFirst(runs.count - capacity)
        }
    }

    public func appendTurn(runID: UUID, turn: HarnessTurnRecord) {
        guard let idx = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[idx].turns.append(turn)
    }

    public func finalizeRun(runID: UUID, endedAt: Date, finalStatus: String) {
        guard let idx = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[idx].endedAt = endedAt
        runs[idx].finalStatus = finalStatus
    }

    /// Newest first.
    public func recentRuns(limit: Int = 5) -> [HarnessRunDetail] {
        let take = min(max(limit, 0), runs.count)
        guard take > 0 else { return [] }
        return Array(runs.suffix(take).reversed())
    }

    public func clear() {
        runs.removeAll()
    }
}
