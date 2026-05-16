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

    public var modelID: String = AnthropicModel.haiku45
    public var fallbackModelID: String = AnthropicModel.sonnet46
    public var maxTurns: Int = 10
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
                    currentModel = fallbackModelID
                    continue
                }
                AgentState.shared.set(.error(message: "Anthropic error: \(err.status.map(String.init) ?? "?")"))
                NSLog("[Harness] \(err)")
                return
            } catch {
                AgentState.shared.set(.error(message: "Network error"))
                NSLog("[Harness] \(error)")
                return
            }

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
                return
            }

            var resultBlocks: [ContentBlock] = []
            for use in toolUses {
                AgentState.shared.set(.toolCall(name: use.name), detail: actionLabel(use.input))
                let result = await dispatcher.dispatch(toolUseId: use.id, name: use.name, input: use.input)
                resultBlocks.append(.toolResult(toolUseId: result.toolUseId, content: result.content, isError: result.isError))
            }
            messages.append(Message(role: "user", content: resultBlocks))

            if response.stopReason != "tool_use" {
                AgentState.shared.set(.idle)
                return
            }
        }

        AgentState.shared.set(.error(message: "Hit max turns (\(maxTurns))"))
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
