//
//  ComputerUseHarness.swift
//  Agent in the Notch
//
//  One agent turn: assemble inputs → call Anthropic → execute tool calls →
//  feed results back → loop until stop_reason != "tool_use". Updates
//  AgentState as it goes so the notch UI reflects what's happening.
//

import Foundation
import AppKit

@MainActor
public final class ComputerUseHarness {
    public static let shared = ComputerUseHarness()

    public var modelID: String = AnthropicModel.sonnet46
    public var fallbackModelID: String = AnthropicModel.sonnet46
    public var maxTurns: Int = 100
    public var maxOutputTokens: Int = 1024

    private init() {}

    public struct Input {
        public var transcript: String
        public var contextSummary: String
        public init(transcript: String, contextSummary: String) {
            self.transcript = transcript
            self.contextSummary = contextSummary
        }
    }

    public func run(_ input: Input) async {
        guard let apiKey = Secrets.anthropicAPIKey else {
            AgentState.shared.set(.error(message: "Missing ANTHROPIC_API_KEY"))
            return
        }

        let runID = UUID()
        let startedAt = Date()
        let transcriptLength = input.transcript.count
        let contextLength = input.contextSummary.count
        var toolCallCount = 0
        var screenshotToolCallCount = 0
        var actionCounts: [String: Int] = [:]
        var firstToolCallAt: Date?
        var firstNonScreenshotActionAt: Date?
        var usedFallback = false
        var completedTurns = 0

        let settings = AgentSettingsStore.shared.settings
        let displaySize = primaryDisplayPixelSize()
        let dispatcher = ToolDispatcher(displaySize: displaySize)
        let client = AnthropicClient(apiKey: apiKey)

        let tools: [Tool] = [
            .computer(
                displayWidth: Int(displaySize.width),
                displayHeight: Int(displaySize.height),
                displayNumber: 1
            )
        ]

        let system = buildSystemPrompt(settings: settings, contextSummary: input.contextSummary)
        var messages: [Message] = [
            Message(role: "user", content: [.text(input.transcript)])
        ]

        AgentState.shared.set(.thinking)
        CursorCompanion.shared.setThinking(true)
        defer { CursorCompanion.shared.setThinking(false) }

        var currentModel = modelID
        var triedFallback = false
        var turn = 0

        func recordMetrics(status: String, errorMessage: String? = nil) async {
            let endedAt = Date()
            await AgentMetricsStore.shared.record(AgentRunMetricsRecord(
                id: runID,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMs: milliseconds(from: startedAt, to: endedAt),
                modelID: modelID,
                fallbackModelID: fallbackModelID,
                usedFallback: usedFallback,
                transcriptLength: transcriptLength,
                contextLength: contextLength,
                contextIncluded: !input.contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                turnCount: completedTurns,
                toolCallCount: toolCallCount,
                screenshotToolCallCount: screenshotToolCallCount,
                actionCounts: actionCounts,
                timeToFirstToolCallMs: firstToolCallAt.map { milliseconds(from: startedAt, to: $0) },
                timeToFirstNonScreenshotActionMs: firstNonScreenshotActionAt.map { milliseconds(from: startedAt, to: $0) },
                finalStatus: status,
                errorMessage: errorMessage
            ))
        }

        while turn < maxTurns {
            turn += 1
            let request = AnthropicMessageRequest(
                model: currentModel,
                maxTokens: maxOutputTokens,
                system: system,
                messages: messages,
                tools: tools,
                toolChoice: nil
            )

            let response: AnthropicMessageResponse
            do {
                response = try await client.send(request)
            } catch let err as AnthropicClient.Error {
                if !triedFallback, shouldFallback(err) {
                    NSLog("[Harness] Model \(currentModel) failed (\(err.status ?? -1)), falling back to \(fallbackModelID)")
                    triedFallback = true
                    usedFallback = true
                    currentModel = fallbackModelID
                    continue
                }
                AgentState.shared.set(.error(message: "Anthropic error: \(err.status.map(String.init) ?? "?")"))
                NSLog("[Harness] \(err)")
                await recordMetrics(status: "anthropic_error", errorMessage: "\(err)")
                return
            } catch {
                AgentState.shared.set(.error(message: "Network error"))
                NSLog("[Harness] \(error)")
                await recordMetrics(status: "network_error", errorMessage: "\(error)")
                return
            }

            completedTurns = turn
            messages.append(Message(role: "assistant", content: response.content))

            let toolUses = response.content.compactMap { block -> (id: String, name: String, input: JSON)? in
                if case .toolUse(let id, let name, let inp) = block { return (id, name, inp) }
                return nil
            }

            if toolUses.isEmpty {
                let text = response.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t } else { return nil }
                }.joined(separator: " ")
                AgentState.shared.set(.idle, detail: text)
                await recordMetrics(status: "completed_without_tool")
                return
            }

            var resultBlocks: [ContentBlock] = []
            for use in toolUses {
                let action = actionLabel(use.input)
                let now = Date()
                if firstToolCallAt == nil {
                    firstToolCallAt = now
                }
                if action != "screenshot", firstNonScreenshotActionAt == nil {
                    firstNonScreenshotActionAt = now
                }
                toolCallCount += 1
                actionCounts[action, default: 0] += 1
                if action == "screenshot" {
                    screenshotToolCallCount += 1
                }

                AgentState.shared.set(.toolCall(name: use.name), detail: action)
                let result = await dispatcher.dispatch(toolUseId: use.id, name: use.name, input: use.input)
                resultBlocks.append(.toolResult(toolUseId: result.toolUseId, content: result.content, isError: result.isError))
            }
            messages.append(Message(role: "user", content: resultBlocks))

            if response.stopReason != "tool_use" {
                AgentState.shared.set(.idle)
                await recordMetrics(status: "completed_after_tools")
                return
            }
        }

        AgentState.shared.set(.error(message: "Hit max turns (\(maxTurns))"))
        await recordMetrics(status: "max_turns", errorMessage: "Hit max turns (\(maxTurns))")
    }

    // MARK: - Helpers

    private func shouldFallback(_ err: AnthropicClient.Error) -> Bool {
        guard let status = err.status else { return false }
        // 400 on a Haiku request with computer-use tool = model doesn't support it.
        // 404 also possible if the model ID is unknown to the API.
        return status == 400 || status == 404
    }

    private func actionLabel(_ input: JSON) -> String {
        input.objectValue?["action"]?.stringValue ?? "tool"
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    private func buildSystemPrompt(settings: AgentSettings, contextSummary: String) -> String {
        var parts: [String] = []
        parts.append("""
        You are an on-screen computer-use agent on macOS. You control the user's machine via the computer tool. \
        You can click, type, scroll, take screenshots, and press keys. Always take a screenshot before acting if you're unsure of the screen state. \
        Refuse to perform irreversible destructive actions (deleting files, formatting drives, sending payments) without explicit confirmation.
        """)

        if !contextSummary.isEmpty {
            parts.append("""
            Local activation context:
            \(contextSummary)

            Use this context to reduce UI exploration and choose a better first action. Treat it as recent learned context, not exact coordinates. If the current screen is ambiguous or the context looks stale, take a screenshot before acting.
            """)
        }

        if !settings.preferences.isEmpty {
            parts.append("User preferences:\n\(settings.preferences)")
        }

        if !settings.systemPrompt.isEmpty {
            parts.append(settings.systemPrompt)
        }

        parts.append("Reasoning effort: \(settings.reasoningEffort.rawValue).")

        return parts.joined(separator: "\n\n")
    }

    private func primaryDisplayPixelSize() -> CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 1920, height: 1080) }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
