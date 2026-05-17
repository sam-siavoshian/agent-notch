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
        public var resolvedIntent: ContextResolvedIntent?
        public init(
            transcript: String,
            contextSummary: String,
            resolvedIntent: ContextResolvedIntent? = nil
        ) {
            self.transcript = transcript
            self.contextSummary = contextSummary
            self.resolvedIntent = resolvedIntent
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

        let systemBlocks = buildSystemBlocks(
            settings: settings,
            contextSummary: input.contextSummary,
            resolvedIntent: input.resolvedIntent
        )
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

            if let intent = input.resolvedIntent {
                let outcome = ContextIntentResolverOutcomeLog.Outcome(
                    recordedAt: endedAt,
                    transcript: input.transcript,
                    intent: intent,
                    harnessStatus: status,
                    harnessErrorMessage: errorMessage,
                    harnessDurationMs: milliseconds(from: startedAt, to: endedAt)
                )
                await ContextIntentResolverOutcomeLog.shared.record(outcome)

                // Recipe feedback loop: when the harness completed successfully
                // and the resolver had surfaced a candidate recipe, bump that
                // recipe's confidence. Successful completion = no anthropic /
                // network / max_turn error AND tool calls actually ran.
                let succeeded = (status == "completed_without_tool" || status == "completed_after_tools")
                if succeeded, let topRecipe = intent.candidateRecipes.first,
                   !topRecipe.appKey.isEmpty, !topRecipe.recipeID.isEmpty {
                    await ContextMemoryStore.shared.bumpRecipeConfidence(
                        appName: topRecipe.appKey,
                        recipeID: topRecipe.recipeID
                    )
                    NSLog("[Harness] Bumped confidence for recipe \(topRecipe.recipeID) in \(topRecipe.appKey)")
                }
            }
        }

        while turn < maxTurns {
            turn += 1
            let request = AnthropicMessageRequest(
                model: currentModel,
                maxTokens: maxOutputTokens,
                systemBlocks: systemBlocks,
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

            if turn == 1 {
                let affirmation = response.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t } else { return nil }
                }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !affirmation.isEmpty {
                    TextToSpeechService.shared.speak(affirmation)
                }
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

    /// Builds the system prompt as two blocks:
    /// - **Static block** (cached): identity + how-to-use-context instructions
    ///   + user preferences + custom system prompt. These rarely change so
    ///   `cache_control: ephemeral` is set on this block, giving us a
    ///   5-minute prompt cache window across turns AND across activations.
    /// - **Dynamic block** (not cached): resolved intent + activation context.
    ///   These change per long-press so caching them would never hit.
    private func buildSystemBlocks(
        settings: AgentSettings,
        contextSummary: String,
        resolvedIntent: ContextResolvedIntent? = nil
    ) -> [SystemBlock] {
        var staticParts: [String] = []
        staticParts.append("""
        You are an on-screen computer-use agent on macOS. You control the user's machine via the computer tool. \
        You can click, type, scroll, take screenshots, and press keys. Always take a screenshot before acting if you're unsure of the screen state. \
        Refuse to perform irreversible destructive actions (deleting files, formatting drives, sending payments) without explicit confirmation. \
        Before executing any tool calls, always begin your response with a brief natural one-sentence spoken acknowledgment of what you're about to do — e.g. "Opening Chrome now." or "Sure, I'll click that." Keep it under 15 words. This sentence will be read aloud to the user.
        """)

        staticParts.append("""
        How to use the context blocks below (when present):

        1. **Resolved Goal / Verb / Target / Resolved Entities** — this is a pre-computed read of what the user means. Trust it as your starting hypothesis; only re-derive if the live screen clearly contradicts it. The resolver has already mapped fuzzy references like "this" or first names to specific entities from your UI memory.

        2. **Candidate Recipes (ranked)** — these are prose action sequences learned by watching the user repeat workflows. If the top-ranked recipe matches the goal, follow its steps directly — don't re-discover the path. The 🎯 marker means the recipe matched the intent keywords. Skip the recipe only if the live screen shows the entry-point surface is no longer where the recipe assumed.

        3. **Current Task / Current Surface / Known Controls (Affordances)** — describes where the user just was and what was actionable there. Use it to skip the "what can I click here" exploration phase. Region names are semantic (footer, sidebar, top-right) — never pixel coordinates. You still ground visually in the live screenshot.

        4. **Recent Activity / Likely Next Actions** — short narrative of what the user did right before invoking you, plus statistical hints of what they most often do from the current surface. Use as soft priors, not directives.

        5. **Entities In Play / Cross-App Memory** — concrete objects (files, people, URLs, tickets) the user has touched recently across this app and adjacent apps. Use to resolve referent ambiguity in the request.

        Treat all of the above as a *prior* describing the screen at the moment you were invoked. The live screenshot is always ground truth — if it contradicts the context, trust the screenshot and act accordingly. Take a screenshot before your first non-trivial action.
        """)

        if !settings.preferences.isEmpty {
            staticParts.append("User preferences:\n\(settings.preferences)")
        }

        if !settings.systemPrompt.isEmpty {
            staticParts.append(settings.systemPrompt)
        }

        staticParts.append("Reasoning effort: \(settings.reasoningEffort.rawValue).")

        var blocks: [SystemBlock] = []
        blocks.append(SystemBlock(text: staticParts.joined(separator: "\n\n"), cached: true))

        var dynamicParts: [String] = []
        if let intent = resolvedIntent, !intent.usedFallback {
            dynamicParts.append(Self.renderResolvedIntent(intent))
        }
        if !contextSummary.isEmpty {
            dynamicParts.append("""
            Activation context (built for this long-press):
            \(contextSummary)
            """)
        }
        if !dynamicParts.isEmpty {
            blocks.append(SystemBlock(text: dynamicParts.joined(separator: "\n\n"), cached: false))
        }
        return blocks
    }

    private static func renderResolvedIntent(_ intent: ContextResolvedIntent) -> String {
        var lines: [String] = []
        lines.append("Resolved user intent: \(intent.inferredGoal)")
        lines.append("Verb: \(intent.verb)")
        if let target = intent.target, !target.isEmpty {
            lines.append("Target: \(target)")
        }
        if !intent.resolvedEntities.isEmpty {
            let entityLines = intent.resolvedEntities.prefix(5).map { entity -> String in
                let label = entity.entityLabel ?? "(unmatched)"
                let type = entity.entityType.map { " [\($0)]" } ?? ""
                return "  - \"\(entity.userPhrase)\" → \(label)\(type) — \(entity.evidence)"
            }
            lines.append("Resolved entities:")
            lines.append(contentsOf: entityLines)
        }
        if !intent.candidateRecipes.isEmpty {
            lines.append("Candidate recipes (ranked):")
            for recipe in intent.candidateRecipes.prefix(3) {
                lines.append("  - \(recipe.recipeName) (score \(String(format: "%.2f", recipe.matchScore)))")
                for step in recipe.stepsProse.prefix(6) {
                    lines.append("      • \(step)")
                }
            }
        }
        lines.append("Resolver confidence: \(String(format: "%.2f", intent.confidence)). Treat this as a hint — re-derive only if it clearly contradicts the live screen.")
        return lines.joined(separator: "\n")
    }

    private func primaryDisplayPixelSize() -> CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 2560, height: 1664) }
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
