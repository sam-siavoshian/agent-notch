import Foundation

/// Central in-memory ring buffer (cap 500) capturing the full back-and-forth between
/// the user, the context system (Mercury), and the action agent (Claude). The DevTools
/// timeline view reads from this. Thread-safe via DispatchQueue.
public final class AgentObservabilityLog {

    public static let shared = AgentObservabilityLog()

    public enum Event: Identifiable {
        case longPressTranscript(id: UUID, t: Date, transcript: String)
        case l2Snapshot(id: UUID, t: Date, app: String, window: String?, axElementCount: Int, ocrLineCount: Int, screenshotJPEG: Data?)
        case selectorRun(id: UUID, t: Date, latencyS: Double, degraded: Bool, model: String?, intentVerb: String, intentTarget: String?, briefLength: Int)
        case mercuryCall(id: UUID, t: Date, role: MercuryRole, requestSummary: String, responseSummary: String, latencyS: Double, success: Bool, promptTokens: Int?, completionTokens: Int?)
        case geminiCall(id: UUID, t: Date, model: String, promptPreview: String, imageBytes: Int, responsePreview: String, latencyS: Double, success: Bool, httpStatus: Int?)
        case harnessTurn(id: UUID, t: Date, turnIndex: Int, modelID: String, systemBlocksPreview: String, userContentPreview: String, assistantPreview: String, toolCalls: [ToolCallSummary], inputTokens: Int?, outputTokens: Int?, latencyS: Double)
        case memoryMutation(id: UUID, t: Date, kind: MutationKind, summary: String)

        public var id: UUID {
            switch self {
            case .longPressTranscript(let id, _, _),
                 .l2Snapshot(let id, _, _, _, _, _, _),
                 .selectorRun(let id, _, _, _, _, _, _, _),
                 .mercuryCall(let id, _, _, _, _, _, _, _, _),
                 .geminiCall(let id, _, _, _, _, _, _, _, _),
                 .harnessTurn(let id, _, _, _, _, _, _, _, _, _, _),
                 .memoryMutation(let id, _, _, _):
                return id
            }
        }

        public var timestamp: Date {
            switch self {
            case .longPressTranscript(_, let t, _),
                 .l2Snapshot(_, let t, _, _, _, _, _),
                 .selectorRun(_, let t, _, _, _, _, _, _),
                 .mercuryCall(_, let t, _, _, _, _, _, _, _),
                 .geminiCall(_, let t, _, _, _, _, _, _, _),
                 .harnessTurn(_, let t, _, _, _, _, _, _, _, _, _),
                 .memoryMutation(_, let t, _, _):
                return t
            }
        }
    }

    public enum MercuryRole: String { case selector, activeTaskUpdater, recipeNaming, other }
    public enum MutationKind: String {
        case activeTaskUpdated, activeTaskArchived, recipePromoted, recipeCandidateAdded, shortcutLearned, resourceRecorded
    }

    public struct ToolCallSummary {
        public let toolName: String
        public let argumentsPreview: String     // first 200 chars
        public let resultPreview: String        // first 200 chars (e.g. "screenshot 1024x768" or text)
        public let durationS: Double?

        public init(toolName: String, argumentsPreview: String, resultPreview: String, durationS: Double?) {
            self.toolName = toolName
            self.argumentsPreview = argumentsPreview
            self.resultPreview = resultPreview
            self.durationS = durationS
        }
    }

    private var buffer: [Event] = []
    private let capacity = 500
    private let queue = DispatchQueue(label: "AgentNotch.AgentObservabilityLog.queue")

    private init() {}

    public func record(_ event: Event) {
        queue.sync {
            buffer.append(event)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
        }
    }

    /// Most recent agent run: the trailing slice from the most recent
    /// `longPressTranscript` event onward.
    public func currentRunEvents() -> [Event] {
        queue.sync {
            guard let startIdx = buffer.lastIndex(where: {
                if case .longPressTranscript = $0 { return true }
                return false
            }) else { return [] }
            return Array(buffer.suffix(from: startIdx))
        }
    }

    /// All Mercury calls in the buffer (any role).
    public func mercuryCalls() -> [Event] {
        queue.sync {
            buffer.filter {
                if case .mercuryCall = $0 { return true }
                return false
            }
        }
    }

    /// All Gemini calls in the buffer.
    public func geminiCalls() -> [Event] {
        queue.sync {
            buffer.filter {
                if case .geminiCall = $0 { return true }
                return false
            }
        }
    }
}
